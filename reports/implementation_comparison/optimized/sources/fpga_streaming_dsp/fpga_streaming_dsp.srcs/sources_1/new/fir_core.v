// Two-stage signed fixed-point FIR. Tap 0 multiplies the newest accepted input.
// Coefficients may change only while idle, with history_clear asserted.
// A clear request blocks new inputs; pending results continue to drain. History
// clears on an edge with history_clear && idle. Busy one-cycle pulses are ignored.
//
// Mathematical operation, indexed by ACCEPTED samples rather than clock cycles:
//   accumulator[n] = sum(coeff[k] * x[n-k]), for k = 0 .. TAPS-1.
// Samples before the beginning of a history epoch are treated as zero.
// An input gap pauses sample history; it does not insert a zero-valued sample.
//
// Pipeline timing when there is no output backpressure:
//   Edge N:   accept x[n], register all products and set mul_valid.
//   Edge N+1: register the scaled/clipped sum and assert the output valid flag.
//   Edge N+2: the receiver accepts that output if m_ready is high.
// Thus handshake-to-handshake latency is two clocks; throughput after startup
// is one input and one output per clock. Stalls extend latency without reordering.
//
// Default binary-point interpretation:
//   input and coefficient: signed 16-bit integers representing real_value * 2^15.
//   product/accumulator:   30 fractional bits.
//   output:               15 fractional bits after an arithmetic right shift.
module fir_core #(
    // Widths include the sign bit. OUTPUT_WIDTH can differ from DATA_WIDTH.
    parameter integer DATA_WIDTH = 16,
    parameter integer COEFF_WIDTH = 16,
    parameter integer OUTPUT_WIDTH = DATA_WIDTH,
    parameter integer TAPS = 8,
    // These parameters describe binary-point positions, not extra storage bits.
    parameter integer INPUT_FRAC_BITS = DATA_WIDTH - 1,
    parameter integer COEFF_FRAC_BITS = COEFF_WIDTH - 1,
    parameter integer OUTPUT_FRAC_BITS = OUTPUT_WIDTH - 1
) (
    input  wire clk,
    // State resets only at a rising clock edge; ready/valid are also masked
    // combinationally while resetn is low so no transfer is advertised in reset.
    input  wire resetn,
    // This is a level request. A caller can pulse it when idle or hold it while
    // old results drain. It never discards an already accepted sample.
    input  wire history_clear,
    // Packed external coefficient storage: tap k occupies
    // coefficients[k*COEFF_WIDTH +: COEFF_WIDTH]. Tap 0 is the low-order word.
    // The caller must keep this bus stable whenever the core is not idle.
    input  wire [TAPS*COEFF_WIDTH-1:0] coefficients,

    input  wire signed [DATA_WIDTH-1:0] s_data,
    input  wire s_valid,
    output wire s_ready,

    output wire signed [OUTPUT_WIDTH-1:0] m_data,
    output wire m_valid,
    input  wire m_ready,
    // Per-result metadata, qualified by m_valid. This flag is not sticky.
    // Downstream buffering must store it together with the corresponding data.
    output wire m_saturated,
    output wire idle
);
    // Retain every product bit, then add enough guard bits for the complete sum.
    // Example: 16-by-16 multiplication gives 32 bits; 8 taps add 3 guard bits.
    localparam integer PRODUCT_WIDTH = DATA_WIDTH + COEFF_WIDTH;
    localparam integer GROWTH_BITS = $clog2(TAPS);
    localparam integer ACC_WIDTH = PRODUCT_WIDTH + GROWTH_BITS;
    // A wide output needs a wide comparison/shift operand even if ACC_WIDTH is
    // smaller. Otherwise the output slice could extend beyond the accumulator.
    localparam integer SCALE_WIDTH = (ACC_WIDTH > OUTPUT_WIDTH) ? ACC_WIDTH : OUTPUT_WIDTH;
    localparam integer SHIFT = INPUT_FRAC_BITS + COEFF_FRAC_BITS - OUTPUT_FRAC_BITS;
    // The current sample comes directly from s_data, so only TAPS-1 OLD samples
    // need storage. The one-element placeholder avoids an invalid empty array
    // for TAPS=1; the generate condition below removes its sequential hardware.
    localparam integer HISTORY_DEPTH = (TAPS > 1) ? TAPS-1 : 1;
    // Build signed output rails already extended to the comparison width:
    //   max =  2^(OUTPUT_WIDTH-1) - 1; min = -2^(OUTPUT_WIDTH-1).
    // Extending the minimum with ones preserves its two's-complement sign.
    localparam signed [SCALE_WIDTH-1:0] OUTPUT_MAX =
        {{(SCALE_WIDTH-OUTPUT_WIDTH){1'b0}}, 1'b0, {(OUTPUT_WIDTH-1){1'b1}}};
    localparam signed [SCALE_WIDTH-1:0] OUTPUT_MIN =
        {{(SCALE_WIDTH-OUTPUT_WIDTH){1'b1}}, 1'b1, {(OUTPUT_WIDTH-1){1'b0}}};

    // Payload storage and combinational arithmetic. Valid flags separately
    // identify which registered payloads correspond to real transactions.
    reg signed [DATA_WIDTH-1:0] history [0:HISTORY_DEPTH-1];
    wire signed [COEFF_WIDTH-1:0] coeff [0:TAPS-1];
    reg signed [PRODUCT_WIDTH-1:0] products [0:TAPS-1];
    wire signed [ACC_WIDTH-1:0] sum_tree [0:2*TAPS-2];
    wire signed [ACC_WIDTH-1:0] acc_sum;
    wire signed [SCALE_WIDTH-1:0] extended_sum;
    wire signed [SCALE_WIDTH-1:0] scaled;
    reg signed [OUTPUT_WIDTH-1:0] out_data;
    reg out_saturated;
    // mul_valid qualifies products[]; out_valid qualifies out_data/out_saturated.
    // Stale payload bits may remain in an invalid stage and must be ignored.
    reg mul_valid;
    reg out_valid;
    wire advance;
    wire accept;
    wire clear_accepted;
    integer i, j;

    // Parameter checks run in simulation, not as physical reset/control logic.
    // A negative SHIFT would require left-shift behavior outside this contract.
    // Preserve the translate_off/on directives: synthesis tools interpret them.
    // synthesis translate_off
    initial begin
        if (DATA_WIDTH < 2 || DATA_WIDTH > 32 || COEFF_WIDTH < 2 || COEFF_WIDTH > 32 ||
            OUTPUT_WIDTH < 2 || OUTPUT_WIDTH > 32)
            $fatal(1, "FIR data/coefficient/output widths must be in [2,32]");
        if (TAPS < 1 || TAPS > 32 || (TAPS & (TAPS-1)) != 0)
            $fatal(1, "FIR TAPS must be a power of two in [1,32]");
        if (INPUT_FRAC_BITS < 0 || INPUT_FRAC_BITS >= DATA_WIDTH ||
            COEFF_FRAC_BITS < 0 || COEFF_FRAC_BITS >= COEFF_WIDTH ||
            OUTPUT_FRAC_BITS < 0 || OUTPUT_FRAC_BITS >= OUTPUT_WIDTH || SHIFT < 0)
            $fatal(1, "Invalid FIR fractional-bit counts or negative output shift");
    end
    // synthesis translate_on

    // Historical samples describe filter state, not pending output transactions.
    // Therefore a drained filter is idle even if its sample history is nonzero.
    assign idle = !mul_valid && !out_valid;
    // Global clock enable for both valid stages: an empty output can be filled,
    // or a ready receiver can consume/replace the currently valid output.
    // When the output is blocked, the entire pipeline conservatively freezes.
    assign advance = !out_valid || m_ready;
    // Clear takes priority over NEW input acceptance, including on an idle edge
    // where the source is presenting valid data. The source must hold that data.
    assign s_ready = resetn && advance && !history_clear;
    assign accept = s_valid && s_ready;
    // A busy pulse blocks new input for its duration but does not clear history.
    // If held high, the request is serviced on a later edge after draining.
    assign clear_accepted = history_clear && idle;
    assign m_valid = resetn && out_valid;
    // Payload and metadata are meaningful only when m_valid is high. Neither is
    // forced to zero when invalid, avoiding unnecessary combinational masking.
    assign m_data = out_data;
    assign m_saturated = out_saturated;

    genvar k;
    generate
        // These loops are elaboration-time hardware generation, not a runtime
        // processor loop: all taps have their own connections and arithmetic.
        for (k = 0; k < TAPS; k = k + 1) begin : unpack_coeff
            // Declaring each extracted word signed makes multiplication use the
            // intended negative coefficient values rather than unsigned words.
            assign coeff[k] = coefficients[k*COEFF_WIDTH +: COEFF_WIDTH];
            if (GROWTH_BITS > 0) begin : extend_product
                // Replicate the sign bit before addition; zero-extension would
                // turn negative products into positive accumulator operands.
                assign sum_tree[TAPS-1+k] = {{GROWTH_BITS{products[k][PRODUCT_WIDTH-1]}}, products[k]};
            end else begin : full_width_product
                assign sum_tree[TAPS-1+k] = products[k];
            end
        end
        // There are 2*TAPS-1 nodes: leaves occupy TAPS-1 .. 2*TAPS-2,
        // internal nodes occupy 0 .. TAPS-2, and node 0 is the complete sum.
        // TAPS=1 has a single leaf/root and generates no adders.
        // Heap layout: each node adds its two children. The power-of-two tap
        // constraint gives log2(TAPS) adder levels instead of a linear chain.
        for (k = 0; k < TAPS-1; k = k + 1) begin : add_tree
            // Keep addition in fabric so synthesis does not reassociate the
            // tree into a long DSP cascade. Multipliers still infer DSPs.
            // All nodes retain ACC_WIDTH bits; no intermediate rounding or
            // clipping is permitted because it would alter the filter result.
            (* use_dsp = "no" *) wire signed [ACC_WIDTH-1:0] node_sum;
            assign node_sum = sum_tree[2*k+1] + sum_tree[2*k+2];
            assign sum_tree[k] = node_sum;
        end
        if (TAPS > 1) begin : sample_history
            always @(posedge clk) begin
                // Hardware reset has priority. An accepted clear starts a new
                // history epoch while preserving the external coefficient bus.
                if (!resetn || clear_accepted) begin
                    for (i = 0; i < HISTORY_DEPTH; i = i + 1)
                        history[i] <= {DATA_WIDTH{1'b0}};
                end else if (accept) begin
                    // Nonblocking assignments read OLD history values, even
                    // though history[0] is assigned earlier in this same block.
                    history[0] <= s_data;
                    for (i = 1; i < HISTORY_DEPTH; i = i + 1)
                        history[i] <= history[i-1];
                end
            end
        end
        if (SCALE_WIDTH > ACC_WIDTH) begin : widen_accumulator
            // This branch supports output words wider than the raw accumulator.
            assign extended_sum = {{(SCALE_WIDTH-ACC_WIDTH){acc_sum[ACC_WIDTH-1]}}, acc_sum};
        end else begin : full_width_accumulator
            // Keep equal-width cases explicit instead of using zero replication.
            assign extended_sum = acc_sum;
        end
    endgenerate

    always @(posedge clk) begin
        if (!resetn) begin
            mul_valid <= 1'b0;
            out_valid <= 1'b0;
        end else if (advance) begin
            // A cycle with no accepted input inserts an INVALID pipeline bubble.
            // It does not shift a zero sample into filter history.
            // out_valid reads the OLD mul_valid, keeping data and validity aligned.
            mul_valid <= accept;
            out_valid <= mul_valid;
        end
    end

    // Stage 1: all multiplications execute in parallel for one accepted sample.
    always @(posedge clk) begin
        if (!resetn) begin
            for (j = 0; j < TAPS; j = j + 1)
                products[j] <= {PRODUCT_WIDTH{1'b0}};
        end else if (accept) begin
            // History shifts on this edge too, so the newest sample must be
            // taken directly from the input. history[0] still means x[n-1].
            products[0] <= s_data * coeff[0];
            for (j = 1; j < TAPS; j = j + 1)
                products[j] <= history[j-1] * coeff[j];
        end
    end

    assign acc_sum = sum_tree[0];

    // Extend before shifting so a wider output format also preserves sign.
    // >>> is arithmetic because extended_sum is signed. Discarding low bits
    // rounds negative fractions toward minus infinity, matching Python >>.
    // Example: shifting signed -3 right by one produces -2, not -1.
    assign scaled = extended_sum >>> SHIFT;

    // Stage 2: scale, clamp and register the complete result atomically.
    always @(posedge clk) begin
        if (!resetn) begin
            out_data <= {OUTPUT_WIDTH{1'b0}};
            out_saturated <= 1'b0;
        end else if (advance && mul_valid) begin
            // Compare at full precision BEFORE selecting output bits. Narrowing
            // first would wrap an overflow and make the range test ineffective.
            if (scaled > OUTPUT_MAX) begin
                out_data <= OUTPUT_MAX[OUTPUT_WIDTH-1:0];
                out_saturated <= 1'b1;
            end else if (scaled < OUTPUT_MIN) begin
                out_data <= OUTPUT_MIN[OUTPUT_WIDTH-1:0];
                out_saturated <= 1'b1;
            end else begin
                // Equality with a rail is representable and is not saturation.
                out_data <= scaled[OUTPUT_WIDTH-1:0];
                out_saturated <= 1'b0;
            end
        end
        // No assignment while stalled: both data and its flag remain stable.
        // An invalid multiplier stage also leaves payload bits untouched.
    end
endmodule
