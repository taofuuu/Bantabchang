// Test wrapper that pins detector_top's weight-file parameters to absolute
// paths so $readmemh can find them during simulation.

`default_nettype none

module wrap_detector_top (
    input  wire        clk,
    input  wire        rst,

    input  wire        pixel_valid,
    input  wire        frame_start,
    input  wire        line_start,
    input  wire [7:0]  pixel,

    output wire        face_valid,
    output wire [7:0]  face_x,
    output wire [6:0]  face_y,
    output wire [7:0]  face_w,
    output wire [6:0]  face_h,
    output wire        scan_done
);

    detector_top #(
        .STRIDE(16),
        .THRESHOLD(32'sd1000),
        .CONV1_W_FILE("../../weights/conv1_w.hex"),
        .CONV1_B_FILE("../../weights/conv1_b.hex"),
        .CONV2_W_FILE("../../weights/conv2_w.hex"),
        .CONV2_B_FILE("../../weights/conv2_b.hex"),
        .CONV3_W_FILE("../../weights/conv3_w.hex"),
        .CONV3_B_FILE("../../weights/conv3_b.hex"),
        .FC_W_FILE("../../weights/fc_w.hex"),
        .FC_B_FILE("../../weights/fc_b.hex")
    ) u (
        .clk(clk), .rst(rst),
        .pixel_valid(pixel_valid),
        .frame_start(frame_start),
        .line_start(line_start),
        .pixel(pixel),
        .face_valid(face_valid),
        .face_x(face_x), .face_y(face_y),
        .face_w(face_w), .face_h(face_h),
        .scan_done(scan_done)
    );

endmodule

`default_nettype wire
