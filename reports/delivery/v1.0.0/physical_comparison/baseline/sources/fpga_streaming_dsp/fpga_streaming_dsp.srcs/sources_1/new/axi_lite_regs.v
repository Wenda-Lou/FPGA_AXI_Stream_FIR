// Single-clock AXI4-Lite register bank, with independent AW/W capture and one
// outstanding transaction in each direction. Address offsets are byte addresses.
// Datapath events are already-qualified handshakes, not raw valid levels.
module axi_lite_regs #(
    parameter integer TAPS = 8,
    parameter integer COEFF_WIDTH = 16
) (
    input wire clk,
    input wire resetn,
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
    input wire s_axi_rready,

    input wire datapath_idle,
    input wire input_transfer,
    input wire output_transfer,
    input wire saturation_event,
    output reg enable,
    output wire [TAPS*COEFF_WIDTH-1:0] coefficients,
    // Qualified combinational strobes, sampled on the SAME commit edge as the
    // coefficient/control update. This avoids a delayed clear after re-enabling.
    output wire history_clear,
    output wire soft_clear
);
    localparam [1:0] OKAY = 2'b00, SLVERR = 2'b10;
    reg aw_pending, w_pending;
    reg [7:0] write_address;
    reg [31:0] write_data;
    reg [3:0] write_strobes;
    reg b_valid, r_valid;
    reg [1:0] b_response, r_response;
    reg [31:0] r_data;
    reg [COEFF_WIDTH-1:0] coefficient_regs [0:TAPS-1];
    reg [31:0] input_count, output_count;
    reg saturated;

    wire write_commit;
    wire coefficient_address;
    wire [5:0] write_index, read_index;
    reg coefficient_effective;
    reg write_ok, clear_command;
    reg [31:0] read_value;
    reg [1:0] read_response;
    integer lane, k, bit_index;

    // PROT attributes are accepted but do not alter this peripheral's access
    // policy. Unmapped, unaligned and read-only writes are errors even at WSTRB=0.
    // synthesis translate_off
    initial begin
        if (TAPS < 1 || TAPS > 32 || (TAPS & (TAPS-1)) != 0)
            $fatal(1, "AXI register TAPS must be a power of two in [1,32]");
        if (COEFF_WIDTH < 2 || COEFF_WIDTH > 32)
            $fatal(1, "AXI register COEFF_WIDTH must be in [2,32]");
    end
    // synthesis translate_on

    // Conservative channel capacity: consume a response before advertising any
    // room for the next write, or the next read. AW and W remain independent.
    assign s_axi_awready = resetn && !aw_pending && !b_valid;
    assign s_axi_wready = resetn && !w_pending && !b_valid;
    assign s_axi_arready = resetn && !r_valid;
    assign s_axi_bvalid = resetn && b_valid;
    assign s_axi_bresp = b_response;
    assign s_axi_rvalid = resetn && r_valid;
    assign s_axi_rresp = r_response;
    assign s_axi_rdata = r_data;
    assign write_commit = resetn && aw_pending && w_pending && !b_valid;
    assign coefficient_address = write_address >= 8'h20 && write_address < (32+4*TAPS);
    assign write_index = write_address[7:2] - 6'd8;
    assign read_index = s_axi_araddr[7:2] - 6'd8;

    // An effective coefficient strobe overlaps at least one implemented bit.
    // High byte lanes above a narrow coefficient field are successful no-ops,
    // including while busy/enabled; they do not clear history.
    always @(*) begin
        coefficient_effective = 1'b0;
        for (lane = 0; lane < 4; lane = lane+1)
            if (lane*8 < COEFF_WIDTH && write_strobes[lane])
                coefficient_effective = 1'b1;
        write_ok = 1'b0;
        clear_command = 1'b0;
        if (write_address[1:0] == 0) begin
            if (write_address == 8'h00) begin
                clear_command = write_strobes[0] && write_data[1];
                // Reject the entire CONTROL write if soft clear is illegal;
                // neither ENABLE nor any status/counter may change from it.
                write_ok = !clear_command || (!enable && datapath_idle && !write_data[0]);
            end else if (coefficient_address) begin
                write_ok = !coefficient_effective || (!enable && datapath_idle);
            end
        end
    end
    assign soft_clear = write_commit && write_ok && clear_command;
    assign history_clear = soft_clear ||
                           (write_commit && write_ok && coefficient_address && coefficient_effective);

    // Read snapshot uses PRE-EDGE state. A concurrent commit or event increments
    // registers via nonblocking assignments, so it appears only in later reads.
    always @(*) begin
        read_value = 32'd0;
        read_response = SLVERR;
        if (s_axi_araddr[1:0] == 0) begin
            case (s_axi_araddr)
                8'h00: begin read_value = {31'd0, enable}; read_response = OKAY; end
                8'h04: begin read_value = {29'd0, saturated, !datapath_idle, datapath_idle}; read_response = OKAY; end
                8'h08: begin read_value = input_count; read_response = OKAY; end
                8'h0c: begin read_value = output_count; read_response = OKAY; end
                default: begin
                    if (s_axi_araddr >= 8'h20 && s_axi_araddr < (32+4*TAPS)) begin
                        // Explicit signed cast sign-extends narrow coefficients;
                        // at COEFF_WIDTH=32 it simply preserves all register bits.
                        read_value = $signed(coefficient_regs[read_index]);
                        read_response = OKAY;
                    end
                end
            endcase
        end
    end

    // Capture each half of a write once. Commit occurs on the first edge AFTER
    // both buffered halves are present, independent of their arrival order.
    always @(posedge clk) begin
        if (!resetn) begin
            aw_pending <= 1'b0;
            w_pending <= 1'b0;
            write_address <= 8'd0;
            write_data <= 32'd0;
            write_strobes <= 4'd0;
            b_valid <= 1'b0;
            b_response <= OKAY;
        end else begin
            if (s_axi_awvalid && s_axi_awready) begin
                aw_pending <= 1'b1;
                write_address <= s_axi_awaddr;
            end
            if (s_axi_wvalid && s_axi_wready) begin
                w_pending <= 1'b1;
                write_data <= s_axi_wdata;
                write_strobes <= s_axi_wstrb;
            end
            if (write_commit) begin
                aw_pending <= 1'b0;
                w_pending <= 1'b0;
                b_valid <= 1'b1;
                b_response <= write_ok ? OKAY : SLVERR;
            end else if (b_valid && s_axi_bready) begin
                b_valid <= 1'b0;
            end
        end
    end

    // Register the complete read response once; live counters/status are not
    // connected to RDATA after capture, keeping payload stable under R stalls.
    always @(posedge clk) begin
        if (!resetn) begin
            r_valid <= 1'b0;
            r_data <= 32'd0;
            r_response <= OKAY;
        end else if (s_axi_arvalid && s_axi_arready) begin
            r_valid <= 1'b1;
            r_data <= read_value;
            r_response <= read_response;
        end else if (r_valid && s_axi_rready) begin
            r_valid <= 1'b0;
        end
    end

    genvar tap;
    generate
        for (tap = 0; tap < TAPS; tap = tap+1) begin : pack_coefficients
            assign coefficients[tap*COEFF_WIDTH +: COEFF_WIDTH] = coefficient_regs[tap];
        end
    endgenerate

    // WSTRB writes only overlapping coefficient bits; upper reserved bits are
    // ignored. Even an unchanged effective write starts a fresh history epoch.
    always @(posedge clk) begin
        if (!resetn) begin
            enable <= 1'b0;
            for (k = 0; k < TAPS; k = k+1) coefficient_regs[k] <= {COEFF_WIDTH{1'b0}};
        end else if (write_commit && write_ok) begin
            if (write_address == 8'h00 && write_strobes[0]) enable <= write_data[0];
            if (coefficient_address && coefficient_effective)
                for (bit_index = 0; bit_index < COEFF_WIDTH; bit_index = bit_index+1)
                    if (write_strobes[bit_index/8])
                        coefficient_regs[write_index][bit_index] <= write_data[bit_index];
        end
    end

    // Events count regardless of ENABLE, because accepted work can still leave
    // the disabled datapath. Natural 32-bit addition wraps modulo 2^32.
    // Priority is hardware reset, then legal soft clear, then event updates.
    always @(posedge clk) begin
        if (!resetn) begin
            input_count <= 32'd0;
            output_count <= 32'd0;
            saturated <= 1'b0;
        end else if (soft_clear) begin
            input_count <= 32'd0;
            output_count <= 32'd0;
            saturated <= 1'b0;
        end else begin
            if (input_transfer) input_count <= input_count + 32'd1;
            if (output_transfer) output_count <= output_count + 32'd1;
            if (saturation_event) saturated <= 1'b1;
        end
    end
endmodule
