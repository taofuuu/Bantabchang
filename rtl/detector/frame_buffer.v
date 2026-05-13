// holds one 160x120 grayscale frame
// write: streaming pixel_valid/frame_start 
// read: random 15-bit addr, 1-cycle latency
// frame_done pulses on the last pixel of each frame

`default_nettype none

module frame_buffer #(
    parameter FRAME_W = 160,
    parameter FRAME_H = 120,
    parameter ADDR_W  = 15        // ceil(log2(160*120)) = 15
) (
    input  wire             clk,
    input  wire             rst,           // synchronous, active high

    // streaming write port
    input  wire             pixel_valid,
    input  wire             frame_start,
    input  wire             line_start,    // unused but accepted (sync hint)
    input  wire [7:0]       pixel,
    output reg              frame_done,    // 1-cycle pulse at end of frame

    // random read port
    input  wire [ADDR_W-1:0] r_addr,
    output reg  [7:0]        r_data
);

    localparam FRAME_PIXELS = FRAME_W * FRAME_H;     // 19200

    reg [7:0]        mem [0:FRAME_PIXELS-1];
    reg [ADDR_W-1:0] wr_ptr;                          // next write address

    // frame_start resets write addr to 0, recovering from partial frames
    wire [ADDR_W-1:0] write_addr = (pixel_valid && frame_start)
                                 ? {ADDR_W{1'b0}}
                                 : wr_ptr;

    // suppress unused warning
    wire _unused_line_start = line_start;

    always @(posedge clk) begin
        if (rst) begin
            wr_ptr     <= {ADDR_W{1'b0}};
            frame_done <= 1'b0;
        end else begin
            frame_done <= 1'b0;
            if (pixel_valid) begin
                mem[write_addr] <= pixel;
                if (frame_start) begin
                    // wrote pixel 0, next goes to addr 1
                    wr_ptr <= {{(ADDR_W-1){1'b0}}, 1'b1};
                end else begin
                    wr_ptr <= wr_ptr + 1'b1;
                    if (wr_ptr == FRAME_PIXELS - 1) begin
                        frame_done <= 1'b1;
                    end
                end
            end
        end
    end

    // read port
    always @(posedge clk) begin
        r_data <= mem[r_addr];
    end

endmodule

`default_nettype wire
