`timescale 1ns/1ps

// Self-checking simulation environment; this file is not synthesizable hardware.
// Verification has three layers: directed numerical examples, a transaction
// scoreboard plus protocol assertions, and an exported trace replayed in Python.
// Testbench parameters mirror the DUT so the same tests cover several formats.
module tb_fir_core #(
    parameter integer DATA_WIDTH = 16,
    parameter integer COEFF_WIDTH = 16,
    parameter integer OUTPUT_WIDTH = DATA_WIDTH,
    parameter integer TAPS = 8,
    parameter integer INPUT_FRAC_BITS = DATA_WIDTH-1,
    parameter integer COEFF_FRAC_BITS = COEFF_WIDTH-1,
    parameter integer OUTPUT_FRAC_BITS = OUTPUT_WIDTH-1
);
    // Use signed 64-bit arithmetic for the oracle, independently of the DUT's
    // product registers and adder-tree widths. A startup guard below restricts
    // configurations so the oracle cannot silently overflow its accumulator.
    localparam integer SHIFT = INPUT_FRAC_BITS + COEFF_FRAC_BITS - OUTPUT_FRAC_BITS;
    // Select a delayed tap when available; a one-tap filter has no old sample.
    localparam integer HISTORY_TAP = (TAPS > 1) ? 1 : 0;
    localparam longint signed INPUT_MIN = -(64'sd1 << (DATA_WIDTH-1));
    localparam longint signed INPUT_MAX = (64'sd1 << (DATA_WIDTH-1))-1;
    localparam longint signed COEFF_MIN = -(64'sd1 << (COEFF_WIDTH-1));
    localparam longint signed COEFF_MAX = (64'sd1 << (COEFF_WIDTH-1))-1;
    localparam longint signed OUTPUT_MIN = -(64'sd1 << (OUTPUT_WIDTH-1));
    localparam longint signed OUTPUT_MAX = (64'sd1 << (OUTPUT_WIDTH-1))-1;
    localparam longint signed TEST_INPUT = 64'sd1 << ((DATA_WIDTH > 3) ? DATA_WIDTH-3 : 0);
    // GAIN represents one-half when coefficients have fractional bits. For an
    // integer-only format, use unity because one-half is not representable.
    localparam longint signed GAIN = (COEFF_FRAC_BITS > 0) ? (64'sd1 << (COEFF_FRAC_BITS-1)) : 1;

    logic clk = 0, resetn = 0, history_clear = 0;
    logic [TAPS*COEFF_WIDTH-1:0] coefficients = 0;
    logic signed [DATA_WIDTH-1:0] s_data = 0;
    logic s_valid = 0, m_ready = 0;
    wire s_ready, m_valid, m_saturated, idle;
    wire signed [OUTPUT_WIDTH-1:0] m_data;

    fir_core #(
        .DATA_WIDTH(DATA_WIDTH), .COEFF_WIDTH(COEFF_WIDTH),
        .OUTPUT_WIDTH(OUTPUT_WIDTH), .TAPS(TAPS),
        .INPUT_FRAC_BITS(INPUT_FRAC_BITS), .COEFF_FRAC_BITS(COEFF_FRAC_BITS),
        .OUTPUT_FRAC_BITS(OUTPUT_FRAC_BITS)
    ) dut (
        .clk(clk), .resetn(resetn), .history_clear(history_clear),
        .coefficients(coefficients), .s_data(s_data), .s_valid(s_valid),
        .s_ready(s_ready), .m_data(m_data), .m_valid(m_valid),
        .m_ready(m_ready), .m_saturated(m_saturated), .idle(idle)
    );
    // A 10 ns simulation clock: falling edges drive stimulus, rising edges
    // perform transfers. This clock generator exists only in the testbench.
    always #5 clk = ~clk;

    // Each queue entry contains the saturation bit followed by the output word.
    logic [OUTPUT_WIDTH:0] expected[$];
    // Store acceptance timestamps in a parallel queue for latency checking.
    int accepted_at[$];
    longint signed model_history [0:TAPS-1];
    logic [TAPS*COEFF_WIDTH-1:0] previous_coefficients = 0;
    // These counters span the entire run, including hardware resets. Reset may
    // discard pending results, so conservation is writes == reads + discarded.
    int writes = 0, reads = 0, discarded = 0, clock_index = 0;
    int output_stalls = 0, input_stalls = 0, resets_with_data = 0;
    int positive_clips = 0, negative_clips = 0;
    int history_clears = 0, busy_clear_requests = 0, deferred_inputs = 0;
    int read_streak = 0, max_read_streak = 0;
    int seed = 1, target_samples = 10000, events_file = 0;
    // A blocked source must retry exactly the same word with valid still high.
    // check_latency is enabled only in the deliberately stall-free test phase.
    bit source_blocked = 0, check_latency = 0;
    logic [DATA_WIDTH-1:0] held_input;
    logic [31:0] rng_state = 1;
    string events_path = "fir_events.txt";

    // Local xorshift32 generator makes traffic reproducible from SEED without
    // depending on the simulator's global random-number-generator state.
    function automatic logic [31:0] next_random(input logic [31:0] value);
        logic [31:0] result;
        result = value ^ (value << 13);
        result = result ^ (result >> 17);
        return result ^ (result << 5);
    endfunction

    // Return {saturation_flag, output_bits}. Compare the wide integer before
    // narrowing, and mark only values beyond the rails as clipped.
    function automatic logic [OUTPUT_WIDTH:0] clipped(input longint signed value);
        if (value > OUTPUT_MAX) return {1'b1, OUTPUT_WIDTH'(OUTPUT_MAX)};
        if (value < OUTPUT_MIN) return {1'b1, OUTPUT_WIDTH'(OUTPUT_MIN)};
        return {1'b0, value[OUTPUT_WIDTH-1:0]};
    endfunction

    // Compact expected value for directed cases with exactly one contribution.
    // This avoids relying only on the general history-based scoreboard oracle.
    function automatic logic [OUTPUT_WIDTH:0] one_product(
        input longint signed sample, input longint signed coefficient);
        return clipped((sample * coefficient) >>> SHIFT);
    endfunction

    // Behavioral integer oracle, independent of DUT registers and adder widths.
    function automatic logic [OUTPUT_WIDTH:0] reference_result(input logic signed [DATA_WIDTH-1:0] sample);
        longint signed accumulator, shifted, coefficient;
        // Called ONLY on an input handshake. Shift from high indices downward
        // because these blocking assignments update the software model at once.
        // Unlike RTL nonblocking assignments, an upward loop would overwrite
        // history before later iterations could read its previous contents.
        for (int k = TAPS-1; k > 0; k--) model_history[k] = model_history[k-1];
        model_history[0] = sample;
        accumulator = 0;
        for (int k = 0; k < TAPS; k++) begin
            // A part-select loses signedness; explicitly restore the sign.
            coefficient = $signed(coefficients[k*COEFF_WIDTH +: COEFF_WIDTH]);
            accumulator += model_history[k] * coefficient;
        end
        shifted = accumulator >>> SHIFT;
        if (shifted > OUTPUT_MAX) positive_clips++;
        if (shifted < OUTPUT_MIN) negative_clips++;
        return clipped(shifted);
    endfunction

    // Drive a complete cycle away from the active clock edge. The #1 delay after
    // the rising edge lets DUT nonblocking assignments and the scoreboard settle
    // before a calling task inspects newly registered signals.
    task automatic cycle(input bit valid_in, input logic [DATA_WIDTH-1:0] data_in,
                         input bit ready_out, input bit reset_value = 1,
                         input bit clear_value = 0);
        @(negedge clk);
        resetn = reset_value;
        history_clear = clear_value;
        s_valid = valid_in;
        s_data = data_in;
        m_ready = ready_out;
        @(posedge clk);
        #1;
    endtask

    // Finish a previously blocked input, then stop offering new transactions
    // while the receiver accepts all results. valid=0 is a gap, not a zero input.
    task automatic drain;
        int attempts;
        attempts = 0;
        while (source_blocked || expected.size() != 0) begin
            if (attempts++ > 32) $fatal(1, "Pipeline failed to drain");
            if (source_blocked) cycle(1, s_data, 1);
            else cycle(0, 0, 1);
        end
        // Extra empty cycles expose a late duplicate result after the queue drains.
        repeat (4) cycle(0, 0, 1);
        if (idle !== 1'b1) $fatal(1, "Drained core is not idle");
    endtask

    // Legal coefficient replacement uses idle + history_clear, without reset.
    task automatic configure_filter(input logic [TAPS*COEFF_WIDTH-1:0] values);
        // Coefficients are external inputs, not resettable DUT registers. Wait
        // for no in-flight work, replace them, and clear the previous sample epoch.
        drain();
        @(negedge clk);
        history_clear = 1;
        s_valid = 0;
        m_ready = 0;
        coefficients = values;
        // Export every coefficient so Python can replay this exact filter epoch.
        for (int k = 0; k < TAPS; k++)
            $fdisplay(events_file, "C %0d %0d", k, $signed(values[k*COEFF_WIDTH +: COEFF_WIDTH]));
        @(posedge clk);
        #1;
        if (s_ready !== 1'b0 || m_valid !== 1'b0 || idle !== 1'b1)
            $fatal(1, "Idle coefficient update flags failed");
        cycle(0, 0, 0);
    endtask

    // Offering valid once is insufficient when ready is low. Keep the word
    // unchanged until the scoreboard observes its actual input handshake.
    task automatic send_sample(input logic [DATA_WIDTH-1:0] value, input bit ready_out);
        int attempts;
        attempts = 0;
        do begin
            if (attempts++ > 32) $fatal(1, "Input was not accepted");
            cycle(1, value, ready_out);
        end while (source_blocked);
    endtask

    // Block the receiver to inspect a result before it can disappear in a
    // handshake. Hold it for two more cycles, then let the scoreboard consume it.
    task automatic check_single(input logic [DATA_WIDTH-1:0] sample,
                                input logic [OUTPUT_WIDTH:0] literal_expected);
        int attempts;
        send_sample(sample, 0);
        attempts = 0;
        while (m_valid !== 1'b1) begin
            if (attempts++ > 8) $fatal(1, "Output valid did not arrive");
            cycle(0, 0, 0);
        end
        if ({m_saturated, m_data} !== literal_expected)
            $fatal(1, "Directed mismatch input=%h expected=%h actual=%h", sample, literal_expected, {m_saturated, m_data});
        repeat (2) cycle(0, 0, 0);
        drain();
    endtask

    // |=> checks the following sampled clock edge. Once valid is blocked, both
    // payload and metadata must remain stable through the next transfer chance.
    // Reset cancels this obligation because it intentionally discards work.
    property output_stays_stable;
        @(posedge clk) disable iff (!resetn)
            m_valid && !m_ready |=> m_valid && $stable({m_data, m_saturated});
    endproperty
    assert property (output_stays_stable)
        else $fatal(1, "Output data/saturation changed under backpressure");

    // Check the testbench source as well: illegal stimulus could otherwise make
    // a correct DUT appear to lose samples during backpressure or a clear request.
    property source_stays_stable;
        @(posedge clk) disable iff (!resetn)
            s_valid && !s_ready |=> s_valid && $stable(s_data);
    endproperty
    assert property (source_stays_stable)
        else $fatal(1, "Testbench changed a blocked input");

    // Sample handshake signals BEFORE DUT nonblocking updates. They describe
    // transfers at this edge; the later #1 check observes the resulting new state.
    // The queue tracks unconsumed results, independently of physical stage layout.
    always @(posedge clk) begin : scoreboard
        logic [OUTPUT_WIDTH:0] wanted;
        int input_cycle;
        clock_index++;
        if (!resetn) begin
            // Hardware reset invalidates all pending results and all history.
            // Keep cumulative counts and external coefficients for accounting.
            if (expected.size() != 0) resets_with_data++;
            discarded += expected.size();
            expected.delete();
            accepted_at.delete();
            for (int k = 0; k < TAPS; k++) model_history[k] = 0;
            source_blocked = 0;
            read_streak = 0;
            previous_coefficients = coefficients;
            $fdisplay(events_file, "R");
        end else begin
            if (idle !== (expected.size() == 0)) $fatal(1, "Idle disagrees with pending transactions");
            if ($isunknown({s_ready, m_valid, idle})) $fatal(1, "Unknown control output");
            if (expected.size() != 0 && coefficients !== previous_coefficients)
                $fatal(1, "Coefficients changed with data in flight");
            previous_coefficients = coefficients;
            if (history_clear && s_ready !== 1'b0) $fatal(1, "Clear did not block input");
            if (history_clear && idle) begin
                // Only an idle clear is an accepted history operation. A busy
                // pulse still blocks input but must not erase accepted samples.
                for (int k = 0; k < TAPS; k++) model_history[k] = 0;
                history_clears++;
                if (s_valid) deferred_inputs++;
                $fdisplay(events_file, "H");
            end else if (history_clear) busy_clear_requests++;
            if (source_blocked && (s_valid !== 1'b1 || s_data !== held_input))
                $fatal(1, "Blocked source payload changed");
            if (s_valid && !s_ready) input_stalls++;
            if (m_valid && !m_ready) output_stalls++;
            source_blocked = s_valid && !s_ready;
            held_input = s_data;

            // Check output BEFORE enqueuing any input accepted on the same edge.
            // This also detects an illegal zero-latency bypass of an empty core.
            if (m_valid && m_ready) begin
                if (expected.size() == 0) $fatal(1, "Unexpected/duplicate output");
                wanted = expected.pop_front();
                input_cycle = accepted_at.pop_front();
                if ({m_saturated, m_data} !== wanted)
                    $fatal(1, "FIR mismatch output=%0d expected=%h actual=%h", reads, wanted, {m_saturated, m_data});
                if (check_latency && clock_index - input_cycle != 2)
                    $fatal(1, "Expected two-cycle handshake latency without stalls");
                $fdisplay(events_file, "O %0d %0d", $signed(m_data), m_saturated);
                reads++;
                read_streak++;
                if (read_streak > max_read_streak) max_read_streak = read_streak;
            end else read_streak = 0;
            if (s_valid && s_ready) begin
                // Advance the numerical model once per accepted sample, never
                // once per attempted valid cycle or elapsed clock cycle.
                if ($isunknown(s_data)) $fatal(1, "Unknown accepted input");
                expected.push_back(reference_result(s_data));
                accepted_at.push_back(clock_index);
                $fdisplay(events_file, "I %0d", $signed(s_data));
                writes++;
            end
        end
        // Wait for valid flags to update, then check pending count against idle.
        #1;
        if (idle !== (expected.size() == 0)) $fatal(1, "Post-edge idle mismatch");
        if (!resetn && (m_valid !== 1'b0 || s_ready !== 1'b0 || m_saturated !== 1'b0))
            $fatal(1, "Reset flags failed");
    end

    // Directed phases establish specific corner cases before randomized traffic.
    // P describes the format; C changes coefficients; I/O record accepted
    // transactions; R records reset; H records an actually accepted idle clear.
    initial begin : stimulus
        logic [TAPS*COEFF_WIDTH-1:0] values;
        longint signed amplitude, impulse, min_product, other_min_product;
        bit positive_possible, negative_possible;
        int random_start, random_cycles;
        if ($value$plusargs("SEED=%d", seed)) begin end
        if ($value$plusargs("SAMPLES=%d", target_samples)) begin end
        if ($value$plusargs("EVENTS=%s", events_path)) begin end
        if (seed <= 0 || target_samples < 1 || target_samples > 100000)
            $fatal(1, "Require positive SEED and 1 <= SAMPLES <= 100000");
        if (DATA_WIDTH + COEFF_WIDTH + $clog2(TAPS) > 62)
            $fatal(1, "This testbench integer oracle supports at most 62 accumulator bits");
        events_file = $fopen(events_path, "w");
        if (events_file == 0) $fatal(1, "Cannot open event export");
        $fdisplay(events_file, "P %0d %0d %0d %0d %0d %0d %0d", TAPS, DATA_WIDTH,
                  COEFF_WIDTH, OUTPUT_WIDTH, INPUT_FRAC_BITS, COEFF_FRAC_BITS, OUTPUT_FRAC_BITS);
        rng_state = seed;
        repeat (2) cycle(0, 0, 0, 0);
        cycle(0, 0, 0);

        // Phase 1: a single active tap isolates sign, binary-point scaling and
        // negative arithmetic-shift rounding (for example, -3 / 2 becomes -2).
        values = 0;
        values[0 +: COEFF_WIDTH] = COEFF_WIDTH'(GAIN);
        configure_filter(values);
        check_single(DATA_WIDTH'(TEST_INPUT), one_product(TEST_INPUT, GAIN));
        check_single(DATA_WIDTH'(-TEST_INPUT), one_product(-TEST_INPUT, GAIN));
        if (COEFF_FRAC_BITS > 0 && INPUT_FRAC_BITS == OUTPUT_FRAC_BITS) begin
            check_single(DATA_WIDTH'(1), clipped(0));
            check_single(DATA_WIDTH'(-1), clipped(-1));
            check_single(DATA_WIDTH'(3), clipped(1));
            check_single(DATA_WIDTH'(-3), clipped(-2));
            if (DATA_WIDTH >= 16 && OUTPUT_WIDTH >= 16)
                check_single(DATA_WIDTH'(10000), clipped(5000));
        end
        check_single(DATA_WIDTH'(INPUT_MAX), one_product(INPUT_MAX, GAIN));
        check_single(DATA_WIDTH'(INPUT_MIN), one_product(INPUT_MIN, GAIN));
        $display("PASS directed: gain, signed shifting and output hold");

        // Phase 2: zero coefficients must suppress even the largest input rails.
        configure_filter(0);
        check_single(DATA_WIDTH'(INPUT_MAX), clipped(0));
        check_single(DATA_WIDTH'(INPUT_MIN), clipped(0));
        $display("PASS directed: zero coefficients");

        // Phase 3: distinct alternating-sign taps reveal reversed coefficient
        // ordering. An impulse followed by accepted zeros walks through all taps;
        // the gaps inside check_single must preserve history between transfers.
        for (int k = 0; k < TAPS; k++) begin
            amplitude = (COEFF_FRAC_BITS > k+1) ? (64'sd1 << (COEFF_FRAC_BITS-k-1)) : 1;
            if (k % 2 != 0) amplitude = -amplitude;
            values[k*COEFF_WIDTH +: COEFF_WIDTH] = COEFF_WIDTH'(amplitude);
        end
        configure_filter(values);
        impulse = TEST_INPUT;
        for (int k = 0; k < TAPS; k++)
            check_single(DATA_WIDTH'((k == 0) ? impulse : 0),
                         one_product(impulse, $signed(values[k*COEFF_WIDTH +: COEFF_WIDTH])));
        check_single(0, clipped(0));
        $display("PASS directed: impulse tap ordering and history across gaps");

        // Phase 4: rail inputs and coefficients exercise accumulator headroom
        // and clipping in both directions, including minimum times minimum.
        configure_filter({TAPS{COEFF_WIDTH'(COEFF_MAX)}});
        repeat (32) send_sample(DATA_WIDTH'(INPUT_MAX), 1);
        drain();
        configure_filter({TAPS{COEFF_WIDTH'(COEFF_MAX)}});
        repeat (32) send_sample(DATA_WIDTH'(INPUT_MIN), 1);
        drain();
        configure_filter({TAPS{COEFF_WIDTH'(COEFF_MIN)}});
        repeat (32) send_sample(DATA_WIDTH'(INPUT_MIN), 1);
        drain();
        configure_filter({TAPS{COEFF_WIDTH'(COEFF_MIN)}});
        repeat (32) send_sample(DATA_WIDTH'(INPUT_MAX), 1);
        drain();
        // Equal numerical output values can have different metadata: an exact
        // positive rail is not clipped, whereas an overflowing value clamped to
        // that same rail must set m_saturated.
        if (DATA_WIDTH == OUTPUT_WIDTH && INPUT_FRAC_BITS == OUTPUT_FRAC_BITS &&
            COEFF_FRAC_BITS == COEFF_WIDTH-1) begin
            values = 0;
            values[0 +: COEFF_WIDTH] = COEFF_WIDTH'(COEFF_MIN);
            configure_filter(values);
            check_single(DATA_WIDTH'(-INPUT_MAX), {1'b0, OUTPUT_WIDTH'(OUTPUT_MAX)});
            check_single(DATA_WIDTH'(INPUT_MIN), {1'b1, OUTPUT_WIDTH'(OUTPUT_MAX)});
        end
        $display("PASS directed: clipping, natural rail versus saturation flag, accumulator precision");

        configure_filter(values);
        // Phase 5: continuous source and receiver readiness must sustain one
        // result each clock after startup, with two-edge handshake latency.
        check_latency = 1;
        for (int k = 0; k < 1050; k++) cycle(1, DATA_WIDTH'(TEST_INPUT + k*13), 1);
        drain();
        check_latency = 0;
        $display("PASS directed: streaming throughput and two-cycle latency");

        values = 0;
        // Phase 6: keep gain on a historical tap where possible, making stale
        // history visible after clear. Coefficients survive this operation.
        values[HISTORY_TAP*COEFF_WIDTH +: COEFF_WIDTH] = COEFF_WIDTH'(GAIN);
        configure_filter(values);
        check_single(DATA_WIDTH'(TEST_INPUT), (HISTORY_TAP == 0) ? one_product(TEST_INPUT, GAIN) : clipped(0));
        cycle(0, 0, 0, 1, 1);
        check_single(0, clipped(0));
        // A candidate input must wait through an idle clear, then be accepted once.
        cycle(1, DATA_WIDTH'(TEST_INPUT), 0, 1, 1);
        if (!source_blocked) $fatal(1, "Clear did not defer input");
        cycle(1, DATA_WIDTH'(TEST_INPUT), 0);
        drain();
        check_single(0, (HISTORY_TAP == 0) ? clipped(0) : one_product(TEST_INPUT, GAIN));
        $display("PASS directed: idle clear, preserved coefficients and deferred input");

        configure_filter(values);
        // Phase 7: fill both pipeline stages, pulse clear while busy, and prove
        // the pending results and subsequent delayed sample were preserved.
        send_sample(DATA_WIDTH'(TEST_INPUT), 0);
        send_sample(DATA_WIDTH'(TEST_INPUT+1), 0);
        cycle(0, 0, 0, 1, 1);
        drain();
        check_single(0, (HISTORY_TAP == 0) ? clipped(0) : one_product(TEST_INPUT+1, GAIN));
        // A held clear first drains both stages and then clears at idle.
        send_sample(DATA_WIDTH'(TEST_INPUT), 0);
        send_sample(DATA_WIDTH'(TEST_INPUT+1), 0);
        repeat (3) cycle(0, 0, 1, 1, 1);
        cycle(0, 0, 1);
        check_single(0, clipped(0));
        $display("PASS directed: busy clear preserves data; held request drains then clears");

        configure_filter(values);
        send_sample(DATA_WIDTH'(TEST_INPUT), 0);
        send_sample(DATA_WIDTH'(TEST_INPUT+1), 0);
        cycle(1, DATA_WIDTH'(TEST_INPUT), 0);
        // Phase 8: reset is allowed to abandon the two accepted results and a
        // blocked, unaccepted source word. It also starts with zero sample history.
        if (!source_blocked || m_valid !== 1'b1) $fatal(1, "Reset fixture did not fill pipeline");
        cycle(0, 0, 0, 0);
        cycle(0, 0, 0, 0);
        cycle(0, 0, 1);
        check_single(0, clipped(0));
        check_single(DATA_WIDTH'(TEST_INPUT), (HISTORY_TAP == 0) ? one_product(TEST_INPUT, GAIN) : clipped(0));
        check_single(0, (HISTORY_TAP == 0) ? clipped(0) : one_product(TEST_INPUT, GAIN));
        $display("PASS directed: reset with blocked input/output and cleared history");

        for (int k = 0; k < TAPS; k++) begin
            rng_state = next_random(rng_state);
            values[k*COEFF_WIDTH +: COEFF_WIDTH] = COEFF_WIDTH'(rng_state);
        end
        configure_filter(values);
        // Phase 9: count accepted random samples, not attempts. Force recurring
        // 24-cycle receiver stalls in addition to random valid/ready gaps.
        // A blocked source retries its existing word instead of generating a new one.
        random_start = writes;
        random_cycles = 0;
        while (writes-random_start < target_samples) begin
            if (random_cycles++ > target_samples*30+1000) $fatal(1, "Random traffic progress timeout");
            rng_state = next_random(rng_state);
            if (source_blocked) cycle(1, s_data, (random_cycles % 251 >= 24) && rng_state[2]);
            else cycle(rng_state[1:0] != 0, DATA_WIDTH'(rng_state), (random_cycles % 251 >= 24) && rng_state[2]);
        end
        drain();
        // Some formats cannot clip in one direction (for example, a wide integer
        // output). Require clip coverage only when the mathematical range permits it.
        min_product = INPUT_MIN * COEFF_MAX;
        other_min_product = INPUT_MAX * COEFF_MIN;
        if (other_min_product < min_product) min_product = other_min_product;
        positive_possible = ((TAPS * (INPUT_MIN * COEFF_MIN)) >>> SHIFT) > OUTPUT_MAX;
        negative_possible = ((TAPS * min_product) >>> SHIFT) < OUTPUT_MIN;
        // Every accepted sample must be consumed exactly once or explicitly
        // discarded by reset; all required control scenarios must actually occur.
        if (writes != reads+discarded || expected.size() != 0) $fatal(1, "Final accounting failed");
        if (max_read_streak < 1024 || input_stalls == 0 || output_stalls == 0 || resets_with_data == 0 ||
            history_clears == 0 || busy_clear_requests == 0 || deferred_inputs == 0 ||
            (positive_possible && positive_clips == 0) || (negative_possible && negative_clips == 0))
            $fatal(1, "Required scenario coverage missing");
        $display("PASS: fir_core taps=%0d input_width=%0d coeff_width=%0d output_width=%0d input_frac=%0d coeff_frac=%0d output_frac=%0d seed=%0d random_samples=%0d writes=%0d reads=%0d reset_discarded=%0d max_streak=%0d history_clears=%0d busy_clears=%0d",
                 TAPS, DATA_WIDTH, COEFF_WIDTH, OUTPUT_WIDTH, INPUT_FRAC_BITS, COEFF_FRAC_BITS,
                 OUTPUT_FRAC_BITS, seed, writes-random_start, writes, reads, discarded,
                 max_read_streak, history_clears, busy_clear_requests);
        $display("COVERAGE: input_stalls=%0d output_stalls=%0d positive_clips=%0d negative_clips=%0d reset_with_data=%0d deferred_inputs=%0d",
                 input_stalls, output_stalls, positive_clips, negative_clips, resets_with_data, deferred_inputs);
        $fclose(events_file);
        $finish;
    end

    // Independent wall-clock watchdog catches a hung task even if its local
    // progress counter never advances. This is simulation time, not host time.
    initial begin
        #100000000;
        $fatal(1, "FIR testbench watchdog timeout");
    end
endmodule
