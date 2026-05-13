`timescale 1ns / 1ps
`default_nettype none
// Performs safe Clock Domain Crossing (CDC) for pixel data
// using toggle-based synchronizer, ensuring data stability when moving from the camera pclk

module pixel_stream_cdc(
    // Source domain: camera pclk
    input  wire        src_clk,
    input  wire        src_rst,
    input  wire        src_valid,
    input  wire        src_line_start,
    input  wire        src_frame_start,
    input  wire [7:0]  src_pixel,

    // Destination domain: system clk
    input  wire        dst_clk,
    input  wire        dst_rst,
    output reg         dst_valid,
    output reg         dst_frame_start,
    output reg         dst_line_start,
    output reg  [7:0]  dst_pixel
);

    //flag every new pixel
    reg        src_toggle;
    //latched
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

    // 2-stage synchronizer (FF) for stability
    (* ASYNC_REG = "TRUE" *) reg toggle_meta;
    (* ASYNC_REG = "TRUE" *) reg toggle_sync;
    // Edge-detection
    reg toggle_prev;

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
