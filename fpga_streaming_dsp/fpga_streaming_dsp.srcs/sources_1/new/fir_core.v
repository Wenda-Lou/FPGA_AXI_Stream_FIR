module fir_core (
    input  wire               clk,
    input  wire               resetn,
    input  wire       [127:0] coefficients,

    input  wire signed [15:0] s_data,
    input  wire               s_valid,
    output wire               s_ready,

    output wire signed [15:0] m_data,
    output wire               m_valid,
    input  wire               m_ready
);

    reg signed [15:0] history [0:7];

    wire accept;
    integer i;
    reg mul_valid;
    reg out_valid;
    wire advance;

    assign accept = s_valid && s_ready;
    assign advance = !out_valid || m_ready;

    assign s_ready = resetn && advance;
    assign m_valid = resetn && out_valid;

    always @(posedge clk) begin
        if (!resetn) begin
            for (i = 0; i < 8; i = i + 1) begin
                history[i] <= 16'sd0;
            end
        end else if (accept) begin
            history[0] <= s_data;
            for (i = 1; i < 8; i = i + 1) begin
                history[i] <= history[i-1];
            end
        end
    end

    always @(posedge clk) begin
        if (!resetn) begin
            mul_valid <= 1'b0;
            out_valid <= 1'b0;
        end else if (advance) begin
            mul_valid <= accept;
            out_valid <= mul_valid;
        end
    end

    wire signed [15:0] coeff [0:7];
    reg signed [31:0] products [0:7];

    genvar k;
    generate
        for (k = 0; k < 8; k = k + 1) begin : unpack_coeff
            assign coeff[k] = coefficients[k*16 +: 16];
        end
    endgenerate

    integer j;

    always @(posedge clk) begin
        if (!resetn) begin
            for (j = 0; j < 8; j = j + 1)
                products[j] <= 32'sd0;
        end else if (accept) begin
            products[0] <= s_data * coeff[0];

            for (j = 1; j < 8; j = j + 1)
                products[j] <= history[j-1] * coeff[j];
        end
    end

    reg signed [34:0] acc_sum;
    integer t;

    always @(*) begin
        acc_sum = 35'sd0;

        for (t = 0; t < 8; t = t + 1) begin
            acc_sum = acc_sum + $signed({{3{products[t][31]}}, products[t]});
        end
    end

    wire signed [34:0] scaled;
    reg signed [15:0] out_data;

    assign scaled = acc_sum >>> 15;
    assign m_data = out_data;

    always @(posedge clk) begin
        if (!resetn) begin
            out_data <= 16'sd0;
        end else if (advance && mul_valid) begin
            if (scaled > 35'sd32767)
                out_data <= 16'sh7fff;
            else if (scaled < -35'sd32768)
                out_data <= 16'sh8000;
            else
                out_data <= scaled[15:0];
        end
    end

endmodule