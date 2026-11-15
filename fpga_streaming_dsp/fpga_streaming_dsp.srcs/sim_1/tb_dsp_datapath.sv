`timescale 1ns/1ps

// End-to-end verification observes EXTERNAL handshakes, not attempted samples.
// An independent integer oracle checks both data and saturation; Python replays
// the exported events as a second arithmetic check. Internal probes below are
// verification-only and do not add ports or state to the hardware.
module tb_dsp_datapath #(
    parameter integer DATA_WIDTH = 16,
    parameter integer COEFF_WIDTH = 16,
    parameter integer OUTPUT_WIDTH = DATA_WIDTH,
    parameter integer TAPS = 8,
    parameter integer INPUT_FRAC_BITS = DATA_WIDTH-1,
    parameter integer COEFF_FRAC_BITS = COEFF_WIDTH-1,
    parameter integer OUTPUT_FRAC_BITS = OUTPUT_WIDTH-1,
    parameter integer INPUT_FIFO_DEPTH = 16,
    parameter integer OUTPUT_FIFO_DEPTH = 16
);
    localparam integer SHIFT = INPUT_FRAC_BITS + COEFF_FRAC_BITS - OUTPUT_FRAC_BITS;
    localparam integer CAPACITY = INPUT_FIFO_DEPTH + OUTPUT_FIFO_DEPTH + 2;
    localparam longint signed INPUT_MIN = -(64'sd1 << (DATA_WIDTH-1));
    localparam longint signed INPUT_MAX = (64'sd1 << (DATA_WIDTH-1))-1;
    localparam longint signed COEFF_MIN = -(64'sd1 << (COEFF_WIDTH-1));
    localparam longint signed COEFF_MAX = (64'sd1 << (COEFF_WIDTH-1))-1;
    localparam longint signed OUTPUT_MIN = -(64'sd1 << (OUTPUT_WIDTH-1));
    localparam longint signed OUTPUT_MAX = (64'sd1 << (OUTPUT_WIDTH-1))-1;
    localparam longint signed GAIN = (COEFF_FRAC_BITS > 0) ? (64'sd1 << (COEFF_FRAC_BITS-1)) : 1;
    localparam longint signed TEST_INPUT = 64'sd1 << ((DATA_WIDTH > 3) ? DATA_WIDTH-3 : 0);

    logic clk = 0, resetn = 0, enable = 0, history_clear = 0;
    logic [TAPS*COEFF_WIDTH-1:0] coefficients = 0;
    logic signed [DATA_WIDTH-1:0] s_data = 0;
    logic s_valid = 0, m_ready = 0;
    wire s_ready, m_valid, m_saturated, idle, history_clear_accepted, result_saturated;
    wire signed [OUTPUT_WIDTH-1:0] m_data;
    wire [$clog2(INPUT_FIFO_DEPTH):0] input_occupancy;
    wire [$clog2(OUTPUT_FIFO_DEPTH):0] output_occupancy;

    dsp_datapath #(
        .DATA_WIDTH(DATA_WIDTH), .COEFF_WIDTH(COEFF_WIDTH), .OUTPUT_WIDTH(OUTPUT_WIDTH),
        .TAPS(TAPS), .INPUT_FRAC_BITS(INPUT_FRAC_BITS), .COEFF_FRAC_BITS(COEFF_FRAC_BITS),
        .OUTPUT_FRAC_BITS(OUTPUT_FRAC_BITS), .INPUT_FIFO_DEPTH(INPUT_FIFO_DEPTH),
        .OUTPUT_FIFO_DEPTH(OUTPUT_FIFO_DEPTH)
    ) dut (.*);
    always #5 clk = ~clk;

    // expected tracks every accepted input until its external output or reset.
    // to_produce independently checks the earlier FIR-to-output-FIFO transfer,
    // including the exact cycle of the future sticky-status saturation event.
    logic [OUTPUT_WIDTH:0] expected[$], to_produce[$];
    int accepted_at[$];
    longint signed model_history [0:TAPS-1];
    logic [TAPS*COEFF_WIDTH-1:0] previous_coefficients = 0;
    int writes = 0, reads = 0, discarded = 0, clock_index = 0;
    int input_stalls = 0, output_stalls = 0, disabled_reads = 0;
    int clears = 0, rejected_clears = 0, resets_with_data = 0;
    int positive_clips = 0, negative_clips = 0, saturation_events = 0;
    int input_full = 0, output_full = 0, max_pending = 0;
    int read_streak = 0, max_read_streak = 0;
    int seed = 1, target_samples = 10000, events_file = 0;
    logic [31:0] rng_state = 1;
    logic [DATA_WIDTH-1:0] held_input;
    bit source_blocked = 0, check_latency = 0;
    string events_path = "datapath_events.txt";

    function automatic logic [31:0] next_random(input logic [31:0] value);
        logic [31:0] result;
        result = value ^ (value << 13);
        result = result ^ (result >> 17);
        return result ^ (result << 5);
    endfunction

    function automatic logic [OUTPUT_WIDTH:0] clipped(input longint signed value);
        if (value > OUTPUT_MAX) return {1'b1, OUTPUT_WIDTH'(OUTPUT_MAX)};
        if (value < OUTPUT_MIN) return {1'b1, OUTPUT_WIDTH'(OUTPUT_MIN)};
        return {1'b0, value[OUTPUT_WIDTH-1:0]};
    endfunction

    // Blocking software-model updates go from old/high indices downward.
    // Advance only on external acceptance. Coefficients cannot change while
    // any work is buffered, so modeling ahead of FIR execution is equivalent.
    function automatic logic [OUTPUT_WIDTH:0] reference_result(input logic signed [DATA_WIDTH-1:0] sample);
        longint signed accumulator, coefficient, shifted;
        for (int k = TAPS-1; k > 0; k--) model_history[k] = model_history[k-1];
        model_history[0] = sample;
        accumulator = 0;
        for (int k = 0; k < TAPS; k++) begin
            coefficient = $signed(coefficients[k*COEFF_WIDTH +: COEFF_WIDTH]);
            accumulator += model_history[k] * coefficient;
        end
        shifted = accumulator >>> SHIFT;
        if (shifted > OUTPUT_MAX) positive_clips++;
        if (shifted < OUTPUT_MIN) negative_clips++;
        return clipped(shifted);
    endfunction

    // Falling-edge drive avoids races with rising-edge handshake monitors.
    // Return after NBA updates, so tasks inspect the new registered state.
    task automatic cycle(input bit valid_in, input logic [DATA_WIDTH-1:0] data_in,
                         input bit ready_out, input bit enabled = 1,
                         input bit reset_value = 1, input bit clear_value = 0);
        @(negedge clk);
        resetn = reset_value;
        enable = enabled;
        history_clear = clear_value;
        s_valid = valid_in;
        s_data = data_in;
        m_ready = ready_out;
        @(posedge clk);
        #1;
    endtask

    task automatic send_sample(input logic [DATA_WIDTH-1:0] value);
        int attempts;
        attempts = 0;
        do begin
            if (attempts++ > CAPACITY+32) $fatal(1, "Input acceptance timeout");
            cycle(1, value, 1);
        end while (source_blocked);
    endtask

    // Finish any blocked source word before removing valid, then disable new
    // acceptance and drain all internal work. No zero samples are injected.
    task automatic drain;
        int attempts;
        attempts = 0;
        while (source_blocked) begin
            if (attempts++ > CAPACITY+32) $fatal(1, "Blocked source drain timeout");
            cycle(1, s_data, 1);
        end
        while (expected.size() != 0) begin
            if (attempts++ > 2*CAPACITY+64) $fatal(1, "Datapath drain timeout");
            cycle(0, 0, 1, 0);
        end
        repeat (4) cycle(0, 0, 1, 0);
        if (!idle || input_occupancy != 0 || output_occupancy != 0)
            $fatal(1, "Drained datapath is not empty");
    endtask

    // Coefficients remain external direct inputs until the AXI4-Lite milestone.
    // Replace them legally with the whole datapath disabled, idle and clearing.
    task automatic configure_filter(input logic [TAPS*COEFF_WIDTH-1:0] values);
        drain();
        @(negedge clk);
        enable = 0;
        history_clear = 1;
        s_valid = 0;
        coefficients = values;
        for (int k = 0; k < TAPS; k++)
            $fdisplay(events_file, "C %0d %0d", k, $signed(values[k*COEFF_WIDTH +: COEFF_WIDTH]));
        @(posedge clk);
        #1;
        if (!history_clear_accepted || s_ready) $fatal(1, "Legal clear was not accepted");
        cycle(0, 0, 0, 0);
    endtask

    task automatic check_single(input logic [DATA_WIDTH-1:0] sample,
                                input logic [OUTPUT_WIDTH:0] literal_expected);
        int attempts;
        attempts = 0;
        cycle(1, sample, 0);
        if (source_blocked) $fatal(1, "Single-sample fixture was not empty");
        while (!m_valid) begin
            if (attempts++ > 12) $fatal(1, "Single output did not arrive");
            cycle(0, 0, 0);
        end
        if ({m_saturated, m_data} !== literal_expected)
            $fatal(1, "Directed arithmetic/metadata mismatch");
        repeat (3) cycle(0, 0, 0);
        drain();
    endtask

    // Fill the entire system while the receiver refuses data. The first blocked
    // input is still an UNACCEPTED source transaction and must be held or reset.
    task automatic fill_blocked;
        int attempts;
        attempts = 0;
        do begin
            if (attempts++ > CAPACITY+16) $fatal(1, "Backpressure did not reach source");
            cycle(1, DATA_WIDTH'(attempts*97), 0);
        end while (!source_blocked);
        if (expected.size() != CAPACITY || input_occupancy != INPUT_FIFO_DEPTH ||
            output_occupancy != OUTPUT_FIFO_DEPTH || !m_valid)
            $fatal(1, "Full-buffer fixture failed");
        repeat (8) cycle(1, s_data, 0);
    endtask

    // Data and its sideband must remain stable together, including while enable
    // changes or an invalid clear is presented. Reset may abandon a transaction.
    assert property (@(posedge clk) disable iff (!resetn)
        m_valid && !m_ready |=> m_valid && $stable({m_data, m_saturated}))
        else $fatal(1, "Output changed under backpressure");
    assert property (@(posedge clk) disable iff (!resetn)
        s_valid && !s_ready |=> s_valid && $stable(s_data))
        else $fatal(1, "Testbench changed an unaccepted source word");

    always @(posedge clk) begin : scoreboard
        logic [OUTPUT_WIDTH:0] wanted, generated;
        int input_cycle;
        clock_index++;
        if (!resetn) begin
            if (expected.size() != 0) resets_with_data++;
            discarded += expected.size();
            expected.delete();
            to_produce.delete();
            accepted_at.delete();
            for (int k = 0; k < TAPS; k++) model_history[k] = 0;
            source_blocked = 0;
            read_streak = 0;
            previous_coefficients = coefficients;
            $fdisplay(events_file, "R");
        end else begin
            if ($isunknown({s_ready, m_valid, idle, history_clear_accepted, result_saturated}))
                $fatal(1, "Unknown control output");
            if (idle !== (expected.size() == 0)) $fatal(1, "Pre-edge global idle mismatch");
            if (!enable && s_ready) $fatal(1, "Disabled input remained ready");
            if (input_occupancy > INPUT_FIFO_DEPTH || output_occupancy > OUTPUT_FIFO_DEPTH)
                $fatal(1, "FIFO occupancy exceeded its capacity");
            if (coefficients !== previous_coefficients && (enable || !idle || !history_clear_accepted))
                $fatal(1, "Illegal testbench coefficient update");
            previous_coefficients = coefficients;
            if (history_clear_accepted !== (history_clear && !enable && idle))
                $fatal(1, "Global history-clear acceptance mismatch");
            if (history_clear_accepted) begin
                for (int k = 0; k < TAPS; k++) model_history[k] = 0;
                clears++;
                $fdisplay(events_file, "H");
            end else if (history_clear) rejected_clears++;
            if (source_blocked && (!s_valid || s_data !== held_input))
                $fatal(1, "Source retry changed");
            source_blocked = s_valid && !s_ready;
            held_input = s_data;
            if (source_blocked) input_stalls++;
            if (m_valid && !m_ready) output_stalls++;
            if (input_occupancy == INPUT_FIFO_DEPTH) input_full++;
            if (output_occupancy == OUTPUT_FIFO_DEPTH) output_full++;

            // Check output before accepting a new input: empty bypass is illegal.
            if (m_valid && m_ready) begin
                if (expected.size() == 0) $fatal(1, "Unexpected or duplicate output");
                wanted = expected.pop_front();
                input_cycle = accepted_at.pop_front();
                if ({m_saturated, m_data} !== wanted) $fatal(1, "End-to-end data/flag mismatch at output %0d", reads);
                if (check_latency && clock_index-input_cycle != 4)
                    $fatal(1, "Expected four-clock external handshake latency");
                $fdisplay(events_file, "O %0d %0d", $signed(m_data), m_saturated);
                reads++;
                if (!enable) disabled_reads++;
                read_streak++;
                if (read_streak > max_read_streak) max_read_streak = read_streak;
            end else read_streak = 0;

            // The pulse belongs to production into the output FIFO, not to its
            // later external consumption. Check it against an independent queue.
            if (dut.core_valid && dut.output_ready) begin
                if (to_produce.size() == 0) $fatal(1, "Unexpected FIR production");
                generated = to_produce.pop_front();
                if ({dut.core_saturated, dut.core_data} !== generated || result_saturated !== generated[OUTPUT_WIDTH])
                    $fatal(1, "FIR production or saturation-event mismatch");
                if (result_saturated) saturation_events++;
            end else if (result_saturated) $fatal(1, "Saturation event without a production handshake");

            if (s_valid && s_ready) begin
                if ($isunknown(s_data)) $fatal(1, "Unknown accepted sample");
                wanted = reference_result(s_data);
                expected.push_back(wanted);
                to_produce.push_back(wanted);
                accepted_at.push_back(clock_index);
                writes++;
                $fdisplay(events_file, "I %0d", $signed(s_data));
            end
            if (expected.size() > max_pending) max_pending = expected.size();
            if (expected.size() > CAPACITY) $fatal(1, "Total buffering capacity exceeded");
        end
        #1;
        if (idle !== (expected.size() == 0)) $fatal(1, "Post-edge global idle mismatch");
        if (expected.size() != input_occupancy + output_occupancy + int'(dut.core.mul_valid) + int'(dut.core.out_valid))
            $fatal(1, "Pending count differs from FIFO plus pipeline occupancy");
        if (!resetn && (s_ready || m_valid || result_saturated || history_clear_accepted || !idle))
            $fatal(1, "Reset controls failed");
    end

    initial begin : stimulus
        logic [TAPS*COEFF_WIDTH-1:0] values;
        longint signed impulse, amplitude, min_product, other_min_product;
        int random_start, random_cycles;
        bit positive_possible, negative_possible;
        if ($value$plusargs("SEED=%d", seed)) begin end
        if ($value$plusargs("SAMPLES=%d", target_samples)) begin end
        if ($value$plusargs("EVENTS=%s", events_path)) begin end
        if (seed <= 0 || target_samples < 1 || target_samples > 100000)
            $fatal(1, "Require positive seed and 1..100000 samples");
        if (DATA_WIDTH+COEFF_WIDTH+$clog2(TAPS) > 62)
            $fatal(1, "Integer oracle supports at most 62 accumulator bits");
        events_file = $fopen(events_path, "w");
        if (events_file == 0) $fatal(1, "Cannot open event trace");
        $fdisplay(events_file, "P %0d %0d %0d %0d %0d %0d %0d", TAPS, DATA_WIDTH,
                  COEFF_WIDTH, OUTPUT_WIDTH, INPUT_FRAC_BITS, COEFF_FRAC_BITS, OUTPUT_FRAC_BITS);
        rng_state = seed;
        repeat (2) cycle(0, 0, 0, 0, 0);
        cycle(0, 0, 0, 0);

        // Known single-tap values isolate sign, floor shifting and output hold.
        values = 0;
        values[0 +: COEFF_WIDTH] = COEFF_WIDTH'(GAIN);
        configure_filter(values);
        check_single(DATA_WIDTH'(TEST_INPUT), clipped((TEST_INPUT*GAIN) >>> SHIFT));
        check_single(DATA_WIDTH'(-3), clipped((-64'sd3*GAIN) >>> SHIFT));
        check_single(DATA_WIDTH'(INPUT_MIN), clipped((INPUT_MIN*GAIN) >>> SHIFT));
        configure_filter(0);
        check_single(DATA_WIDTH'(INPUT_MAX), clipped(0));

        // Distinct alternating taps expose ordering/sign errors across both FIFOs.
        for (int k = 0; k < TAPS; k++) begin
            amplitude = (COEFF_FRAC_BITS > k+1) ? (64'sd1 << (COEFF_FRAC_BITS-k-1)) : 1;
            if (k % 2) amplitude = -amplitude;
            values[k*COEFF_WIDTH +: COEFF_WIDTH] = COEFF_WIDTH'(amplitude);
        end
        configure_filter(values);
        impulse = TEST_INPUT;
        for (int k = 0; k < TAPS; k++)
            check_single(DATA_WIDTH'((k == 0) ? impulse : 0),
                         clipped((impulse * $signed(values[k*COEFF_WIDTH +: COEFF_WIDTH])) >>> SHIFT));
        check_single(0, clipped(0));

        // Enable/disable between single samples must preserve sample history.
        // An enabled idle clear is illegal and must not erase a delayed impulse.
        values = 0;
        values[((TAPS > 1) ? 1 : 0)*COEFF_WIDTH +: COEFF_WIDTH] = COEFF_WIDTH'(GAIN);
        configure_filter(values);
        send_sample(DATA_WIDTH'(TEST_INPUT));
        drain();
        cycle(0, 0, 1, 1, 1, 1);
        check_single(0, (TAPS > 1) ? clipped((TEST_INPUT*GAIN) >>> SHIFT) : clipped(0));

        // Saturation rails followed by zero/nonclipping results exercise sideband
        // alignment. Exact positive rail and clipped positive rail look identical
        // in data alone for equal Q formats, but their flags must differ.
        values = 0;
        values[0 +: COEFF_WIDTH] = COEFF_WIDTH'(COEFF_MIN);
        configure_filter(values);
        check_single(DATA_WIDTH'(-INPUT_MAX), clipped((-INPUT_MAX*COEFF_MIN) >>> SHIFT));
        check_single(DATA_WIDTH'(INPUT_MIN), clipped((INPUT_MIN*COEFF_MIN) >>> SHIFT));
        check_single(0, clipped(0));
        configure_filter({TAPS{COEFF_WIDTH'(COEFF_MAX)}});
        repeat (32) send_sample(DATA_WIDTH'(INPUT_MAX));
        drain();
        configure_filter({TAPS{COEFF_WIDTH'(COEFF_MAX)}});
        repeat (32) send_sample(DATA_WIDTH'(INPUT_MIN));
        drain();
        configure_filter({TAPS{COEFF_WIDTH'(COEFF_MIN)}});
        repeat (32) send_sample(DATA_WIDTH'(INPUT_MIN));
        drain();

        // No-stall latency is 1 FIFO + 2 FIR + 1 FIFO = four clocks.
        configure_filter(values);
        check_latency = 1;
        repeat (1050) cycle(1, DATA_WIDTH'(TEST_INPUT), 1);
        drain();
        check_latency = 0;

        // Fully blocked output eventually fills both FIFOs and both FIR stages.
        // Disable with one word still offered: drain accepted work while keeping
        // that unaccepted word stable. Busy clear pulses cannot disturb history.
        configure_filter(values);
        fill_blocked();
        repeat (4) cycle(1, s_data, 0, 0, 1, 1);
        while (expected.size() != 0) cycle(1, s_data, 1, 0);
        repeat (3) cycle(1, s_data, 1, 0);
        cycle(1, s_data, 1);
        drain();

        // A held disabled clear waits for GLOBAL idle, including output FIFO.
        fill_blocked();
        while (expected.size() != 0) cycle(1, s_data, 1, 0, 1, 1);
        cycle(1, s_data, 1, 0, 1, 1);
        cycle(1, s_data, 1);
        drain();

        // Hardware reset, unlike clear, discards the complete buffered capacity.
        fill_blocked();
        repeat (2) cycle(0, 0, 0, 0, 0);
        cycle(0, 0, 1, 0);
        check_single(0, clipped(0));

        // Random enable gaps may hold a pending source transaction for many
        // cycles. Preserve it until acceptance; also force long receiver stalls.
        for (int k = 0; k < TAPS; k++) begin
            rng_state = next_random(rng_state);
            values[k*COEFF_WIDTH +: COEFF_WIDTH] = COEFF_WIDTH'(rng_state);
        end
        configure_filter(values);
        random_start = writes;
        random_cycles = 0;
        while (writes-random_start < target_samples) begin
            if (random_cycles++ > target_samples*40+1000) $fatal(1, "Random traffic timeout");
            rng_state = next_random(rng_state);
            if (source_blocked)
                cycle(1, s_data, (random_cycles % 251 >= 48) && rng_state[2], rng_state[3:2] != 0);
            else
                cycle(rng_state[1:0] != 0, DATA_WIDTH'(rng_state),
                      (random_cycles % 251 >= 48) && rng_state[2], rng_state[3:2] != 0);
        end
        drain();
        min_product = INPUT_MIN * COEFF_MAX;
        other_min_product = INPUT_MAX * COEFF_MIN;
        if (other_min_product < min_product) min_product = other_min_product;
        positive_possible = ((TAPS*(INPUT_MIN*COEFF_MIN)) >>> SHIFT) > OUTPUT_MAX;
        negative_possible = ((TAPS*min_product) >>> SHIFT) < OUTPUT_MIN;
        if (writes != reads+discarded || expected.size() != 0 || to_produce.size() != 0)
            $fatal(1, "Final transaction conservation failed");
        if (max_read_streak < 1024 || max_pending != CAPACITY || input_full == 0 || output_full == 0 ||
            input_stalls == 0 || output_stalls == 0 || disabled_reads == 0 || resets_with_data == 0 ||
            clears == 0 || rejected_clears == 0 || (positive_possible && positive_clips == 0) ||
            (negative_possible && negative_clips == 0) || (positive_possible && saturation_events == 0))
            $fatal(1, "Required integration coverage missing");
        $display("PASS: dsp_datapath taps=%0d input_width=%0d coeff_width=%0d output_width=%0d input_frac=%0d coeff_frac=%0d output_frac=%0d input_depth=%0d output_depth=%0d seed=%0d random_samples=%0d writes=%0d reads=%0d reset_discarded=%0d max_streak=%0d max_pending=%0d history_clears=%0d rejected_clears=%0d disabled_reads=%0d saturation_events=%0d",
                 TAPS, DATA_WIDTH, COEFF_WIDTH, OUTPUT_WIDTH, INPUT_FRAC_BITS, COEFF_FRAC_BITS,
                 OUTPUT_FRAC_BITS, INPUT_FIFO_DEPTH, OUTPUT_FIFO_DEPTH, seed, writes-random_start,
                 writes, reads, discarded, max_read_streak, max_pending, clears, rejected_clears,
                 disabled_reads, saturation_events);
        $display("COVERAGE: input_full=%0d output_full=%0d input_stalls=%0d output_stalls=%0d positive_clips=%0d negative_clips=%0d reset_with_data=%0d",
                 input_full, output_full, input_stalls, output_stalls, positive_clips, negative_clips, resets_with_data);
        $fclose(events_file);
        $finish;
    end

    initial begin
        #100000000;
        $fatal(1, "Datapath simulation watchdog timeout");
    end
endmodule
