`timescale 1ns/1ps

// Verification for the current fixed 8-tap, signed Q1.15 FIR core.
module tb_fir_core;
    logic clk = 0;
    logic resetn = 0;
    logic [127:0] coefficients = 0;
    logic signed [15:0] s_data = 0;
    logic s_valid = 0;
    wire s_ready;
    wire signed [15:0] m_data;
    wire m_valid;
    logic m_ready = 0;

    fir_core dut (
        .clk(clk), .resetn(resetn), .coefficients(coefficients),
        .s_data(s_data), .s_valid(s_valid), .s_ready(s_ready),
        .m_data(m_data), .m_valid(m_valid), .m_ready(m_ready)
    );

    always #5 clk = ~clk;

    logic [15:0] expected[$];
    int accepted_at[$];
    int signed model_history [0:7];
    logic [127:0] previous_coefficients = 0;
    int writes = 0, reads = 0, discarded = 0, clock_index = 0;
    int output_stalls = 0, input_stalls = 0, resets_with_data = 0;
    int positive_clips = 0, negative_clips = 0;
    int read_streak = 0, max_read_streak = 0;
    int seed = 1, target_samples = 10000;
    int events_file = 0;
    bit source_blocked = 0, check_latency = 0;
    logic [15:0] held_input;
    logic [31:0] rng_state = 1;
    string events_path = "fir_events.txt";

    function automatic logic [31:0] next_random(input logic [31:0] value);
        logic [31:0] result;
        result = value ^ (value << 13);
        result = result ^ (result >> 17);
        return result ^ (result << 5);
    endfunction

    // Behavioral oracle uses 64-bit integer arithmetic, independently of the
    // DUT's product registers and 35-bit adder implementation.
    function automatic logic [15:0] reference_result(input logic signed [15:0] sample);
        longint signed accumulator, shifted;
        int signed coefficient;
        for (int k = 7; k > 0; k--) model_history[k] = model_history[k-1];
        model_history[0] = sample;
        accumulator = 0;
        for (int k = 0; k < 8; k++) begin
            coefficient = $signed(coefficients[k*16 +: 16]);
            accumulator += longint'(model_history[k]) * longint'(coefficient);
        end
        shifted = accumulator >>> 15;
        if (shifted > 32767) begin
            positive_clips++;
            return 16'h7fff;
        end
        if (shifted < -32768) begin
            negative_clips++;
            return 16'h8000;
        end
        return shifted[15:0];
    endfunction

    // Drive only on falling edges; DUT state settles before this task returns.
    task automatic cycle(input bit valid_in, input logic [15:0] data_in,
                         input bit ready_out, input bit reset_value = 1);
        @(negedge clk);
        resetn = reset_value;
        s_valid = valid_in;
        s_data = data_in;
        m_ready = ready_out;
        @(posedge clk);
        #1;
    endtask

    task automatic drain;
        int attempts;
        attempts = 0;
        while (source_blocked || expected.size() != 0) begin
            if (attempts++ > 32) $fatal(1, "Pipeline failed to drain");
            if (source_blocked) cycle(1, s_data, 1);
            else cycle(0, 0, 1);
        end
        // Catch delayed duplicates even after the expected queue becomes empty.
        repeat (4) cycle(0, 0, 1);
    endtask

    // External coefficients are changed only while the core is held in reset.
    task automatic configure_filter(input logic [127:0] values);
        drain();
        @(negedge clk);
        resetn = 0;
        s_valid = 0;
        m_ready = 0;
        coefficients = values;
        for (int k = 0; k < 8; k++)
            $fdisplay(events_file, "C %0d %0d", k, $signed(values[k*16 +: 16]));
        cycle(0, 0, 0, 0);
        cycle(0, 0, 0, 0);
        cycle(0, 0, 0);
        if (s_ready !== 1'b1 || m_valid !== 1'b0)
            $fatal(1, "Reset release flags failed");
    endtask

    task automatic send_sample(input logic [15:0] value, input bit ready_out);
        int attempts;
        attempts = 0;
        do begin
            if (attempts++ > 32) $fatal(1, "Input was not accepted");
            cycle(1, value, ready_out);
        end while (source_blocked);
    endtask

    // Hand-calculated checks protect against an error shared by both models.
    task automatic check_single(input logic [15:0] sample,
                                input logic [15:0] literal_expected);
        int attempts;
        send_sample(sample, 0);
        attempts = 0;
        while (m_valid !== 1'b1) begin
            if (attempts++ > 8) $fatal(1, "Output valid did not arrive");
            cycle(0, 0, 0);
        end
        if (m_data !== literal_expected)
            $fatal(1, "Directed check: input=%h expected=%h actual=%h", sample, literal_expected, m_data);
        repeat (2) cycle(0, 0, 0);
        drain();
    endtask

    property output_stays_stable;
        @(posedge clk) disable iff (!resetn)
            m_valid && !m_ready |=> m_valid && $stable(m_data);
    endproperty
    assert property (output_stays_stable)
        else $fatal(1, "Output changed under backpressure");

    property source_stays_stable;
        @(posedge clk) disable iff (!resetn)
            s_valid && !s_ready |=> s_valid && $stable(s_data);
    endproperty
    assert property (source_stays_stable)
        else $fatal(1, "Testbench changed a blocked input");

    // Sample handshakes before NBA updates, comparing outputs before new inputs.
    always @(posedge clk) begin : scoreboard
        logic [15:0] wanted;
        int input_cycle;
        clock_index++;
        if (!resetn) begin
            if (expected.size() != 0) resets_with_data++;
            discarded += expected.size();
            expected.delete();
            accepted_at.delete();
            for (int k = 0; k < 8; k++) model_history[k] = 0;
            source_blocked = 0;
            read_streak = 0;
            previous_coefficients = coefficients;
            $fdisplay(events_file, "R");
            #1;
            if (m_valid !== 1'b0 || s_ready !== 1'b0)
                $fatal(1, "Reset flags failed");
        end else begin
            if (s_ready !== 1'b0 && s_ready !== 1'b1) $fatal(1, "Unknown s_ready");
            if (m_valid !== 1'b0 && m_valid !== 1'b1) $fatal(1, "Unknown m_valid");
            if (expected.size() != 0 && coefficients !== previous_coefficients)
                $fatal(1, "Coefficients changed with data in flight");
            previous_coefficients = coefficients;
            if (source_blocked && (s_valid !== 1'b1 || s_data !== held_input))
                $fatal(1, "Blocked source payload changed");
            if (s_valid && !s_ready) input_stalls++;
            if (m_valid && !m_ready) output_stalls++;
            source_blocked = s_valid && !s_ready;
            held_input = s_data;

            if (m_valid && m_ready) begin
                if (expected.size() == 0) $fatal(1, "Unexpected/duplicate output");
                wanted = expected.pop_front();
                input_cycle = accepted_at.pop_front();
                if (m_data !== wanted)
                    $fatal(1, "FIR mismatch output=%0d expected=%h actual=%h", reads, wanted, m_data);
                if (check_latency && clock_index - input_cycle != 2)
                    $fatal(1, "Expected two-cycle handshake latency without stalls");
                $fdisplay(events_file, "O %0d", $signed(m_data));
                reads++;
                read_streak++;
                if (read_streak > max_read_streak) max_read_streak = read_streak;
            end else read_streak = 0;
            if (s_valid && s_ready) begin
                if ($isunknown(s_data)) $fatal(1, "Unknown accepted input");
                expected.push_back(reference_result(s_data));
                accepted_at.push_back(clock_index);
                $fdisplay(events_file, "I %0d", $signed(s_data));
                writes++;
            end
        end
    end

    initial begin : stimulus
        logic [127:0] values;
        int random_start, random_cycles;
        if ($value$plusargs("SEED=%d", seed)) begin end
        if ($value$plusargs("SAMPLES=%d", target_samples)) begin end
        if ($value$plusargs("EVENTS=%s", events_path)) begin end
        if (seed <= 0 || target_samples < 1 || target_samples > 100000)
            $fatal(1, "Require positive SEED and 1 <= SAMPLES <= 100000");
        events_file = $fopen(events_path, "w");
        if (events_file == 0) $fatal(1, "Cannot open event export");
        rng_state = seed;

        values = 0;
        values[15:0] = 16'sd16384;
        configure_filter(values);
        check_single(16'sd10000, 16'sd5000);
        check_single(16'sd1, 16'sd0);
        check_single(-16'sd1, -16'sd1);
        check_single(16'sd3, 16'sd1);
        check_single(-16'sd3, -16'sd2);
        check_single(16'h7fff, 16'sd16383);
        check_single(16'h8000, -16'sd16384);
        $display("PASS directed: half gain, signed floor shifting and blocked output");

        configure_filter(128'd0);
        check_single(16'h7fff, 16'd0);
        check_single(16'h8000, 16'd0);
        $display("PASS directed: zero coefficients");

        // Little-endian tap packing: coefficient 0 is the low 16 bits.
        values = { -16'sd128, 16'sd256, -16'sd512, 16'sd1024,
                   -16'sd2048, 16'sd4096, -16'sd8192, 16'sd16384 };
        configure_filter(values);
        check_single(16'sd16384, 16'sd8192);
        check_single(0, -16'sd4096);
        check_single(0, 16'sd2048);
        check_single(0, -16'sd1024);
        check_single(0, 16'sd512);
        check_single(0, -16'sd256);
        check_single(0, 16'sd128);
        check_single(0, -16'sd64);
        check_single(0, 0);
        $display("PASS directed: all eight impulse taps and history across traffic gaps");

        configure_filter({8{16'h7fff}});
        repeat (32) send_sample(16'h7fff, 1);
        drain();
        configure_filter({8{16'h7fff}});
        repeat (32) send_sample(16'h8000, 1);
        drain();
        configure_filter({8{16'h8000}});
        repeat (32) send_sample(16'h8000, 1);
        drain();
        $display("PASS directed: positive/negative saturation and full accumulator precision");

        configure_filter(values);
        check_latency = 1;
        for (int k = 0; k < 1050; k++) cycle(1, 16'h4000 + k, 1);
        drain();
        check_latency = 0;
        $display("PASS directed: continuous streaming, 1024+ output transfers and two-cycle latency");

        // Both valid stages are occupied and a third input is blocked at reset.
        values = 0;
        values[31:16] = 16'sd16384;
        configure_filter(values);
        send_sample(16'sd10000, 0);
        send_sample(16'sd20000, 0);
        cycle(1, 16'sd30000, 0);
        if (!source_blocked || m_valid !== 1'b1) $fatal(1, "Reset fixture did not fill the pipeline");
        cycle(0, 0, 0, 0);
        cycle(0, 0, 0, 0);
        cycle(0, 0, 1);
        check_single(0, 0);
        check_single(16'sd10000, 0);
        check_single(0, 16'sd5000);
        $display("PASS directed: reset with blocked input/output, discard and cleared history");

        // Seeded, full-range coefficients and samples; hold any blocked input.
        for (int k = 0; k < 8; k++) begin
            rng_state = next_random(rng_state);
            values[k*16 +: 16] = rng_state[15:0];
        end
        configure_filter(values);
        random_start = writes;
        random_cycles = 0;
        while (writes - random_start < target_samples) begin
            if (random_cycles++ > target_samples * 30 + 1000)
                $fatal(1, "Random traffic progress timeout");
            rng_state = next_random(rng_state);
            if (source_blocked)
                cycle(1, s_data, (random_cycles % 251 >= 24) && rng_state[2]);
            else
                cycle(rng_state[1:0] != 0, rng_state[31:16],
                      (random_cycles % 251 >= 24) && rng_state[2]);
        end
        drain();
        if (writes != reads + discarded || expected.size() != 0)
            $fatal(1, "Final transfer accounting failed");
        if (max_read_streak < 1024 || positive_clips == 0 || negative_clips == 0 ||
            input_stalls == 0 || output_stalls == 0 || resets_with_data == 0)
            $fatal(1, "Required scenario coverage missing");
        $display("PASS: fir_core seed=%0d random_samples=%0d writes=%0d reads=%0d reset_discarded=%0d max_streak=%0d",
                 seed, writes-random_start, writes, reads, discarded, max_read_streak);
        $display("COVERAGE: input_stalls=%0d output_stalls=%0d positive_clips=%0d negative_clips=%0d reset_with_data=%0d",
                 input_stalls, output_stalls, positive_clips, negative_clips, resets_with_data);
        $fclose(events_file);
        $finish;
    end

    initial begin
        #100000000;
        $fatal(1, "FIR testbench watchdog timeout");
    end
endmodule 
