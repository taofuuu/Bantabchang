// Test wrapper: wires frame_buffer + patch_extractor + act_buffer together
// so the cocotb test can ingest a 160x120 frame, kick off extraction, and
// then read the patch buffer to verify byte-for-byte.

`default_nettype none

module wrap_patch_extractor (
    input  wire        clk,
    input  wire        rst,

    // frame ingestion
    input  wire        pixel_valid,
    input  wire        frame_start,
    input  wire        line_start,
    input  wire [7:0]  pixel,
    output wire        frame_done,

    // patch_extractor control
    input  wire        start,
    input  wire [7:0]  patch_x,
    input  wire [6:0]  patch_y,
    input  wire [2:0]  dilate_in,
    output wire        pe_done,

    // act_buffer read port for the test
    input  wire [9:0]        ab_r_addr,
    output wire signed [7:0] ab_r_data
);

    wire [14:0]      fb_r_addr;
    wire [7:0]       fb_r_data;
    wire             ab_we;
    wire [9:0]       ab_w_addr;
    wire signed [7:0] ab_w_data;

    frame_buffer u_fb (
        .clk(clk), .rst(rst),
        .pixel_valid(pixel_valid),
        .frame_start(frame_start),
        .line_start(line_start),
        .pixel(pixel),
        .frame_done(frame_done),
        .r_addr(fb_r_addr),
        .r_data(fb_r_data)
    );

    patch_extractor u_pe (
        .clk(clk), .rst(rst),
        .start(start),
        .patch_x(patch_x),
        .patch_y(patch_y),
        .dilate_in(dilate_in),
        .done(pe_done),
        .fb_r_addr(fb_r_addr),
        .fb_r_data(fb_r_data),
        .ab_we(ab_we),
        .ab_w_addr(ab_w_addr),
        .ab_w_data(ab_w_data)
    );

    act_buffer #(
        .WIDTH(8), .DEPTH(576), .ADDR_W(10)
    ) u_ab (
        .clk(clk),
        .we(ab_we), .w_addr(ab_w_addr), .w_data(ab_w_data),
        .r_addr(ab_r_addr), .r_data(ab_r_data)
    );

endmodule

`default_nettype wire
