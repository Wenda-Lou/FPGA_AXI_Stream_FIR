`timescale 1ns/1ps

// Each cycle drives on a falling edge and checks after the next rising edge.
// The scoreboard observes ports only, independently of DUT pointers and RAM.
module tb_axis_fifo #(
    parameter integer DATA_WIDTH = 16,
    parameter integer DEPTH = 16
);
    logic clk = 0;
    logic resetn = 0;
    logic [DATA_WIDTH-1:0] s_data = 0;
    logic s_valid = 0;
    wire s_ready;
    wire [DATA_WIDTH-1:0] m_data;
    wire m_valid;
    logic m_ready = 0;
    wire [$clog2(DEPTH):0] occupancy;

    axis_fifo #(.DATA_WIDTH(DATA_WIDTH), .DEPTH(DEPTH)) dut (
        .clk(clk), .resetn(resetn),
        .s_data(s_data), .s_valid(s_valid), .s_ready(s_ready),
        .m_data(m_data), .m_valid(m_valid), .m_ready(m_ready),
        .occupancy(occupancy)
    );

    always #5 clk = ~clk;

    // The queue stores accepted inputs; it does not inspect DUT memory/pointers.
    logic [DATA_WIDTH-1:0] expected[$];
    logic [DATA_WIDTH-1:0] expected_word;
    logic [DATA_WIDTH-1:0] held_input, held_output;
    bit input_stalled = 0;
    bit output_stalled = 0;
    int writes = 0, reads = 0, discarded = 0;
    int simultaneous = 0, full_blocks = 0, empty_reads = 0;
    int stalled_outputs = 0, resets_with_data = 0, full_read_writes = 0;
    int resets_with_blocked_input = 0, empty_read_writes = 0;
    int simultaneous_streak = 0, max_simultaneous_streak = 0;
    int seed = 1, target_samples = 10000;
    int random_start_writes, random_cycles = 0;
    int unsigned rng_state;
    logic [31:0] random_word;

    // Reproducible local PRNG, independent of simulator-global random state.
    function automatic logic [31:0] next_random(input logic [31:0] value);
        logic [31:0] result;
        result = value ^ (value << 13);
        result = result ^ (result >> 17);
        return result ^ (result << 5);
    endfunction

    // Drive on falling edges, then allow rising-edge nonblocking updates to settle.
    task automatic cycle(input bit valid_in, input logic [DATA_WIDTH-1:0] data_in,
                         input bit ready_out, input bit reset_value = 1);
        @(negedge clk);
        resetn = reset_value;
        s_valid = valid_in;
        s_data = data_in;
        m_ready = ready_out;
        @(posedge clk);
        #1;
    endtask

    property output_stays_stable;
        @(posedge clk) disable iff (!resetn)
            m_valid && !m_ready |=> m_valid && $stable(m_data);
    endproperty
    assert property (output_stays_stable)
        else $fatal(1, "Output stability assertion failed");

    property source_stays_stable;
        @(posedge clk) disable iff (!resetn)
            s_valid && !s_ready |=> s_valid && $stable(s_data);
    endproperty
    assert property (source_stays_stable)
        else $fatal(1, "Testbench source violated ready/valid");

    // Check handshakes using pre-edge values; check occupancy after DUT updates.
    always @(posedge clk) begin
        if (!resetn) begin
            if (expected.size() != 0) resets_with_data++;
            if (input_stalled) resets_with_blocked_input++;
            discarded += expected.size();
            expected.delete();
            input_stalled = 0;
            output_stalled = 0;
            simultaneous_streak = 0;
            #1;
            if (occupancy !== 0 || s_ready !== 1'b0 || m_valid !== 1'b0)
                $fatal(1, "Reset state failed");
        end else begin
            assert (occupancy <= DEPTH)
                else $fatal(1, "Occupancy out of bounds");
            if (occupancy !== expected.size())
                $fatal(1, "Occupancy mismatch: expected=%0d actual=%0d", expected.size(), occupancy);
            if (s_ready !== (expected.size() < DEPTH) || m_valid !== (expected.size() != 0))
                $fatal(1, "Ready/valid mismatch at occupancy %0d", expected.size());
            if (input_stalled && (s_valid !== 1'b1 || s_data !== held_input))
                $fatal(1, "Testbench changed an unaccepted input");
            if (output_stalled && (m_valid !== 1'b1 || m_data !== held_output))
                $fatal(1, "Output changed while stalled");

            if (expected.size() == DEPTH && s_valid && !s_ready) full_blocks++;
            if (expected.size() == 0 && m_ready && !m_valid) empty_reads++;
            if (expected.size() == DEPTH && s_valid && m_ready) full_read_writes++;
            if (expected.size() == 0 && s_valid && m_ready) empty_read_writes++;
            if (s_valid && s_ready && m_valid && m_ready) begin
                simultaneous++;
                simultaneous_streak++;
                if (simultaneous_streak > max_simultaneous_streak)
                    max_simultaneous_streak = simultaneous_streak;
            end else simultaneous_streak = 0;
            if (m_valid && !m_ready) stalled_outputs++;

            input_stalled = s_valid && !s_ready;
            output_stalled = m_valid && !m_ready;
            held_input = s_data;
            held_output = m_data;

            // Pop first: a newly accepted input cannot bypass an empty FIFO.
            if (m_valid && m_ready) begin
                if (expected.size() == 0) $fatal(1, "Unexpected output");
                expected_word = expected.pop_front();
                if (m_data !== expected_word)
                    $fatal(1, "Data mismatch: expected=%h actual=%h", expected_word, m_data);
                reads++;
            end
            if (s_valid && s_ready) begin
                expected.push_back(s_data);
                writes++;
            end
            #1;
            if (occupancy !== expected.size())
                $fatal(1, "Post-edge occupancy mismatch");
        end
    end

    initial begin
        if ($value$plusargs("SEED=%d", seed)) begin end
        if ($value$plusargs("SAMPLES=%d", target_samples)) begin end
        if (seed <= 0 || target_samples < 1 || target_samples > 100000)
            $fatal(1, "Require SEED > 0 and 1 <= SAMPLES <= 100000");
        rng_state = seed;

        cycle(0, 0, 0, 0);
        cycle(0, 0, 1);
        $display("PASS directed: reset and empty read protection");

        // Preserve the original single-write, hold, then read exercise.
        cycle(1, 16'h1234, 0);
        repeat (2) cycle(0, 0, 0);
        cycle(0, 0, 1);
        cycle(0, 0, 1);
        $display("PASS directed: single write/read and hold");

        // Multiple distinct payloads, including the high bit and all ones.
        // Interleaved reads keep this valid even for the minimum depth of 2.
        cycle(1, {DATA_WIDTH{1'b1}}, 0);
        cycle(1, {1'b1, {(DATA_WIDTH-1){1'b0}}}, 0);
        cycle(0, 0, 1);
        cycle(1, 16'h3333, 0);
        repeat (2) cycle(0, 0, 1);
        $display("PASS directed: payload width and ordered multi-sample traffic");

        // Fill, reject a held input, read from full, then accept that input.
        for (int i = 0; i < DEPTH; i++) cycle(1, 16'h9000 + i, 0);
        repeat (3) cycle(1, 16'hcafe, 0);
        cycle(1, 16'hcafe, 1);
        cycle(1, 16'hcafe, 0);
        repeat (DEPTH) cycle(0, 0, 1);
        cycle(0, 0, 1);
        $display("PASS directed: full protection and simultaneous requests at full");

        // Sustain simultaneous transfers and wrap both pointers repeatedly.
        cycle(1, 16'h2222, 0);
        for (int i = 0; i < 1024; i++) cycle(1, 16'h4000 + i, 1);
        cycle(0, 0, 1);
        $display("PASS directed: pointer wraparound and 1024-cycle continuous throughput");

        // Hardware reset deliberately discards queued, stalled output data.
        repeat (DEPTH) cycle(1, 16'hdead, 0);
        cycle(1, 16'hbeef, 0);
        cycle(0, 0, 0, 0);
        cycle(0, 0, 1);
        cycle(1, 16'h002a, 1);
        cycle(0, 0, 1);
        $display("PASS directed: reset while full with blocked input and output; restart");

        // A blocked source keeps valid and payload stable until acceptance.
        random_start_writes = writes;
        while (writes - random_start_writes < target_samples) begin
            if (random_cycles >= target_samples * 20 + 1000)
                $fatal(1, "Random traffic made insufficient forward progress");
            rng_state = next_random(rng_state);
            random_word = rng_state;
            if (input_stalled)
                cycle(1, s_data, (random_cycles % 251 >= 24) && random_word[2]);
            else
                cycle(random_word[1:0] != 0, random_word[31:16],
                      (random_cycles % 251 >= 24) && random_word[2]);
            random_cycles++;
        end

        // Finish any pending source transfer, then drain every expected result.
        while (input_stalled) cycle(1, s_data, 1);
        while (expected.size() != 0) cycle(0, 0, 1);
        cycle(0, 0, 1);
        if (writes != reads + discarded)
            $fatal(1, "Transfer accounting failed");
        if (max_simultaneous_streak < 1024 || full_blocks == 0 || empty_reads == 0 ||
            stalled_outputs == 0 || resets_with_data == 0 || full_read_writes == 0 ||
            empty_read_writes == 0 || resets_with_blocked_input == 0)
            $fatal(1, "Required scenario coverage missing");

        $display("PASS: axis_fifo width=%0d depth=%0d seed=%0d random_samples=%0d random_cycles=%0d writes=%0d reads=%0d reset_discarded=%0d max_streak=%0d",
                 DATA_WIDTH, DEPTH, seed, writes - random_start_writes, random_cycles,
                 writes, reads, discarded, max_simultaneous_streak);
        $display("COVERAGE: simultaneous=%0d full_blocks=%0d empty_reads=%0d output_stalls=%0d reset_with_data=%0d full_read_write=%0d empty_read_write=%0d reset_blocked_input=%0d",
                 simultaneous, full_blocks, empty_reads, stalled_outputs, resets_with_data,
                 full_read_writes, empty_read_writes, resets_with_blocked_input);
        $finish;
    end

    initial begin
        #100000000;
        $fatal(1, "FIFO test timeout");
    end
endmodule
