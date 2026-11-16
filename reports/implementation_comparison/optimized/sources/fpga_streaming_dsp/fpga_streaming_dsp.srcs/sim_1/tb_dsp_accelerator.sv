`timescale 1ns/1ps

// Complete AXI-controlled FIR verification. Only public AXI interfaces drive the
// hardware. An independent register-map model and accepted-sample FIR oracle
// check control and arithmetic together; Python independently replays the trace.
// Internal probes observe FIFO/pipeline occupancy and per-result clipping, which
// is deliberately not exposed as an optional AXI4-Stream sideband.
module tb_dsp_accelerator #(
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
    logic [DATA_WIDTH-1:0] s_axis_tdata = 0;
    logic s_axis_tvalid = 0, m_axis_tready = 0;
    wire s_axis_tready, m_axis_tvalid;
    wire [OUTPUT_WIDTH-1:0] m_axis_tdata;
    bit model_idle = 1, saturation_event = 0;
    wire input_transfer = resetn && s_axis_tvalid && s_axis_tready;
    wire output_transfer = resetn && m_axis_tvalid && m_axis_tready;
    wire enable = dut.enable;
    wire history_clear = dut.history_clear;
    wire soft_clear = dut.soft_clear;
    wire [TAPS*COEFF_WIDTH-1:0] coefficients = dut.coefficients;
    dsp_accelerator #(
        .DATA_WIDTH(DATA_WIDTH), .COEFF_WIDTH(COEFF_WIDTH), .OUTPUT_WIDTH(OUTPUT_WIDTH),
        .TAPS(TAPS), .INPUT_FRAC_BITS(INPUT_FRAC_BITS), .COEFF_FRAC_BITS(COEFF_FRAC_BITS),
        .OUTPUT_FRAC_BITS(OUTPUT_FRAC_BITS), .INPUT_FIFO_DEPTH(INPUT_FIFO_DEPTH),
        .OUTPUT_FIFO_DEPTH(OUTPUT_FIFO_DEPTH)
    ) dut (.*);
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
    int seed = 1, target_samples = 10000, events_file = 0;
    logic [31:0] rng_state = 1, traffic_rng = 1, control_rng = 7;
    string events_path = "accelerator_events.txt";
    localparam integer SHIFT = INPUT_FRAC_BITS+COEFF_FRAC_BITS-OUTPUT_FRAC_BITS;
    localparam integer CAPACITY = INPUT_FIFO_DEPTH+OUTPUT_FIFO_DEPTH+2;
    localparam longint signed INPUT_MIN = -(64'sd1 << (DATA_WIDTH-1));
    localparam longint signed INPUT_MAX = (64'sd1 << (DATA_WIDTH-1))-1;
    localparam longint signed COEFF_MIN = -(64'sd1 << (COEFF_WIDTH-1));
    localparam longint signed COEFF_MAX = (64'sd1 << (COEFF_WIDTH-1))-1;
    localparam longint signed OUTPUT_MIN = -(64'sd1 << (OUTPUT_WIDTH-1));
    localparam longint signed OUTPUT_MAX = (64'sd1 << (OUTPUT_WIDTH-1))-1;
    localparam longint signed TEST_INPUT = 64'sd1 << ((DATA_WIDTH > 3) ? DATA_WIDTH-3 : 0);
    localparam longint signed GAIN = (COEFF_FRAC_BITS > 0) ? (64'sd1 << (COEFF_FRAC_BITS-1)) : 1;
    logic [OUTPUT_WIDTH:0] expected[$], to_produce[$];
    int accepted_at[$];
    longint signed model_history [0:TAPS-1];
    int writes = 0, reads = 0, discarded = 0, resets_with_data = 0;
    int input_stalls = 0, output_stalls = 0, disabled_reads = 0;
    int positive_clips = 0, negative_clips = 0, saturation_events = 0;
    int read_streak = 0, max_read_streak = 0, max_pending = 0;
    int input_full = 0, output_full = 0, disable_edge_inputs = 0;
    bit source_blocked = 0, check_latency = 0;
    logic [DATA_WIDTH-1:0] held_input;
    bit traffic_done = 0, controls_done = 0;

    function automatic logic [31:0] next_random(input logic [31:0] value);
        logic [31:0] result;
        result = value ^ (value << 13);
        result = result ^ (result >> 17);
        return result ^ (result << 5);
    endfunction

    // Accepted samples advance history once; clock gaps and FIFO execution time
    // do not. Coefficients come from the independent AXI register model.
    function automatic logic [OUTPUT_WIDTH:0] clipped(input longint signed value);
        if (value > OUTPUT_MAX) return {1'b1, OUTPUT_WIDTH'(OUTPUT_MAX)};
        if (value < OUTPUT_MIN) return {1'b1, OUTPUT_WIDTH'(OUTPUT_MIN)};
        return {1'b0,value[OUTPUT_WIDTH-1:0]};
    endfunction
    function automatic logic [OUTPUT_WIDTH:0] reference_result(input logic signed [DATA_WIDTH-1:0] sample);
        longint signed accumulator, coefficient, shifted;
        for (int t = TAPS-1; t > 0; t--) model_history[t] = model_history[t-1];
        model_history[0] = sample;
        accumulator = 0;
        for (int t = 0; t < TAPS; t++) begin
            coefficient = $signed(model_coeff[t]);
            accumulator += model_history[t]*coefficient;
        end
        shifted = accumulator >>> SHIFT;
        if (shifted > OUTPUT_MAX) positive_clips++;
        if (shifted < OUTPUT_MIN) negative_clips++;
        return clipped(shifted);
    endfunction

    // A read snapshots the old state, including status and counter event races.
    // Pack response above data so invalid reads can be checked as {SLVERR, 0}.
    function automatic logic [33:0] read_model(input logic [7:0] address);
        int index;
        logic [31:0] value;
        if (address % 4 != 0) return {2'b10, 32'd0};
        case (address)
            0: return {2'b00, 31'd0, model_enable};
            4: return {2'b00, 29'd0, model_saturated, !model_idle, model_idle};
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

    // Stream tasks never write enable or coefficients: all configuration uses
    // the public AXI4-Lite bus. Return after nonblocking updates have settled.
    task automatic stream_cycle(input bit valid_in, input logic [DATA_WIDTH-1:0] value,
                                input bit ready_out);
        @(negedge clk);
        s_axis_tvalid = valid_in; s_axis_tdata = value; m_axis_tready = ready_out;
        @(posedge clk);
        #1;
    endtask

    task automatic reset_system;
        @(negedge clk);
        resetn = 0;
        s_axis_tvalid = 0; m_axis_tready = 0;
        s_axi_awvalid = 0; s_axi_wvalid = 0; s_axi_arvalid = 0;
        s_axi_bready = 0; s_axi_rready = 0;
        repeat (2) begin @(posedge clk); #1; end
        @(negedge clk); resetn = 1;
        @(posedge clk); #1;
    endtask

    task automatic send_sample(input logic [DATA_WIDTH-1:0] value);
        int attempts;
        attempts = 0;
        do begin
            if (attempts++ > CAPACITY+32) $fatal(1,"Sample acceptance timeout");
            stream_cycle(1,value,1);
        end while (source_blocked);
        // Remove valid after acceptance, before unrelated bus tasks consume time.
        @(negedge clk); s_axis_tvalid = 0;
    endtask

    task automatic drain_stream;
        int attempts;
        attempts = 0;
        if (source_blocked && !model_enable) $fatal(1,"Re-enable the held source before calling drain_stream");
        while (source_blocked) begin
            if (attempts++ > CAPACITY+32) $fatal(1,"Source drain timeout");
            stream_cycle(1,s_axis_tdata,1);
        end
        stream_cycle(0,0,1);
        while (expected.size() != 0) begin
            if (attempts++ > 2*CAPACITY+64) $fatal(1,"Global drain timeout");
            stream_cycle(0,0,1);
        end
        repeat (4) stream_cycle(0,0,1);
        if (!dut.idle) $fatal(1,"Drained accelerator is not idle");
    endtask

    task automatic configure_filter(input logic [TAPS*COEFF_WIDTH-1:0] values);
        drain_stream();
        write_reg(0,0,1,0,0,1,0);
        for (int t = 0; t < TAPS; t++)
            write_reg(8'(32+4*t),32'($signed(values[t*COEFF_WIDTH +: COEFF_WIDTH])),15,t%3,1,1,0);
        write_reg(0,1,1,0,0,1,0);
    endtask

    task automatic check_single(input logic [DATA_WIDTH-1:0] sample,
                                input logic [OUTPUT_WIDTH:0] literal_expected);
        int attempts;
        attempts = 0;
        stream_cycle(1,sample,0);
        if (source_blocked) $fatal(1,"Single-sample fixture was not empty/enabled");
        while (!m_axis_tvalid) begin
            if (attempts++ > 12) $fatal(1,"Single output timeout");
            stream_cycle(0,0,0);
        end
        if ({dut.output_saturated,m_axis_tdata} !== literal_expected) $fatal(1,"Directed numerical mismatch");
        repeat (3) stream_cycle(0,0,0);
        drain_stream();
    endtask

    task automatic fill_blocked;
        int attempts;
        attempts = 0;
        do begin
            if (attempts++ > CAPACITY+16) $fatal(1,"Backpressure did not reach input");
            stream_cycle(1,DATA_WIDTH'((attempts%2) ? INPUT_MIN : INPUT_MAX),0);
        end while (!source_blocked);
        if (expected.size() != CAPACITY || dut.input_occupancy != INPUT_FIFO_DEPTH ||
            dut.output_occupancy != OUTPUT_FIFO_DEPTH || !m_axis_tvalid)
            $fatal(1,"Full accelerator fixture failed");
        repeat (8) stream_cycle(1,s_axis_tdata,0);
    endtask

    // One candidate word is already held while disabled. Allow exactly its
    // first handshake after the AXI enable commit, then remove valid even if
    // the write response stays stalled. Keeping valid high would offer repeats.
    task automatic resume_held_source;
        fork
            write_reg(0,1,1,2,5,1,0);
            begin
                do @(posedge clk); while (!s_axis_tready);
                @(negedge clk); s_axis_tvalid = 0;
            end
        join
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

    assert property (@(posedge clk) disable iff (!resetn)
        s_axis_tvalid && !s_axis_tready |=> s_axis_tvalid && $stable(s_axis_tdata))
        else $fatal(1,"Stream master changed a blocked input");
    assert property (@(posedge clk) disable iff (!resetn)
        m_axis_tvalid && !m_axis_tready |=> m_axis_tvalid && $stable({m_axis_tdata,dut.output_saturated}))
        else $fatal(1,"Stream output/flag changed under backpressure");

    always @(posedge clk) begin : monitor
        bit aw_take, w_take, ar_take, commit_now, ok, effective, coeff_addr, clear_request;
        int index, input_cycle;
        logic [OUTPUT_WIDTH:0] wanted, generated;
        logic [33:0] snapshot;
        logic [31:0] mask, merged;
        clock_index++;
        model_idle = expected.size() == 0;
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
            if (expected.size() != 0) resets_with_data++;
            discarded += expected.size();
            expected.delete(); to_produce.delete(); accepted_at.delete();
            for (int t = 0; t < TAPS; t++) model_history[t] = 0;
            source_blocked = 0; read_streak = 0;
            $fdisplay(events_file,"R");
            // Existing replay R preserves external-core coefficients. Export
            // their actual hardware-reset zeros explicitly for this full top.
            for (int t = 0; t < TAPS; t++) $fdisplay(events_file,"C %0d 0",t);
        end else begin
            // Stream state is checked independently of register-bank counters.
            if (dut.idle !== model_idle) $fatal(1,"Pre-edge global idle mismatch");
            if ($isunknown({s_axis_tready,m_axis_tvalid,dut.idle})) $fatal(1,"Unknown stream controls");
            if (!model_enable && s_axis_tready) $fatal(1,"Disabled source was ready");
            if (source_blocked && (!s_axis_tvalid || s_axis_tdata !== held_input)) $fatal(1,"Blocked source retry changed");
            source_blocked = s_axis_tvalid && !s_axis_tready;
            held_input = s_axis_tdata;
            if (source_blocked) input_stalls++;
            if (m_axis_tvalid && !m_axis_tready) output_stalls++;
            if (dut.input_occupancy == INPUT_FIFO_DEPTH) input_full++;
            if (dut.output_occupancy == OUTPUT_FIFO_DEPTH) output_full++;
            if (output_transfer) begin
                if (expected.size() == 0) $fatal(1,"Unexpected/duplicate stream output");
                wanted = expected.pop_front(); input_cycle = accepted_at.pop_front();
                if ({dut.output_saturated,m_axis_tdata} !== wanted) $fatal(1,"Stream data/flag mismatch output=%0d",reads);
                if (check_latency && clock_index-input_cycle != 4) $fatal(1,"Expected four-cycle external latency");
                $fdisplay(events_file,"O %0d %0d",$signed(m_axis_tdata),dut.output_saturated);
                reads++;
                if (!model_enable) disabled_reads++;
                read_streak++;
                if (read_streak > max_read_streak) max_read_streak = read_streak;
            end else read_streak = 0;
            // Derive expected sticky-set events from the arithmetic oracle at
            // the production boundary, not from the top's event connection.
            saturation_event = 0;
            if (dut.datapath.core_valid && dut.datapath.output_ready) begin
                if (to_produce.size() == 0) $fatal(1,"Unexpected FIR production");
                generated = to_produce.pop_front();
                if ({dut.datapath.core_saturated,dut.datapath.core_data} !== generated)
                    $fatal(1,"Internal FIR production mismatch");
                saturation_event = generated[OUTPUT_WIDTH];
                if (saturation_event) saturation_events++;
            end
            if (dut.saturation_event !== saturation_event) $fatal(1,"Sticky saturation event wiring mismatch");

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
                if (saved_address == 0) ok = !clear_request || (!model_enable && model_idle && !saved_data[0]);
                else if (coeff_addr) ok = !effective || (!model_enable && model_idle);
            end
            if (history_clear !== (commit_now && ok && (clear_request || (coeff_addr && effective))) ||
                soft_clear !== (commit_now && ok && clear_request))
                $fatal(1, "Commit-edge clear qualification mismatch");
            if (dut.clear_accepted !== (commit_now && ok && (clear_request || (coeff_addr && effective))))
                $fatal(1,"History-clear delivery mismatch");
            if (commit_now && ok && (clear_request || (coeff_addr && effective))) begin
                for (int t = 0; t < TAPS; t++) model_history[t] = 0;
                $fdisplay(events_file,"H");
            end
            if (commit_now && ok && saved_address == 0 && saved_strobes[0] &&
                model_enable && !saved_data[0] && input_transfer) disable_edge_inputs++;

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
                        $fdisplay(events_file,"C %0d %0d",index,$signed(model_coeff[index]));
                    end
                end
            end
            if (aw_take) begin aw_captures++; aw_held = 1; saved_address = s_axi_awaddr; aw_at = clock_index; end
            if (w_take) begin w_captures++; w_held = 1; saved_data = s_axi_wdata; saved_strobes = s_axi_wstrb; w_at = clock_index; end
            if (input_transfer) begin
                if ($isunknown(s_axis_tdata)) $fatal(1,"Unknown accepted stream input data=%h time=%0t",s_axis_tdata,$time);
                wanted = reference_result($signed(s_axis_tdata));
                expected.push_back(wanted); to_produce.push_back(wanted); accepted_at.push_back(clock_index);
                writes++;
                $fdisplay(events_file,"I %0d",$signed(s_axis_tdata));
            end
            if (expected.size() > max_pending) max_pending = expected.size();
            if (expected.size() > CAPACITY) $fatal(1,"Total buffering capacity exceeded");
        end
        #1;
        if (dut.idle !== (expected.size() == 0)) $fatal(1,"Post-edge global idle mismatch");
        if (expected.size() != dut.input_occupancy+dut.output_occupancy+
            int'(dut.datapath.core.mul_valid)+int'(dut.datapath.core.out_valid))
            $fatal(1,"FIFO/pipeline occupancy differs from accepted-sample accounting");
        if (!resetn && (s_axis_tready || m_axis_tvalid || !dut.idle)) $fatal(1,"Stream reset failed");
        if (enable !== model_enable) $fatal(1, "ENABLE side effect mismatch");
        for (int t = 0; t < TAPS; t++)
            if (coefficients[t*COEFF_WIDTH +: COEFF_WIDTH] !== model_coeff[t])
                $fatal(1, "Coefficient side effect mismatch tap=%0d", t);
        if (!resetn && (s_axi_awready || s_axi_wready || s_axi_arready ||
                       s_axi_bvalid || s_axi_rvalid || history_clear || soft_clear))
            $fatal(1, "Reset did not mask AXI transfers");
    end

    initial begin : stimulus
        logic [TAPS*COEFF_WIDTH-1:0] values;
        longint signed amplitude, impulse, min_product, other_min_product;
        bit positive_possible, negative_possible;
        int random_start, random_cycles;
        if ($value$plusargs("SEED=%d",seed)) begin end
        if ($value$plusargs("SAMPLES=%d",target_samples)) begin end
        if ($value$plusargs("EVENTS=%s",events_path)) begin end
        if (seed <= 0 || target_samples < 1 || target_samples > 100000)
            $fatal(1,"Require positive seed and 1..100000 random samples");
        if (DATA_WIDTH+COEFF_WIDTH+$clog2(TAPS) > 62)
            $fatal(1,"Integer oracle supports at most 62 accumulator bits");
        events_file = $fopen(events_path,"w");
        if (events_file == 0) $fatal(1,"Cannot open accelerator events");
        $fdisplay(events_file,"P %0d %0d %0d %0d %0d %0d %0d",TAPS,DATA_WIDTH,COEFF_WIDTH,
                  OUTPUT_WIDTH,INPUT_FRAC_BITS,COEFF_FRAC_BITS,OUTPUT_FRAC_BITS);
        rng_state = seed; traffic_rng = seed; control_rng = seed ^ 32'h19c457;
        reset_system();
        read_reg(0,0,1,0); read_reg(4,0,1,1); read_reg(8,0,1,0); read_reg(12,0,1,0);
        for (int t = 0; t < TAPS; t++) read_reg(8'(32+4*t),0,1,0);

        // Known arithmetic is exercised AFTER real AXI coefficient programming.
        values = 0; values[0 +: COEFF_WIDTH] = COEFF_WIDTH'(GAIN);
        configure_filter(values);
        check_single(DATA_WIDTH'(TEST_INPUT),clipped((TEST_INPUT*GAIN) >>> SHIFT));
        check_single(DATA_WIDTH'(-3),clipped((-64'sd3*GAIN) >>> SHIFT));
        check_single(DATA_WIDTH'(INPUT_MIN),clipped((INPUT_MIN*GAIN) >>> SHIFT));
        configure_filter(0);
        check_single(DATA_WIDTH'(INPUT_MAX),clipped(0));
        for (int t = 0; t < TAPS; t++) begin
            amplitude = (COEFF_FRAC_BITS > t+1) ? (64'sd1 << (COEFF_FRAC_BITS-t-1)) : 1;
            if (t%2) amplitude = -amplitude;
            values[t*COEFF_WIDTH +: COEFF_WIDTH] = COEFF_WIDTH'(amplitude);
        end
        configure_filter(values);
        impulse = TEST_INPUT;
        for (int t = 0; t < TAPS; t++)
            check_single(DATA_WIDTH'((t == 0) ? impulse : 0),
                clipped((impulse*$signed(values[t*COEFF_WIDTH +: COEFF_WIDTH])) >>> SHIFT));
        check_single(0,clipped(0));

        // Byte masking, sign extension, holes and RO errors reach the real bank.
        write_reg(0,0,1,0,0,1,0);
        for (int strobe = 0; strobe < 16; strobe++) begin
            write_reg(32,(strobe%2) ? 32'h89abcdef : 32'h12345678,4'(strobe),strobe%3,2,1,0);
            read_reg(32,2);
        end
        write_reg(1,0,0,0,0,1,2); write_reg(4,0,0,1,0,1,2);
        write_reg(8,0,15,2,0,1,2); write_reg(16,0,15,0,0,1,2);
        read_reg(1,0,1,0,2); read_reg(16,0,1,0,2);

        // Both signs of clipping, where the selected numeric formats permit it.
        configure_filter({TAPS{COEFF_WIDTH'(COEFF_MAX)}});
        repeat (32) send_sample(DATA_WIDTH'(INPUT_MAX));
        drain_stream();
        configure_filter({TAPS{COEFF_WIDTH'(COEFF_MAX)}});
        repeat (32) send_sample(DATA_WIDTH'(INPUT_MIN));
        drain_stream();
        values = 0; values[0 +: COEFF_WIDTH] = COEFF_WIDTH'(COEFF_MIN);
        configure_filter(values);
        check_single(DATA_WIDTH'(-INPUT_MAX),clipped((-INPUT_MAX*COEFF_MIN) >>> SHIFT));
        check_single(DATA_WIDTH'(INPUT_MIN),clipped((INPUT_MIN*COEFF_MIN) >>> SHIFT));

        // AXI reads do not disturb continuous streaming or its four-clock latency.
        configure_filter(values);
        check_latency = 1;
        fork
            begin
                repeat (1050) stream_cycle(1,DATA_WIDTH'(TEST_INPUT),1);
                drain_stream();
            end
            begin
                repeat (20) begin read_reg(8,3); read_reg(12,2); read_reg(4,1); end
            end
        join
        check_latency = 0;
        $display("PASS directed: AXI-programmed arithmetic and continuous streaming");

        // A disable commit still counts the final input accepted under OLD enable.
        fork
            begin
                @(negedge clk);
                s_axis_tvalid = 1; s_axis_tdata = DATA_WIDTH'(TEST_INPUT); m_axis_tready = 1;
                wait (!model_enable);
                @(negedge clk); s_axis_tvalid = 0;
            end
            begin
                repeat (4) @(negedge clk);
                write_reg(0,0,1,0,3,1,0);
            end
        join
        drain_stream();
        read_reg(8); read_reg(12); read_reg(0,0,1,0);

        // Disable/re-enable preserves history. An effective SAME-VALUE coefficient
        // write while disabled/idle instead starts a zero-history epoch.
        values = 0;
        values[((TAPS > 1) ? 1 : 0)*COEFF_WIDTH +: COEFF_WIDTH] = COEFF_WIDTH'(GAIN);
        configure_filter(values);
        check_single(DATA_WIDTH'(TEST_INPUT),(TAPS > 1) ? clipped(0) : clipped((TEST_INPUT*GAIN) >>> SHIFT));
        write_reg(0,0,1,0,0,1,0); write_reg(0,1,1,0,0,1,0);
        check_single(0,(TAPS > 1) ? clipped((TEST_INPUT*GAIN) >>> SHIFT) : clipped(0));
        check_single(DATA_WIDTH'(TEST_INPUT),(TAPS > 1) ? clipped(0) : clipped((TEST_INPUT*GAIN) >>> SHIFT));
        write_reg(0,0,1,0,0,1,0);
        write_reg(8'(32+4*((TAPS > 1) ? 1 : 0)),32'(GAIN),15,1,3,1,0);
        write_reg(0,1,1,0,0,1,0);
        check_single(0,clipped(0));

        // Fully blocked output fills every storage stage. Illegal active/busy
        // writes cannot change coefficients/history, enable, counters or sticky
        // state, apart from normal events still progressing independently.
        configure_filter({TAPS{COEFF_WIDTH'(COEFF_MIN)}});
        fill_blocked();
        read_reg(4,8); read_reg(8,3); read_reg(12,3);
        write_reg(32,0,1,1,6,1,2);
        write_reg(0,2,1,2,4,1,2); write_reg(0,3,1,0,4,1,2);
        write_reg(0,0,1,0,3,1,0);
        write_reg(32,0,1,0,3,1,2); write_reg(0,2,1,0,3,1,2);
        write_reg(32,0,0,0,3,1,0);
        if (COEFF_WIDTH < 25) write_reg(32,0,8,0,3,1,0);
        // Preserve the unaccepted candidate at the source while old work drains.
        while (expected.size() != 0) stream_cycle(1,s_axis_tdata,1);
        read_reg(4,5); read_reg(8); read_reg(12);
        resume_held_source();
        drain_stream();

        // A legal soft clear preserves coefficients and an outstanding R snapshot.
        // An offered source word remains blocked until a later enable commit.
        configure_filter(values);
        check_single(DATA_WIDTH'(TEST_INPUT),(TAPS > 1) ? clipped(0) : clipped((TEST_INPUT*GAIN) >>> SHIFT));
        write_reg(0,0,1,0,0,1,0);
        stream_cycle(1,DATA_WIDTH'(TEST_INPUT),1);
        write_reg(0,3,1,0,3,1,2);
        fork
            read_reg(8,20);
            write_reg(0,2,1,0,6,1,0);
        join
        read_reg(8,0,1,0); read_reg(12,0,1,0); read_reg(4,0,1,1);
        resume_held_source();
        drain_stream();
        check_single(0,(TAPS > 1) ? clipped((TEST_INPUT*GAIN) >>> SHIFT) : clipped(0));

        // Seed the 32-bit boundary only; actual stream handshakes then exercise
        // both counters across wrap, checking the top's event connections too.
        @(negedge clk);
        dut.registers.input_count = 32'hfffffffe; dut.registers.output_count = 32'hfffffffe;
        model_inputs = 32'hfffffffe; model_outputs = 32'hfffffffe;
        repeat (3) send_sample(DATA_WIDTH'(TEST_INPUT));
        drain_stream();
        read_reg(8,0,1,1); read_reg(12,0,1,1);

        // Full data buffers plus AW-only, W-only, and simultaneous stalled B/R
        // are reset separately. No pre-reset data, coefficient or request survives.
        fill_blocked();
        @(negedge clk); s_axi_awvalid = 1; s_axi_awaddr = 32;
        @(posedge clk);
        @(negedge clk); s_axi_awvalid = 0;
        reset_system();
        read_reg(0,0,1,0); read_reg(32,0,1,0); read_reg(4,0,1,1);
        configure_filter(values); fill_blocked();
        @(negedge clk); s_axi_wvalid = 1; s_axi_wdata = 32'hbad; s_axi_wstrb = 15;
        @(posedge clk);
        @(negedge clk); s_axi_wvalid = 0;
        reset_system();
        configure_filter(values); fill_blocked();
        @(negedge clk);
        s_axi_awvalid = 1; s_axi_awaddr = 32;
        s_axi_wvalid = 1; s_axi_wdata = 0; s_axi_wstrb = 0;
        s_axi_arvalid = 1; s_axi_araddr = 4;
        @(posedge clk);
        @(negedge clk); s_axi_awvalid = 0; s_axi_wvalid = 0; s_axi_arvalid = 0;
        wait (s_axi_bvalid && s_axi_rvalid);
        repeat (5) stream_cycle(1,s_axis_tdata,0);
        reset_system();
        read_reg(0,0,1,0); read_reg(8,0,1,0); read_reg(12,0,1,0);
        for (int t = 0; t < TAPS; t++) read_reg(8'(32+4*t),0,1,0);

        // Independent RNGs keep concurrent stream and AXI traffic reproducible.
        // Control writes may disable temporarily; every disable branch re-enables
        // before returning, guaranteeing progress when the receiver becomes ready.
        for (int t = 0; t < TAPS; t++) begin
            rng_state = next_random(rng_state);
            values[t*COEFF_WIDTH +: COEFF_WIDTH] = COEFF_WIDTH'(rng_state);
        end
        configure_filter(values);
        random_start = writes;
        fork
            begin
                random_cycles = 0;
                while (writes-random_start < target_samples) begin
                    if (random_cycles++ > target_samples*100+5000) $fatal(1,"Random stream progress timeout");
                    traffic_rng = next_random(traffic_rng);
                    if (source_blocked)
                        stream_cycle(1,s_axis_tdata,(random_cycles%251 >= 48) && traffic_rng[2]);
                    else
                        stream_cycle(traffic_rng[1:0] != 0,DATA_WIDTH'(traffic_rng),
                                     (random_cycles%251 >= 48) && traffic_rng[2]);
                end
                traffic_done = 1;
                stream_cycle(0,0,1);
                while (!controls_done) stream_cycle(0,0,1);
                drain_stream();
            end
            begin
                while (!traffic_done) begin
                    control_rng = next_random(control_rng);
                    case (control_rng[3:0])
                        0: begin
                            write_reg(0,0,1,int'(control_rng[7:4])%3,3,1,0);
                            read_reg(4,4); read_reg(12,3);
                            write_reg(0,1,1,1,2,1,0);
                        end
                        1: begin
                            fork
                                write_reg(32,control_rng,1,2,5,1,2);
                                read_reg(8,7);
                            join
                        end
                        2: write_reg(0,2,1,1,4,1,2);
                        3: write_reg(32,control_rng,0,0,4,1,0);
                        4: write_reg(0,2,14,0,2,1,0);
                        5: read_reg(16,5,1,0,2);
                        default: read_reg(8'(4*(control_rng[5:4])),int'(control_rng[9:6]));
                    endcase
                end
                controls_done = 1;
            end
        join
        write_reg(0,0,1,0,0,1,0);
        read_reg(0,0,1,0); read_reg(4); read_reg(8); read_reg(12);
        for (int t = 0; t < TAPS; t++) read_reg(8'(32+4*t));

        min_product = INPUT_MIN*COEFF_MAX;
        other_min_product = INPUT_MAX*COEFF_MIN;
        if (other_min_product < min_product) min_product = other_min_product;
        positive_possible = ((TAPS*(INPUT_MIN*COEFF_MIN)) >>> SHIFT) > OUTPUT_MAX;
        negative_possible = ((TAPS*min_product) >>> SHIFT) < OUTPUT_MIN;
        if (writes != reads+discarded || expected.size() != 0 || to_produce.size() != 0 ||
            aw_held || w_held || b_pending || r_pending) $fatal(1,"Final stream/AXI drain accounting failed");
        if (aw_captures != commits+reset_aw || w_captures != commits+reset_w ||
            commits != write_responses+reset_b || ar_captures != read_responses+reset_r)
            $fatal(1,"AXI transaction conservation failed");
        if (max_read_streak < 1024 || max_pending != CAPACITY || input_full == 0 || output_full == 0 ||
            input_stalls == 0 || output_stalls == 0 || disabled_reads == 0 || disable_edge_inputs == 0 ||
            resets_with_data != 3 || aw_first == 0 || w_first == 0 || simultaneous == 0 || errors == 0 ||
            b_stalls == 0 || r_stalls == 0 || soft_clears == 0 || coefficient_writes == 0 ||
            reset_aw == 0 || reset_w == 0 || reset_b == 0 || reset_r == 0 ||
            (positive_possible && positive_clips == 0) || (negative_possible && negative_clips == 0) ||
            (positive_possible && saturation_events == 0)) $fatal(1,"Required full-system coverage missing");
        $display("PASS: dsp_accelerator taps=%0d input_width=%0d coeff_width=%0d output_width=%0d input_frac=%0d coeff_frac=%0d output_frac=%0d input_depth=%0d output_depth=%0d seed=%0d random_samples=%0d writes=%0d reads=%0d reset_discarded=%0d max_streak=%0d max_pending=%0d history_clears=%0d disabled_reads=%0d disable_edge_inputs=%0d saturation_events=%0d",
                 TAPS,DATA_WIDTH,COEFF_WIDTH,OUTPUT_WIDTH,INPUT_FRAC_BITS,COEFF_FRAC_BITS,OUTPUT_FRAC_BITS,
                 INPUT_FIFO_DEPTH,OUTPUT_FIFO_DEPTH,seed,writes-random_start,writes,reads,discarded,
                 max_read_streak,max_pending,clear_pulses,disabled_reads,disable_edge_inputs,saturation_events);
        $display("AXI: commits=%0d write_responses=%0d read_responses=%0d aw_first=%0d w_first=%0d simultaneous=%0d errors=%0d b_stalls=%0d r_stalls=%0d aw_captures=%0d w_captures=%0d ar_captures=%0d reset_aw=%0d reset_w=%0d reset_b=%0d reset_r=%0d soft_clears=%0d coefficient_writes=%0d",
                 commits,write_responses,read_responses,aw_first,w_first,simultaneous,errors,b_stalls,r_stalls,
                 aw_captures,w_captures,ar_captures,reset_aw,reset_w,reset_b,reset_r,soft_clears,coefficient_writes);
        $display("COVERAGE: positive_clips=%0d negative_clips=%0d input_full=%0d output_full=%0d input_stalls=%0d output_stalls=%0d resets_with_data=%0d",
                 positive_clips,negative_clips,input_full,output_full,input_stalls,output_stalls,resets_with_data);
        $fclose(events_file);
        $finish;
    end
    initial begin
        #200000000;
        $fatal(1,"Accelerator testbench watchdog timeout");
    end
endmodule
