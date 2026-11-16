// Complete single-clock accelerator: AXI4-Lite registers control a buffered FIR.
// AXI4-Stream uses only TDATA/TVALID/TREADY, with one signed sample per transfer.
// No packet boundaries, clock-domain crossings or processor subsystem are used.
module dsp_accelerator #(
    parameter integer DATA_WIDTH = 16,
    parameter integer COEFF_WIDTH = 16,
    parameter integer OUTPUT_WIDTH = DATA_WIDTH,
    parameter integer TAPS = 8,
    parameter integer INPUT_FRAC_BITS = DATA_WIDTH-1,
    parameter integer COEFF_FRAC_BITS = COEFF_WIDTH-1,
    parameter integer OUTPUT_FRAC_BITS = OUTPUT_WIDTH-1,
    parameter integer INPUT_FIFO_DEPTH = 16,
    parameter integer OUTPUT_FIFO_DEPTH = 16
) (
    input wire clk,
    input wire resetn,
    input wire [DATA_WIDTH-1:0] s_axis_tdata,
    input wire s_axis_tvalid,
    output wire s_axis_tready,
    output wire [OUTPUT_WIDTH-1:0] m_axis_tdata,
    output wire m_axis_tvalid,
    input wire m_axis_tready,

    input wire [7:0] s_axi_awaddr,
    input wire [2:0] s_axi_awprot,
    input wire s_axi_awvalid,
    output wire s_axi_awready,
    input wire [31:0] s_axi_wdata,
    input wire [3:0] s_axi_wstrb,
    input wire s_axi_wvalid,
    output wire s_axi_wready,
    output wire [1:0] s_axi_bresp,
    output wire s_axi_bvalid,
    input wire s_axi_bready,
    input wire [7:0] s_axi_araddr,
    input wire [2:0] s_axi_arprot,
    input wire s_axi_arvalid,
    output wire s_axi_arready,
    output wire [31:0] s_axi_rdata,
    output wire [1:0] s_axi_rresp,
    output wire s_axi_rvalid,
    input wire s_axi_rready
);
    wire enable, idle, history_clear, soft_clear, clear_accepted;
    wire input_transfer, output_transfer, saturation_event;
    wire [TAPS*COEFF_WIDTH-1:0] coefficients;
    wire [$clog2(INPUT_FIFO_DEPTH):0] input_occupancy;
    wire [$clog2(OUTPUT_FIFO_DEPTH):0] output_occupancy;
    // The flag is buffered alongside each result, but is not an extra public
    // AXI4-Stream sideband. Software observes sticky clipping through STATUS.
    wire output_saturated;

    // Count EXTERNAL handshakes, not FIR/FIFO internal transfers or valid levels.
    // On a disabling CONTROL commit edge, these wires still see the old enable;
    // any last accepted sample therefore belongs to the old running epoch.
    assign input_transfer = resetn && s_axis_tvalid && s_axis_tready;
    assign output_transfer = resetn && m_axis_tvalid && m_axis_tready;

    axi_lite_regs #(.TAPS(TAPS), .COEFF_WIDTH(COEFF_WIDTH)) registers (
        .clk(clk), .resetn(resetn),
        .s_axi_awaddr(s_axi_awaddr), .s_axi_awprot(s_axi_awprot),
        .s_axi_awvalid(s_axi_awvalid), .s_axi_awready(s_axi_awready),
        .s_axi_wdata(s_axi_wdata), .s_axi_wstrb(s_axi_wstrb),
        .s_axi_wvalid(s_axi_wvalid), .s_axi_wready(s_axi_wready),
        .s_axi_bresp(s_axi_bresp), .s_axi_bvalid(s_axi_bvalid), .s_axi_bready(s_axi_bready),
        .s_axi_araddr(s_axi_araddr), .s_axi_arprot(s_axi_arprot),
        .s_axi_arvalid(s_axi_arvalid), .s_axi_arready(s_axi_arready),
        .s_axi_rdata(s_axi_rdata), .s_axi_rresp(s_axi_rresp),
        .s_axi_rvalid(s_axi_rvalid), .s_axi_rready(s_axi_rready),
        .datapath_idle(idle), .input_transfer(input_transfer), .output_transfer(output_transfer),
        .saturation_event(saturation_event), .enable(enable), .coefficients(coefficients),
        .history_clear(history_clear), .soft_clear(soft_clear)
    );

    // Preserve the verified buffered block's synthesis boundary. No registers
    // are added here: external no-stall handshake latency remains four clocks.
    (* keep_hierarchy = "yes" *) dsp_datapath #(
        .DATA_WIDTH(DATA_WIDTH), .COEFF_WIDTH(COEFF_WIDTH), .OUTPUT_WIDTH(OUTPUT_WIDTH),
        .TAPS(TAPS), .INPUT_FRAC_BITS(INPUT_FRAC_BITS), .COEFF_FRAC_BITS(COEFF_FRAC_BITS),
        .OUTPUT_FRAC_BITS(OUTPUT_FRAC_BITS), .INPUT_FIFO_DEPTH(INPUT_FIFO_DEPTH),
        .OUTPUT_FIFO_DEPTH(OUTPUT_FIFO_DEPTH)
    ) datapath (
        .clk(clk), .resetn(resetn), .enable(enable), .history_clear(history_clear),
        .history_clear_accepted(clear_accepted), .coefficients(coefficients),
        .s_data(s_axis_tdata), .s_valid(s_axis_tvalid), .s_ready(s_axis_tready),
        .m_data(m_axis_tdata), .m_valid(m_axis_tvalid), .m_ready(m_axis_tready),
        .m_saturated(output_saturated), .idle(idle),
        .input_occupancy(input_occupancy), .output_occupancy(output_occupancy),
        // Set sticky status when a result ENTERS the output FIFO. Waiting for
        // external consumption would postpone status while the receiver stalls.
        .result_saturated(saturation_event)
    );
    // history_clear already includes a legal soft-clear command. soft_clear is
    // consumed inside the register bank for counters/status, not as a global
    // reset: an outstanding AXI response must survive a legal soft clear.
endmodule
