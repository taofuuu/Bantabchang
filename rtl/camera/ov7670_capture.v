`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// OV7670 Camera Capture Module
//
// Two parallel outputs, both clocked by the camera pclk:
//
//   1. Frame-buffer write port (for the VGA preview):
//        320x240 RGB444 → existing dual-port BRAM, 17-bit linear address
//
//   2. Grayscale streaming output (for the NN face detector):
//        160x120 8-bit luma, 2x downsampled, with the
//        pixel/pixel_valid/frame_start/line_start handshake from
//        docs/INTERFACES.md.
//
// Both outputs are produced from the same RGB565 byte pair, so we never
// re-read the camera. The CDC into the system clock domain happens
// downstream in pixel_stream_cdc.v.
//////////////////////////////////////////////////////////////////////////////////

module ov7670_capture(
    input  wire        pclk,           // ~24 MHz pixel clock from camera
    input  wire        vsync,
    input  wire        href,
    input  wire [7:0]  data_in,
    input  wire        reset,

    // RGB444 frame-buffer write port (camera-side of dual-port BRAM)
    output reg  [16:0] frame_addr,
    output reg  [11:0] frame_pixel,
    output reg         frame_we,

    // Grayscale stream for the detector (in pclk domain).
    // All four signals are coincident; valid is a 1-pclk-cycle pulse.
    output reg         stream_valid,
    output reg         stream_frame_start,
    output reg         stream_line_start,
    output reg [7:0]   stream_pixel
);

    parameter FRAME_WIDTH  = 320;
    parameter FRAME_HEIGHT = 240;
    parameter MAX_ADDR     = FRAME_WIDTH * FRAME_HEIGHT - 1;

    localparam WAIT_FRAME    = 2'd0;
    localparam CAPTURE_BYTE1 = 2'd1;
    localparam CAPTURE_BYTE2 = 2'd2;

    reg [1:0] state;
    reg [7:0] byte1;
    reg       prev_vsync;

    // Coordinate counters in the native 320x240 grid.
    reg [8:0] pixel_x;     // 0..319
    reg [7:0] pixel_y;     // 0..239

    // RGB565 components (byte1 = first/high byte, data_in = second/low byte).
    wire [4:0] rgb565_r = byte1[7:3];
    wire [5:0] rgb565_g = {byte1[2:0], data_in[7:5]};
    wire [4:0] rgb565_b = data_in[4:0];

    // RGB444 for the VGA preview path.
    wire [3:0] rgb444_r = rgb565_r[4:1];
    wire [3:0] rgb444_g = rgb565_g[5:2];
    wire [3:0] rgb444_b = rgb565_b[4:1];

    // Promote 5/6/5-bit channels to 8-bit by replicating MSBs.
    wire [7:0] r8 = {rgb565_r, rgb565_r[4:2]};
    wire [7:0] g8 = {rgb565_g, rgb565_g[5:4]};
    wire [7:0] b8 = {rgb565_b, rgb565_b[4:2]};

    // Luma ~= (R + 2G + B) / 4 — green-weighted, no multipliers needed.
    wire [9:0] y_sum = r8 + (g8 << 1) + b8;
    wire [7:0] gray8 = y_sum[9:2];

    // We keep every other column AND every other row -> 160x120 grid.
    wire keep_pixel = (pixel_x[0] == 1'b0) && (pixel_y[0] == 1'b0);

    always @(posedge pclk or posedge reset) begin
        if (reset) begin
            state              <= WAIT_FRAME;
            frame_addr         <= 0;
            frame_we           <= 1'b0;
            prev_vsync         <= 1'b0;
            pixel_x            <= 9'd0;
            pixel_y            <= 8'd0;
            stream_valid       <= 1'b0;
            stream_frame_start <= 1'b0;
            stream_line_start  <= 1'b0;
            stream_pixel       <= 8'd0;
        end else begin
            prev_vsync         <= vsync;
            frame_we           <= 1'b0;
            stream_valid       <= 1'b0;
            stream_frame_start <= 1'b0;
            stream_line_start  <= 1'b0;

            // Rising edge of vsync = start of the blanking interval; reset for
            // the next active frame (matches the original module's polarity).
            if (!prev_vsync && vsync) begin
                frame_addr <= 0;
                pixel_x    <= 9'd0;
                pixel_y    <= 8'd0;
                state      <= WAIT_FRAME;
            end else begin
                case (state)
                    WAIT_FRAME: begin
                        if (href) state <= CAPTURE_BYTE1;
                    end

                    CAPTURE_BYTE1: begin
                        if (href) begin
                            byte1 <= data_in;
                            state <= CAPTURE_BYTE2;
                        end else begin
                            // End of line mid-byte: advance to next row.
                            pixel_x <= 9'd0;
                            pixel_y <= pixel_y + 8'd1;
                            state   <= WAIT_FRAME;
                        end
                    end

                    CAPTURE_BYTE2: begin
                        if (href) begin
                            // Complete RGB pixel: write to VGA frame buffer.
                            frame_pixel <= {rgb444_r, rgb444_g, rgb444_b};
                            frame_we    <= 1'b1;
                            if (frame_addr < MAX_ADDR)
                                frame_addr <= frame_addr + 1'b1;

                            // Emit one downsampled grayscale pixel to the detector.
                            if (keep_pixel) begin
                                stream_valid       <= 1'b1;
                                stream_pixel       <= gray8;
                                stream_frame_start <= (pixel_x == 9'd0) && (pixel_y == 8'd0);
                                stream_line_start  <= (pixel_x == 9'd0);
                            end

                            // Advance horizontal counter; row wrap is handled by
                            // href falling, so we only saturate here.
                            if (pixel_x < FRAME_WIDTH - 1)
                                pixel_x <= pixel_x + 9'd1;

                            state <= CAPTURE_BYTE1;
                        end else begin
                            pixel_x <= 9'd0;
                            pixel_y <= pixel_y + 8'd1;
                            state   <= WAIT_FRAME;
                        end
                    end

                    default: state <= WAIT_FRAME;
                endcase
            end
        end
    end

endmodule
