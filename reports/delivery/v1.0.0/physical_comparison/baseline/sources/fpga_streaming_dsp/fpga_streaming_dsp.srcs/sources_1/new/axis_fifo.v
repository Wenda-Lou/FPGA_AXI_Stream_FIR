// Single-clock, non-bypassing ready/valid FIFO with asynchronous head read.
// DEPTH must be a power of two, at least 2. Full queues reject writes even
// when a read occurs on the same edge; this keeps input ready independent
// of downstream ready. Invalid output data is unspecified when empty.
module axis_fifo #(
    parameter integer DATA_WIDTH = 16,
    parameter integer DEPTH = 16
) (
    input  wire        clk,
    input  wire        resetn,

    input  wire [DATA_WIDTH-1:0] s_data,
    input  wire        s_valid,
    output wire        s_ready,

    output wire [DATA_WIDTH-1:0] m_data,
    output wire        m_valid,
    input  wire        m_ready,

    output reg [$clog2(DEPTH):0] occupancy
);

    localparam integer PTR_WIDTH = $clog2(DEPTH);
    localparam integer COUNT_WIDTH = PTR_WIDTH + 1;
    localparam [COUNT_WIDTH-1:0] CAPACITY = DEPTH;

    wire push;
    wire pop;
    reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];
    reg [PTR_WIDTH-1:0] wr_ptr;
    reg [PTR_WIDTH-1:0] rd_ptr;

    // synthesis translate_off
    initial begin
        if (DATA_WIDTH < 1)
            $fatal(1, "axis_fifo DATA_WIDTH must be positive");
        if (DEPTH < 2 || (DEPTH & (DEPTH - 1)) != 0)
            $fatal(1, "axis_fifo DEPTH must be a power of two, at least 2");
    end
    // synthesis translate_on

    assign m_data = mem[rd_ptr];
    assign push = s_valid && s_ready;
    assign pop  = m_valid && m_ready;
    assign s_ready = resetn && (occupancy < CAPACITY);
    assign m_valid = resetn && (occupancy != {COUNT_WIDTH{1'b0}});

    always @(posedge clk) begin
        if (!resetn) begin
            occupancy <= {COUNT_WIDTH{1'b0}};
        end else begin
            case ({push, pop})
                2'b10: occupancy <= occupancy + 1'b1;
                2'b01: occupancy <= occupancy - 1'b1;
                default: occupancy <= occupancy;
            endcase
        end
    end

    always @(posedge clk) begin
        if (!resetn) begin
            wr_ptr <= {PTR_WIDTH{1'b0}};
            rd_ptr <= {PTR_WIDTH{1'b0}};
        end else begin
            if (push) begin
                mem[wr_ptr] <= s_data;
                wr_ptr <= wr_ptr + 1'b1;
            end
            if (pop) begin
                rd_ptr <= rd_ptr + 1'b1;
            end
        end
    end

endmodule
