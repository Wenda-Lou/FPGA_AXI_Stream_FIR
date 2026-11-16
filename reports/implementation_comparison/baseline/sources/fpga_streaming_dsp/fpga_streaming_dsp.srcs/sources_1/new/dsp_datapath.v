// Buffered streaming FIR: input FIFO -> two-stage FIR -> output FIFO.
// This block exposes direct control inputs for a future AXI4-Lite register bank.
// All three instances use the same clock and active-low synchronous reset.
module dsp_datapath #(
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
    // Gate EXTERNAL acceptance only. Deasserting enable must never prevent
    // previously accepted samples from leaving either FIFO or the FIR pipeline.
    input wire enable,
    // Clear is accepted only when disabled and globally idle. Busy/enabled
    // pulses are ignored; a held disabled request takes effect after draining.
    input wire history_clear,
    output wire history_clear_accepted,
    // Replace coefficients only while disabled and idle, together with a clear.
    // Keep every coefficient stable until all buffered work has been consumed.
    input wire [TAPS*COEFF_WIDTH-1:0] coefficients,

    input wire signed [DATA_WIDTH-1:0] s_data,
    input wire s_valid,
    output wire s_ready,
    output wire signed [OUTPUT_WIDTH-1:0] m_data,
    output wire m_valid,
    input wire m_ready,
    // Per-output metadata for verification/future top-level use. Store it in
    // the output FIFO payload so it remains paired with data during all stalls.
    output wire m_saturated,

    output wire idle,
    output wire [$clog2(INPUT_FIFO_DEPTH):0] input_occupancy,
    output wire [$clog2(OUTPUT_FIFO_DEPTH):0] output_occupancy,
    // One event per clipped FIR result accepted by the output FIFO. Future
    // sticky SATURATED status should latch this event, not count stalled valid.
    output wire result_saturated
);
    wire input_ready;
    wire signed [DATA_WIDTH-1:0] input_data;
    wire input_valid;
    wire core_ready;
    wire signed [OUTPUT_WIDTH-1:0] core_data;
    wire core_valid, core_saturated, core_idle;
    wire output_ready;
    wire [OUTPUT_WIDTH:0] output_payload;

    // Ready and valid must be gated consistently: neither the upstream source
    // nor the FIFO may observe a transfer while external acceptance is disabled.
    assign s_ready = enable && input_ready;
    assign idle = (input_occupancy == 0) && core_idle && (output_occupancy == 0);
    assign history_clear_accepted = resetn && history_clear && !enable && idle;
    assign result_saturated = core_valid && output_ready && core_saturated;
    assign {m_saturated, m_data} = output_payload;

    axis_fifo #(.DATA_WIDTH(DATA_WIDTH), .DEPTH(INPUT_FIFO_DEPTH)) input_fifo (
        .clk(clk), .resetn(resetn),
        .s_data(s_data), .s_valid(s_valid && enable), .s_ready(input_ready),
        .m_data(input_data), .m_valid(input_valid), .m_ready(core_ready),
        .occupancy(input_occupancy)
    );

    // The input FIFO's read handshake is exactly the FIR's input handshake.
    // No enable gating belongs here: disabling must still permit internal drain.
    // Preserve the independently optimized arithmetic hierarchy when this block
    // is synthesized with its FIFOs. This affects mapping, not cycle behavior.
    (* keep_hierarchy = "yes" *) fir_core #(
        .DATA_WIDTH(DATA_WIDTH), .COEFF_WIDTH(COEFF_WIDTH),
        .OUTPUT_WIDTH(OUTPUT_WIDTH), .TAPS(TAPS),
        .INPUT_FRAC_BITS(INPUT_FRAC_BITS), .COEFF_FRAC_BITS(COEFF_FRAC_BITS),
        .OUTPUT_FRAC_BITS(OUTPUT_FRAC_BITS)
    ) core (
        .clk(clk), .resetn(resetn), .history_clear(history_clear_accepted),
        .coefficients(coefficients),
        .s_data(input_data), .s_valid(input_valid), .s_ready(core_ready),
        .m_data(core_data), .m_valid(core_valid), .m_ready(output_ready),
        .m_saturated(core_saturated), .idle(core_idle)
    );

    // Pack the flag above the signed output word. Arithmetic signedness belongs
    // to the FIR; a FIFO simply preserves this OUTPUT_WIDTH+1-bit bit pattern.
    // Non-bypassing FIFOs add one handshake cycle each. With no stalls, external
    // input-to-output latency is four clocks and steady throughput is one/clock.
    axis_fifo #(.DATA_WIDTH(OUTPUT_WIDTH+1), .DEPTH(OUTPUT_FIFO_DEPTH)) output_fifo (
        .clk(clk), .resetn(resetn),
        .s_data({core_saturated, core_data}), .s_valid(core_valid), .s_ready(output_ready),
        .m_data(output_payload), .m_valid(m_valid), .m_ready(m_ready),
        .occupancy(output_occupancy)
    );
endmodule
