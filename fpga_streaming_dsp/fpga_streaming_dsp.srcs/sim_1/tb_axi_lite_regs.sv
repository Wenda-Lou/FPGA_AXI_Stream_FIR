`timescale 1ns/1ps

// Register-bank unit test. External datapath events are modeled inputs here;
// no FIR arithmetic or FIFO behavior is assumed. All bus transfers and register
// side effects are checked against a separate model of the published register map.
module tb_axi_lite_regs #(
    parameter integer TAPS = 8,
    parameter integer COEFF_WIDTH = 16
);
    logic clk = 0, resetn = 0;
    logic [7:0] s_axi_awaddr = 0, s_axi_araddr = 0;
    logic [2:0] s_axi_awprot = 0, s_axi_arprot = 0;
    logic s_axi_awvalid = 0, s_axi_wvalid = 0, s_axi_arvalid = 0;
    logic s_axi_bready = 0, s_axi_rready = 0;
    logic [31:0] s_axi_wdata = 0;
    logic [3:0] s_axi_wstrb = 0;
    wire s_axi_awready, s_axi_wready, s_axi_bvalid, s_axi_arready, s_axi_rvalid;
    wire [1:0] s_axi_bresp, s_axi_rresp;
    wire [31:0] s_axi_rdata;
    logic datapath_idle = 1, input_transfer = 0, output_transfer = 0, saturation_event = 0;
    wire enable, history_clear, soft_clear;
    wire [TAPS*COEFF_WIDTH-1:0] coefficients;
    axi_lite_regs #(.TAPS(TAPS), .COEFF_WIDTH(COEFF_WIDTH)) dut (.*);
    always #5 clk = ~clk;

    // Expected register state and transaction slots. Decode uses byte masks
    // and integer address arithmetic rather than the DUT's bit-update logic.
    bit model_enable = 0, model_saturated = 0;
    logic [31:0] model_inputs = 0, model_outputs = 0;
    logic [COEFF_WIDTH-1:0] model_coeff [0:TAPS-1];
    bit aw_held = 0, w_held = 0, b_pending = 0, r_pending = 0;
    logic [7:0] saved_address;
    logic [31:0] saved_data, expected_rdata;
    logic [3:0] saved_strobes;
    logic [1:0] expected_bresp, expected_rresp;
    int clock_index = 0, aw_at = 0, w_at = 0;
    int commits = 0, write_responses = 0, read_responses = 0;
    int aw_captures = 0, w_captures = 0, ar_captures = 0;
    int reset_aw = 0, reset_w = 0, reset_b = 0, reset_r = 0;
    int aw_first = 0, w_first = 0, simultaneous = 0, errors = 0;
    int b_stalls = 0, r_stalls = 0, overlapping_reads_writes = 0;
    int clear_pulses = 0, soft_clears = 0, coefficient_writes = 0;
    int blocked_aw = 0, blocked_w = 0, blocked_ar = 0, resets = 0;
    int seed = 1, target_transactions = 2000;
    logic [31:0] rng_state = 1, event_rng = 7;
    bit random_events = 0;

    function automatic logic [31:0] next_random(input logic [31:0] value);
        logic [31:0] result;
        result = value ^ (value << 13);
        result = result ^ (result >> 17);
        return result ^ (result << 5);
    endfunction

    // A read snapshots the old state, including status and counter event races.
    // Pack response above data so invalid reads can be checked as {SLVERR, 0}.
    function automatic logic [33:0] read_model(input logic [7:0] address);
        int index;
        logic [31:0] value;
        if (address % 4 != 0) return {2'b10, 32'd0};
        case (address)
            0: return {2'b00, 31'd0, model_enable};
            4: return {2'b00, 29'd0, model_saturated, !datapath_idle, datapath_idle};
            8: return {2'b00, model_inputs};
            12: return {2'b00, model_outputs};
            default: begin
                index = (int'(address)-32)/4;
                if (address >= 32 && index >= 0 && index < TAPS) begin
                    value = $signed(model_coeff[index]);
                    return {2'b00, value};
                end
                return {2'b10, 32'd0};
            end
        endcase
    endfunction

    // This unit-test event source is independent of the bus driver. It exercises
    // live counters/status changing while read/write responses remain stalled.
    always @(negedge clk) begin
        if (random_events) begin
            event_rng = next_random(event_rng);
            datapath_idle = event_rng[0];
            input_transfer = enable && event_rng[1];
            output_transfer = event_rng[2];
            saturation_event = event_rng[7:3] == 0;
        end
    end

    // Drive AXI channels on falling edges and sample ready BEFORE NBA updates.
    // order=0: same edge, 1: AW three clocks first, 2: W three clocks first.
    task automatic write_reg(input logic [7:0] address, input logic [31:0] data,
                             input logic [3:0] strobes = 15, input int order = 0,
                             input int stall = 0, input bit literal_check = 0,
                             input logic [1:0] response = 0);
        fork
            begin
                repeat ((order == 2) ? 3 : 0) @(negedge clk);
                @(negedge clk);
                s_axi_awaddr = address;
                s_axi_awprot = data[6:4];
                s_axi_awvalid = 1;
                do @(posedge clk); while (!s_axi_awready);
                @(negedge clk);
                s_axi_awvalid = 0;
            end
            begin
                repeat ((order == 1) ? 3 : 0) @(negedge clk);
                @(negedge clk);
                s_axi_wdata = data;
                s_axi_wstrb = strobes;
                s_axi_wvalid = 1;
                do @(posedge clk); while (!s_axi_wready);
                @(negedge clk);
                s_axi_wvalid = 0;
            end
            begin
                wait (s_axi_bvalid);
                repeat (stall+1) @(negedge clk);
                s_axi_bready = 1;
                @(posedge clk);
                if (literal_check && s_axi_bresp !== response)
                    $fatal(1, "Literal write response mismatch address=%h", address);
                @(negedge clk);
                s_axi_bready = 0;
            end
        join
    endtask

    task automatic read_reg(input logic [7:0] address, input int stall = 0,
                            input bit literal_check = 0, input logic [31:0] value = 0,
                            input logic [1:0] response = 0);
        @(negedge clk);
        s_axi_araddr = address;
        s_axi_arprot = 3'b101;
        s_axi_arvalid = 1;
        do @(posedge clk); while (!s_axi_arready);
        @(negedge clk);
        s_axi_arvalid = 0;
        repeat (stall) @(negedge clk);
        s_axi_rready = 1;
        do @(posedge clk); while (!s_axi_rvalid);
        if (literal_check && {s_axi_rresp, s_axi_rdata} !== {response, value})
            $fatal(1, "Literal read mismatch address=%h expected=%h actual=%h", address, value, s_axi_rdata);
        @(negedge clk);
        s_axi_rready = 0;
    endtask

    task automatic reset_bus;
        random_events = 0;
        @(negedge clk);
        resetn = 0;
        s_axi_awvalid = 0; s_axi_wvalid = 0; s_axi_arvalid = 0;
        s_axi_bready = 0; s_axi_rready = 0;
        input_transfer = 0; output_transfer = 0; saturation_event = 0;
        datapath_idle = 1;
        repeat (2) begin @(posedge clk); #1; end
        @(negedge clk);
        resetn = 1;
        @(posedge clk);
        #1;
    endtask

    task automatic pulse_events(input bit in_event, input bit out_event,
                                input bit sat_event, input int cycles = 1);
        repeat (cycles) begin
            @(negedge clk);
            input_transfer = in_event; output_transfer = out_event; saturation_event = sat_event;
            @(posedge clk);
            #1;
        end
        @(negedge clk);
        input_transfer = 0; output_transfer = 0; saturation_event = 0;
    endtask

    // Slave response payloads must survive arbitrary receiver backpressure.
    assert property (@(posedge clk) disable iff (!resetn)
        s_axi_bvalid && !s_axi_bready |=> s_axi_bvalid && $stable(s_axi_bresp))
        else $fatal(1, "B response changed while blocked");
    assert property (@(posedge clk) disable iff (!resetn)
        s_axi_rvalid && !s_axi_rready |=> s_axi_rvalid && $stable({s_axi_rresp,s_axi_rdata}))
        else $fatal(1, "R response changed while blocked");
    // Check the master too, so invalid stimulus cannot conceal a slave failure.
    assert property (@(posedge clk) disable iff (!resetn)
        s_axi_awvalid && !s_axi_awready |=> s_axi_awvalid && $stable({s_axi_awaddr,s_axi_awprot}))
        else $fatal(1, "Master changed blocked AW");
    assert property (@(posedge clk) disable iff (!resetn)
        s_axi_wvalid && !s_axi_wready |=> s_axi_wvalid && $stable({s_axi_wdata,s_axi_wstrb}))
        else $fatal(1, "Master changed blocked W");
    assert property (@(posedge clk) disable iff (!resetn)
        s_axi_arvalid && !s_axi_arready |=> s_axi_arvalid && $stable({s_axi_araddr,s_axi_arprot}))
        else $fatal(1, "Master changed blocked AR");

    always @(posedge clk) begin : monitor
        bit aw_take, w_take, ar_take, commit_now, ok, effective, coeff_addr, clear_request;
        int index;
        logic [33:0] snapshot;
        logic [31:0] mask, merged;
        clock_index++;
        if (!resetn) begin
            // Only the first reset edge can discard each outstanding slot.
            // Partial AW/W and committed-but-unconsumed B are distinct cases.
            if (aw_held) reset_aw++;
            if (w_held) reset_w++;
            if (b_pending) reset_b++;
            if (r_pending) reset_r++;
            aw_held = 0; w_held = 0; b_pending = 0; r_pending = 0;
            model_enable = 0; model_saturated = 0; model_inputs = 0; model_outputs = 0;
            for (int t = 0; t < TAPS; t++) model_coeff[t] = 0;
            resets++;
        end else begin
            // Validate advertised capacity before using the observed handshakes.
            if ({s_axi_awready,s_axi_wready,s_axi_arready} !==
                {!aw_held && !b_pending,!w_held && !b_pending,!r_pending})
                $fatal(1, "AXI channel capacity/ordering mismatch");
            if ({s_axi_bvalid,s_axi_rvalid} !== {b_pending,r_pending})
                $fatal(1, "AXI response valid mismatch");
            if (b_pending && s_axi_bresp !== expected_bresp) $fatal(1, "B response mismatch");
            if (r_pending && {s_axi_rresp,s_axi_rdata} !== {expected_rresp,expected_rdata})
                $fatal(1, "R snapshot mismatch address=%h", s_axi_araddr);
            aw_take = s_axi_awvalid && s_axi_awready;
            w_take = s_axi_wvalid && s_axi_wready;
            ar_take = s_axi_arvalid && s_axi_arready;
            commit_now = aw_held && w_held && !b_pending;
            snapshot = read_model(s_axi_araddr);

            // Independent register-map policy: effective byte-mask intersection,
            // aligned addresses, and atomic validation before any state update.
            index = (int'(saved_address)-32)/4;
            coeff_addr = saved_address >= 32 && index >= 0 && index < TAPS;
            effective = (saved_strobes & ((1 << ((COEFF_WIDTH+7)/8))-1)) != 0;
            clear_request = saved_address == 0 && saved_strobes[0] && saved_data[1];
            ok = 0;
            if (saved_address % 4 == 0) begin
                if (saved_address == 0) ok = !clear_request || (!model_enable && datapath_idle && !saved_data[0]);
                else if (coeff_addr) ok = !effective || (!model_enable && datapath_idle);
            end
            if (history_clear !== (commit_now && ok && (clear_request || (coeff_addr && effective))) ||
                soft_clear !== (commit_now && ok && clear_request))
                $fatal(1, "Commit-edge clear qualification mismatch");

            if (s_axi_bvalid && !s_axi_bready) b_stalls++;
            if (s_axi_rvalid && !s_axi_rready) r_stalls++;
            if (s_axi_awvalid && !s_axi_awready) blocked_aw++;
            if (s_axi_wvalid && !s_axi_wready) blocked_w++;
            if (s_axi_arvalid && !s_axi_arready) blocked_ar++;
            if (b_pending && s_axi_bready) begin b_pending = 0; write_responses++; end
            if (r_pending && s_axi_rready) begin r_pending = 0; read_responses++; end
            if (ar_take) begin
                ar_captures++;
                {expected_rresp,expected_rdata} = snapshot;
                r_pending = 1;
                if (commit_now) overlapping_reads_writes++;
            end

            if (commit_now && ok && clear_request) begin
                model_inputs = 0; model_outputs = 0; model_saturated = 0;
            end else begin
                if (input_transfer) model_inputs++;
                if (output_transfer) model_outputs++;
                if (saturation_event) model_saturated = 1;
            end
            if (commit_now) begin
                commits++;
                if (aw_at < w_at) aw_first++;
                else if (w_at < aw_at) w_first++;
                else simultaneous++;
                if (!ok) errors++;
                expected_bresp = ok ? 2'b00 : 2'b10;
                b_pending = 1; aw_held = 0; w_held = 0;
                if (ok) begin
                    if (saved_address == 0 && saved_strobes[0]) model_enable = saved_data[0];
                    if (clear_request) soft_clears++;
                    if (clear_request || (coeff_addr && effective)) clear_pulses++;
                    if (coeff_addr && effective) begin
                        mask = 0;
                        for (int b = 0; b < 4; b++) if (saved_strobes[b]) mask |= (32'hff << (b*8));
                        merged = (32'(model_coeff[index]) & ~mask) | (saved_data & mask);
                        model_coeff[index] = COEFF_WIDTH'(merged);
                        coefficient_writes++;
                    end
                end
            end
            if (aw_take) begin aw_captures++; aw_held = 1; saved_address = s_axi_awaddr; aw_at = clock_index; end
            if (w_take) begin w_captures++; w_held = 1; saved_data = s_axi_wdata; saved_strobes = s_axi_wstrb; w_at = clock_index; end
        end
        #1;
        if (enable !== model_enable) $fatal(1, "ENABLE side effect mismatch");
        for (int t = 0; t < TAPS; t++)
            if (coefficients[t*COEFF_WIDTH +: COEFF_WIDTH] !== model_coeff[t])
                $fatal(1, "Coefficient side effect mismatch tap=%0d", t);
        if (!resetn && (s_axi_awready || s_axi_wready || s_axi_arready ||
                       s_axi_bvalid || s_axi_rvalid || history_clear || soft_clear))
            $fatal(1, "Reset did not mask AXI transfers");
    end

    initial begin : stimulus
        logic [31:0] word1, word2;
        logic [7:0] address1, address2;
        int count_start;
        if ($value$plusargs("SEED=%d", seed)) begin end
        if ($value$plusargs("TRANSACTIONS=%d", target_transactions)) begin end
        if (seed <= 0 || target_transactions < 1 || target_transactions > 100000)
            $fatal(1, "Require positive seed and 1..100000 transactions");
        rng_state = seed;
        event_rng = seed ^ 32'h935817;
        reset_bus();
        read_reg(0,0,1,0); read_reg(4,0,1,1); read_reg(8,0,1,0); read_reg(12,0,1,0);

        // Program/read every coefficient, including the highest mapped address.
        for (int t = 0; t < TAPS; t++) begin
            write_reg(8'(32+4*t), 32'hffffffff, 15, t%3, 3, 1, 0);
            read_reg(8'(32+4*t), 3, 1, 32'hffffffff);
        end
        // All 16 byte-strobe patterns, including zero and unused high lanes.
        for (int strobe = 0; strobe < 16; strobe++) begin
            write_reg(32, (strobe%2) ? 32'h89abcdef : 32'h12345678, 4'(strobe), strobe%3, 2, 1, 0);
            read_reg(32,2);
        end
        write_reg(1,0,0,0,0,1,2); write_reg(4,0,0,0,0,1,2);
        write_reg(8,1,15,1,0,1,2); write_reg(12,1,15,2,0,1,2);
        write_reg(16,0,15,0,0,1,2); write_reg(255,0,15,0,0,1,2);
        read_reg(1,0,1,0,2); read_reg(16,0,1,0,2); read_reg(255,0,1,0,2);

        // While enabled, coefficient/soft-clear commands fail atomically. Zero
        // effective lanes remain legal no-ops, even when datapath_idle is false.
        write_reg(0,1,1,0,0,1,0);
        @(negedge clk); datapath_idle = 0;
        write_reg(32,0,1,0,3,1,2);
        write_reg(0,2,1,1,3,1,2); write_reg(0,3,1,2,3,1,2);
        write_reg(32,0,0,0,0,1,0); write_reg(0,2,0,0,0,1,0);
        write_reg(0,2,14,0,0,1,0);
        if (COEFF_WIDTH < 25) write_reg(32,0,8,0,0,1,0);
        read_reg(0,0,1,1);
        pulse_events(1,1,1,3);
        read_reg(4,8,1,6); read_reg(8,0,1,3); read_reg(12,0,1,3);
        write_reg(0,0,1,0,0,1,0);
        write_reg(32,0,1,0,0,1,2); write_reg(0,2,1,0,0,1,2);
        pulse_events(0,1,0,2);
        read_reg(12,0,1,5);
        @(negedge clk); datapath_idle = 1;
        write_reg(0,3,1,0,0,1,2);
        write_reg(0,2,1,0,6,1,0);
        read_reg(0,0,1,0); read_reg(4,0,1,1); read_reg(8,0,1,0); read_reg(12,0,1,0);
        // Coefficient writes clear HISTORY only; sticky/counters survive.
        pulse_events(0,1,1);
        write_reg(32,32'hffffffff,15,0,0,1,0);
        read_reg(4,0,1,5); read_reg(12,0,1,1);
        read_reg(32,0,1,32'hffffffff);
        // Soft clear must preserve a pre-existing read response and the write
        // response itself. Snapshot STATUS before clearing, then hold it stalled.
        fork
            read_reg(4,20,1,5);
            write_reg(0,2,1,0,6,1,0);
        join
        read_reg(4,0,1,1); read_reg(12,0,1,0); read_reg(32,0,1,32'hffffffff);

        // Seed only the counter boundary via a test-only backdoor: executing
        // 2^32 real transfers is unnecessary to verify natural modulo wrap.
        @(negedge clk);
        dut.input_count = 32'hfffffffe; dut.output_count = 32'hfffffffe;
        model_inputs = 32'hfffffffe; model_outputs = 32'hfffffffe;
        pulse_events(1,1,0,3);
        read_reg(8,0,1,1); read_reg(12,0,1,1);
        reset_bus();

        // AR on the CONTROL commit edge sees the old disabled state. A later
        // read sees enabled. Both response channels can be outstanding together.
        @(negedge clk);
        s_axi_awvalid = 1; s_axi_awaddr = 0;
        s_axi_wvalid = 1; s_axi_wdata = 1; s_axi_wstrb = 1;
        @(posedge clk);
        @(negedge clk);
        s_axi_awvalid = 0; s_axi_wvalid = 0; s_axi_arvalid = 1; s_axi_araddr = 0;
        @(posedge clk);
        @(negedge clk);
        s_axi_arvalid = 0;
        if (!s_axi_bvalid || !s_axi_rvalid || s_axi_rdata != 0) $fatal(1, "Same-edge read/write snapshot failed");
        s_axi_bready = 1; s_axi_rready = 1;
        @(posedge clk);
        @(negedge clk); s_axi_bready = 0; s_axi_rready = 0;
        read_reg(0,0,1,1);
        // Disable on a commit edge that also accepts one last input event.
        // AR still snapshots the old enabled value; the event remains counted.
        @(negedge clk);
        s_axi_awvalid = 1; s_axi_awaddr = 0;
        s_axi_wvalid = 1; s_axi_wdata = 0; s_axi_wstrb = 1;
        @(posedge clk);
        @(negedge clk);
        s_axi_awvalid = 0; s_axi_wvalid = 0;
        s_axi_arvalid = 1; s_axi_araddr = 0; input_transfer = 1;
        @(posedge clk);
        @(negedge clk);
        s_axi_arvalid = 0; input_transfer = 0;
        if (enable || !s_axi_rvalid || s_axi_rdata != 1) $fatal(1, "Disable commit snapshot failed");
        s_axi_bready = 1; s_axi_rready = 1;
        @(posedge clk);
        @(negedge clk); s_axi_bready = 0; s_axi_rready = 0;
        read_reg(8,0,1,1);
        // An event on the AR edge appears in the NEXT read, not this snapshot.
        @(negedge clk); s_axi_arvalid = 1; s_axi_araddr = 8; input_transfer = 1;
        @(posedge clk);
        @(negedge clk); s_axi_arvalid = 0; input_transfer = 0; s_axi_rready = 1;
        if (s_axi_rdata != 1) $fatal(1, "Counter read did not snapshot pre-event value");
        @(posedge clk);
        @(negedge clk); s_axi_rready = 0;
        read_reg(8,0,1,2);
        reset_bus();

        // Present a second complete write while B is stalled. Neither half may
        // be accepted early, and the first write must not be committed twice.
        @(negedge clk);
        s_axi_awvalid = 1; s_axi_awaddr = 0;
        s_axi_wvalid = 1; s_axi_wdata = 0; s_axi_wstrb = 1;
        @(posedge clk);
        @(negedge clk); s_axi_awvalid = 0; s_axi_wvalid = 0;
        wait (s_axi_bvalid);
        @(negedge clk);
        s_axi_awvalid = 1; s_axi_awaddr = 32;
        s_axi_wvalid = 1; s_axi_wdata = 32'h42; s_axi_wstrb = 15;
        repeat (6) @(negedge clk);
        s_axi_bready = 1;
        @(posedge clk);
        @(negedge clk); s_axi_bready = 0;
        @(posedge clk);
        @(negedge clk); s_axi_awvalid = 0; s_axi_wvalid = 0;
        wait (s_axi_bvalid);
        @(negedge clk); s_axi_bready = 1;
        @(posedge clk);
        @(negedge clk); s_axi_bready = 0;
        read_reg(32,0,1,32'h42);

        // Hold a second AR behind a captured R response, then let it proceed.
        @(negedge clk); s_axi_arvalid = 1; s_axi_araddr = 0;
        @(posedge clk);
        @(negedge clk); s_axi_araddr = 4;
        repeat (6) @(negedge clk);
        s_axi_rready = 1;
        @(posedge clk);
        @(negedge clk); s_axi_rready = 0;
        @(posedge clk);
        @(negedge clk); s_axi_arvalid = 0; s_axi_rready = 1;
        @(posedge clk);
        @(negedge clk); s_axi_rready = 0;

        // Reset separately with AW-only, W-only, stalled B and stalled R slots.
        @(negedge clk); s_axi_awvalid = 1; s_axi_awaddr = 32;
        @(posedge clk);
        reset_bus();
        @(negedge clk); s_axi_wvalid = 1; s_axi_wdata = 32'hbad; s_axi_wstrb = 15;
        @(posedge clk);
        reset_bus();
        @(negedge clk); s_axi_awvalid = 1; s_axi_awaddr = 32; s_axi_wvalid = 1;
        @(posedge clk);
        @(negedge clk); s_axi_awvalid = 0; s_axi_wvalid = 0;
        wait (s_axi_bvalid);
        reset_bus();
        @(negedge clk); s_axi_arvalid = 1; s_axi_araddr = 4;
        @(posedge clk);
        reset_bus();
        read_reg(32,0,1,0); read_reg(0,0,1,0);

        // Random reads run concurrently with independent AW/W arrival orders,
        // WSTRB patterns and response stalls; event inputs also vary separately.
        random_events = 1;
        count_start = commits;
        repeat (target_transactions) begin
            rng_state = next_random(rng_state); word1 = rng_state;
            rng_state = next_random(rng_state); word2 = rng_state;
            case (word1[2:0])
                0,1: address1 = 0;
                2: address1 = 4;
                3: address1 = 8;
                4,5,6: address1 = 8'(32+4*(word1[15:8]%TAPS));
                default: address1 = word1[15:8];
            endcase
            case (word2[1:0])
                0: address2 = 8'(4*(word2[7:2]%4));
                1,2: address2 = 8'(32+4*(word2[15:8]%TAPS));
                default: address2 = word2[15:8];
            endcase
            fork
                write_reg(address1,word2,word1[19:16],int'(word1[23:20])%3,int'(word1[27:24]));
                read_reg(address2,int'(word2[23:20]));
            join
        end
        random_events = 0;
        @(negedge clk); input_transfer = 0; output_transfer = 0; saturation_event = 0;
        read_reg(0); read_reg(4); read_reg(8); read_reg(12);
        for (int t = 0; t < TAPS; t++) read_reg(8'(32+4*t));
        if (aw_held || w_held || b_pending || r_pending || commits-count_start != target_transactions)
            $fatal(1, "Unfinished AXI transaction or random count mismatch");
        if (aw_captures != commits+reset_aw || w_captures != commits+reset_w ||
            commits != write_responses+reset_b || ar_captures != read_responses+reset_r)
            $fatal(1, "AXI channel transaction conservation failed");
        if (aw_first == 0 || w_first == 0 || simultaneous == 0 || errors == 0 ||
            b_stalls == 0 || r_stalls == 0 || overlapping_reads_writes == 0 ||
            clear_pulses == 0 || soft_clears == 0 || coefficient_writes == 0 ||
            blocked_aw == 0 || blocked_w == 0 || blocked_ar == 0 || resets < 10 ||
            reset_aw == 0 || reset_w == 0 || reset_b == 0 || reset_r == 0)
            $fatal(1, "Required AXI scenario coverage missing");
        $display("PASS: axi_lite_regs taps=%0d coeff_width=%0d seed=%0d random_transactions=%0d commits=%0d write_responses=%0d read_responses=%0d aw_first=%0d w_first=%0d simultaneous=%0d errors=%0d b_stalls=%0d r_stalls=%0d overlapping_reads_writes=%0d history_clears=%0d soft_clears=%0d coefficient_writes=%0d blocked_aw=%0d blocked_w=%0d blocked_ar=%0d reset_edges=%0d",
                 TAPS,COEFF_WIDTH,seed,commits-count_start,commits,write_responses,read_responses,
                 aw_first,w_first,simultaneous,errors,b_stalls,r_stalls,overlapping_reads_writes,
                 clear_pulses,soft_clears,coefficient_writes,blocked_aw,blocked_w,blocked_ar,resets);
        $display("ACCOUNTING: aw_captures=%0d w_captures=%0d ar_captures=%0d reset_aw=%0d reset_w=%0d reset_b=%0d reset_r=%0d",
                 aw_captures,w_captures,ar_captures,reset_aw,reset_w,reset_b,reset_r);
        $finish;
    end
    initial begin
        #100000000;
        $fatal(1, "AXI register testbench watchdog timeout");
    end
endmodule
