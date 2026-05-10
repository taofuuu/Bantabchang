`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// pixel_stream_cdc
//
// Move a 1-pixel-per-strobe handshake from the camera pclk domain to the system
// clk domain. Uses the textbook "MCP formulation":
//
//   - In src domain (pclk), latch {pixel, frame_start, line_start} into a stable
//     register and toggle a 1-bit flag whenever a new pixel arrives.
//   - In dst domain (clk), 2-FF synchronize the toggle, edge-detect it, and
//     re-emit pixel_valid as a 1-clk pulse together with the now-stable data.
//
// This is safe because the data bus is held constant for an entire pclk period
// (~42 ns) while the dst clk samples it at 100 MHz — far more than the 2 dst
// cycles needed for the synchronizer to settle. Adjacent pclk strobes are at
// least 2 pclk cycles apart in our use case, which is also fine.
//
// We could replace this with xpm_fifo_async, but a FIFO doesn't help: the
// detector either accepts every pixel of the next frame or it isn't ready and
// drops it; backpressure would just stall the camera.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module pixel_stream_cdc(
    // Source domain: camera pclk
    input  wire        src_clk,
    input  wire        src_rst,
    input  wire        src_valid,
    input  wire        src_frame_start,
    input  wire        src_line_start,
    input  wire [7:0]  src_pixel,

    // Destination domain: system clk
    input  wire        dst_clk,
    input  wire        dst_rst,
    output reg         dst_valid,
    output reg         dst_frame_start,
    output reg         dst_line_start,
    output reg  [7:0]  dst_pixel
);

    // ------------------------------------------------------------------
    // Source side: latch the payload and toggle a flag on every new pixel.
    // ------------------------------------------------------------------
    reg        src_toggle;
    reg [7:0]  src_pixel_l;
    reg        src_frame_start_l;
    reg        src_line_start_l;

    always @(posedge src_clk or posedge src_rst) begin
        if (src_rst) begin
            src_toggle        <= 1'b0;
            src_pixel_l       <= 8'd0;
            src_frame_start_l <= 1'b0;
            src_line_start_l  <= 1'b0;
        end else if (src_valid) begin
            src_pixel_l       <= src_pixel;
            src_frame_start_l <= src_frame_start;
            src_line_start_l  <= src_line_start;
            src_toggle        <= ~src_toggle;
        end
    end

    // ------------------------------------------------------------------
    // Destination side: 2-FF synchronize the toggle, edge-detect, sample data.
    // ------------------------------------------------------------------
    (* ASYNC_REG = "TRUE" *) reg toggle_meta;
    (* ASYNC_REG = "TRUE" *) reg toggle_sync;
    reg                      toggle_prev;

    always @(posedge dst_clk or posedge dst_rst) begin
        if (dst_rst) begin
            toggle_meta     <= 1'b0;
            toggle_sync     <= 1'b0;
            toggle_prev     <= 1'b0;
            dst_valid       <= 1'b0;
            dst_frame_start <= 1'b0;
            dst_line_start  <= 1'b0;
            dst_pixel       <= 8'd0;
        end else begin
            toggle_meta <= src_toggle;
            toggle_sync <= toggle_meta;
            toggle_prev <= toggle_sync;

            // One-cycle pulse on each toggle edge.
            dst_valid <= (toggle_sync ^ toggle_prev);
            if (toggle_sync ^ toggle_prev) begin
                dst_pixel       <= src_pixel_l;
                dst_frame_start <= src_frame_start_l;
                dst_line_start  <= src_line_start_l;
            end
        end
    end

endmodule

`default_nettype wire
