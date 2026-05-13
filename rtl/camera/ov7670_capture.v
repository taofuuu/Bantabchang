`timescale 1ns / 1ps
// Captures raw OV7670 camera data by converting RGB565 to RGB444 for BRAM
// generate a downsampled 160x120 grayscale stream.

module ov7670_capture(
    input  wire        pclk,
    input  wire        vsync,
    input  wire        href,
    input  wire [7:0]  data_in,
    input  wire        reset,

    // RGB444 frame-buffer write port (camera side of dual-port BRAM)
    output reg  [16:0] frame_addr,
    output reg  [11:0] frame_pixel,
    output reg         frame_we,

    // 160x120 grayscale stream for the NN face detector (pclk domain)
    output reg         stream_valid,
    output reg         stream_frame_start,
    output reg         stream_line_start,
    output reg  [7:0]  stream_pixel,

    // Diagnostics (pclk domain; top does CDC for LEDs)
    output reg         frame_format_ok,
    output reg         frame_heartbeat
);

    // ----- Edge detectors for vsync/href -----
    reg prev_vsync, prev_href;

    // ----- Byte pairing & native pixel counters -----
    reg [7:0]  hi_byte;
    reg        byte_phase;        // 0 = MSB, 1 = LSB
    reg [10:0] cam_col;           // 0..639
    reg [9:0]  cam_row;           // 0..479

    // RGB565 -> RGB444 decode
    wire [3:0] px_r = hi_byte[7:4];
    wire [3:0] px_g = { hi_byte[2:0], data_in[7] };
    wire [3:0] px_b = data_in[4:1];

    // luma proxy for the detector: (R+G+B) scaled to ~8 bits.
    //   sum range 0..45  ->  sum * 5 ≈ 0..225  (fits in 8 bits, no clamp needed).
    wire [5:0] chan_sum = {2'b00, px_r} + {2'b00, px_g} + {2'b00, px_b};
    wire [7:0] gray8    = {chan_sum, 2'b00} + {2'b00, chan_sum};   // sum*5

    // 2x2 store -> 320x240 for BRAM
    wire keep_for_buffer  = (cam_col[0] == 1'b0) && (cam_row[0] == 1'b0);
    // 4x4 store -> 160x120 for Grayscale stream
    wire keep_for_stream  = (cam_col[1:0] == 2'b00) && (cam_row[1:0] == 2'b00);

    localparam integer MAX_ADDR = 320 * 240 - 1;     // 76799

    // -----------------------------------------------------------------
    // Main capture FSM
    // -----------------------------------------------------------------
    always @(posedge pclk or posedge reset) begin
        if (reset) begin
            frame_addr         <= 17'd0;
            frame_pixel        <= 12'h000;
            frame_we           <= 1'b0;
            stream_valid       <= 1'b0;
            stream_frame_start <= 1'b0;
            stream_line_start  <= 1'b0;
            stream_pixel       <= 8'd0;
            byte_phase         <= 1'b0;
            cam_col            <= 11'd0;
            cam_row            <= 10'd0;
            prev_vsync         <= 1'b0;
            prev_href          <= 1'b0;
            hi_byte            <= 8'd0;
        end else begin
            prev_vsync         <= vsync;
            prev_href          <= href;
            frame_we           <= 1'b0;
            stream_valid       <= 1'b0;
            stream_frame_start <= 1'b0;
            stream_line_start  <= 1'b0;

            // Address Increment
            if (frame_we && frame_addr < MAX_ADDR[16:0]) begin
                frame_addr <= frame_addr + 1'b1;
            end

            // Rising edge of VSYNC = reset for the next frame.
            if (!prev_vsync && vsync) begin
                frame_addr <= 17'd0;
                cam_col    <= 11'd0;
                cam_row    <= 10'd0;
                byte_phase <= 1'b0;
            end else if (href) begin
                // store pair of byte
                if (byte_phase == 1'b0) begin
                    hi_byte    <= data_in;
                    byte_phase <= 1'b1;
                end else begin
                    byte_phase <= 1'b0;

                    // data to write to BRAM
                    if (keep_for_buffer && frame_addr <= MAX_ADDR[16:0]) begin
                        frame_pixel <= {px_r, px_g, px_b};
                        frame_we    <= 1'b1;
                    end

                    // data for stream (NN face detection & Grayscale)
                    if (keep_for_stream) begin
                        stream_valid       <= 1'b1;
                        stream_pixel       <= gray8;
                        stream_frame_start <= (cam_col == 11'd0) && (cam_row == 10'd0);
                        stream_line_start  <= (cam_col == 11'd0);
                    end

                    cam_col <= cam_col + 11'd1;
                end
            end else begin
                // end line or blanking
                byte_phase <= 1'b0;
                if (prev_href && !href) begin
                    cam_col <= 11'd0;
                    cam_row <= cam_row + 10'd1;
                end
            end
        end
    end

    // sanity check (1280 pclk/line & 480 lines/frame)
    reg [11:0] pclks_this_line;
    reg [9:0]  lines_this_frame;
    reg        line_ok_sticky;
    reg        prev_href_d;
    reg        prev_vsync_d;

    always @(posedge pclk or posedge reset) begin
        if (reset) begin
            pclks_this_line  <= 12'd0;
            lines_this_frame <= 10'd0;
            line_ok_sticky   <= 1'b1;
            prev_href_d      <= 1'b0;
            prev_vsync_d     <= 1'b0;
            frame_format_ok  <= 1'b0;
            frame_heartbeat  <= 1'b0;
        end else begin
            prev_href_d  <= href;
            prev_vsync_d <= vsync;

            if (href) pclks_this_line <= pclks_this_line + 1'b1;

            if (prev_href_d && !href) begin
                if (pclks_this_line != 12'd1280) line_ok_sticky <= 1'b0;
                pclks_this_line  <= 12'd0;
                lines_this_frame <= lines_this_frame + 1'b1;
            end

            if (!prev_vsync_d && vsync) begin
                frame_format_ok  <= line_ok_sticky && (lines_this_frame == 10'd480);
                lines_this_frame <= 10'd0;
                line_ok_sticky   <= 1'b1;
                frame_heartbeat  <= ~frame_heartbeat;
            end
        end
    end

endmodule
