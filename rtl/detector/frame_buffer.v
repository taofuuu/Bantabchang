// frame_buffer: ingest the streaming filter output, hold one 160x120 frame.
//
// Write side (from teammate filter):
//   - pixel[7:0]  : grayscale pixel
//   - pixel_valid : 1-cycle pulse per pixel
//   - frame_start : co-occurs with pixel_valid for pixel (0,0)
//   - line_start  : co-occurs with pixel_valid for the first pixel of every row
//                   (informational; we trust the upstream raster order)
//
// Internally the write address is a single 15-bit counter (15 bits covers
// 0..19199). On frame_start it forces the first pixel to addr 0 and arms the
// counter to 1; on every subsequent pixel_valid it increments.
//
// frame_done pulses for one cycle on the cycle the 19200th pixel is written.
//
// Read side (to patch extractor):
//   - r_addr[14:0] : linear address (= y*160 + x)
//   - r_data[7:0]  : pixel value, 1-cycle synchronous read
//
// Vivado will infer a single 19200x8 Block RAM.

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

    // Combinational write address: frame_start forces pixel (0,0) regardless
    // of where wr_ptr was, which is how we recover from a partial frame.
    wire [ADDR_W-1:0] write_addr = (pixel_valid && frame_start)
                                 ? {ADDR_W{1'b0}}
                                 : wr_ptr;

    // unused but listed in port map for documentation; this dummy assign
    // prevents a "signal driven but not used" warning in some tools.
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
                    // wrote pixel 0, next pixel goes to addr 1
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

    // synchronous read port
    always @(posedge clk) begin
        r_data <= mem[r_addr];
    end

endmodule

`default_nettype wire
