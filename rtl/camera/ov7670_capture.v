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

    // YUV422 UYVY decode.
    //
    // Several SCCB writes (notably COM7's RGB-enable bit and COM15) appear
    // to be lost by ov7670_config.v's flaky protocol, so the camera is
    // stuck in YUV422 mode regardless of what we ask for. The byte stream
    // per pixel pair is therefore (U, Y0, V, Y1) — i.e. byte1 = chroma
    // (alternating U/V) and data_in = the luma sample for the current pixel.
    //
    // Diagnostic that confirmed this: lens covered → uniform red on the
    // VGA preview, which is exactly what bytes (0x80, 0x00) decode to when
    // mis-interpreted as RGB565. Y=0, U=V=0x80 ⇒ 0x80,0x00 ⇒ R=16,G=0,B=0.
    //
    // For face detection we only need luma, and Y is the correct luma —
    // cleaner than the (R+2G+B)/4 approximation we were doing on the
    // mis-decoded RGB. So we just take Y and display it as grayscale.
    wire [7:0] luma_y = data_in;

    // RGB444 preview = grayscale (R = G = B = Y[7:4]).
    wire [3:0] rgb444_r = luma_y[7:4];
    wire [3:0] rgb444_g = luma_y[7:4];
    wire [3:0] rgb444_b = luma_y[7:4];

    // Detector grayscale stream — Y directly.
    wire [7:0] gray8 = luma_y;

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
                        // First HREF=1 cycle of a line: data_in is already
                        // byte-0 of pixel-0. Latch it on this same edge,
                        // otherwise the whole line is shifted by one byte.
                        if (href) begin
                            byte1 <= data_in;
                            state <= CAPTURE_BYTE2;
                        end
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
