`timescale 1ns / 1ps
`include "scales.vh"
//////////////////////////////////////////////////////////////////////////////////
// Top Module: OV7670 + NN Face Detector + VGA Display
//
// Pipeline:
//   OV7670 ── ov7670_capture ──┬──► RGB444 frame buffer ──► VGA preview
//                              │                                  │
//                              │     (ov7670_capture also emits   │
//                              │      a 160x120 8-bit grayscale   │
//                              │      stream tapped from the same │
//                              │      RGB565 byte pair)           │
//                              ▼                                  │
//                        pixel_stream_cdc                         │
//                       (pclk → system clk)                       │
//                              │                                  │
//                              ▼                                  │
//                         detector_top ─────► face_x / face_y / face_w / face_h
//                              │                                  │
//                              └──── bounding-box overlay ────────┘
//                                            │
//                                            ▼
//                                        VGA output
//
// All RTL clocked from a single 100 MHz input. The clock wizard derives a
// 25 MHz pixel clock for VGA timing and a 24 MHz master clock for the camera.
//////////////////////////////////////////////////////////////////////////////////

module camera_vga_top(
    input  wire        clk,            // 100 MHz from Basys 3
    input  wire        reset,          // BTNC, async active-high

    // OV7670 interface
    input  wire [7:0]  camera_data,
    input  wire        camera_href,
    input  wire        camera_vsync,
    input  wire        camera_pclk,
    output wire        camera_xclk,
    output wire        camera_pwdn,
    output wire        camera_reset,
    inout  wire        camera_siod,
    output wire        camera_sioc,

    // VGA
    output wire        vga_hsync,
    output wire        vga_vsync,
    output wire [3:0]  vga_red,
    output wire [3:0]  vga_green,
    output wire [3:0]  vga_blue,

    // Operator switches / LEDs
    input  wire [2:0]  filter_sel,
    output wire [7:0]  led
);

    //=======================================================================
    // Clocks
    //=======================================================================
    wire clk_25mhz;
    wire clk_24mhz;
    wire clk_locked;

    clk_wiz_0 clk_gen (
        .clk_in1(clk),
        .clk_out1(clk_25mhz),
        .clk_out2(clk_24mhz),
        .reset(reset),
        .locked(clk_locked)
    );

    //=======================================================================
    // Reset synchronizers (async-assert, sync-deassert)
    //=======================================================================
    reg [1:0] rst_clk_sync;
    always @(posedge clk or posedge reset) begin
        if (reset) rst_clk_sync <= 2'b11;
        else       rst_clk_sync <= {rst_clk_sync[0], 1'b0};
    end
    wire rst_clk     = rst_clk_sync[1] | ~clk_locked;

    reg [1:0] rst_25_sync;
    always @(posedge clk_25mhz or posedge reset) begin
        if (reset) rst_25_sync <= 2'b11;
        else       rst_25_sync <= {rst_25_sync[0], 1'b0};
    end
    wire rst_25 = rst_25_sync[1];

    //=======================================================================
    // Camera fixed strapping
    //=======================================================================
    assign camera_pwdn  = 1'b0;       // camera not in power-down
    assign camera_reset = 1'b1;       // camera reset deasserted (active low)
    assign camera_xclk  = clk_24mhz;

    //=======================================================================
    // SCCB configuration
    //=======================================================================
    wire config_done;
    wire sccb_busy;
    wire sccb_nak_seen;

    ov7670_config camera_config (
        .clk(clk),
        .reset(reset || !clk_locked),
        .sioc(camera_sioc),
        .siod(camera_siod),
        .config_done(config_done),
        .sccb_busy(sccb_busy),
        .sccb_nak_seen(sccb_nak_seen)
    );

    //=======================================================================
    // Camera capture (RGB444 → frame buffer + 160x120 grayscale stream)
    //=======================================================================
    wire [16:0] write_addr;
    wire [11:0] write_data;
    wire        write_enable;

    // Camera-domain (pclk) grayscale stream
    wire        cam_stream_valid;
    wire        cam_stream_frame_start;
    wire        cam_stream_line_start;
    wire [7:0]  cam_stream_pixel;

    // Capture diagnostics (pclk domain; see CDC below)
    wire        cap_frame_format_ok;
    wire        cap_frame_heartbeat;

    ov7670_capture camera_capture (
        .pclk(camera_pclk),
        .vsync(camera_vsync),
        .href(camera_href),
        .data_in(camera_data),
        .reset(reset || !config_done),

        .frame_addr(write_addr),
        .frame_pixel(write_data),
        .frame_we(write_enable),

        .stream_valid(cam_stream_valid),
        .stream_frame_start(cam_stream_frame_start),
        .stream_line_start(cam_stream_line_start),
        .stream_pixel(cam_stream_pixel),

        .frame_format_ok(cap_frame_format_ok),
        .frame_heartbeat(cap_frame_heartbeat)
    );

    //=======================================================================
    // CDC: pclk-domain diagnostic flags -> clk domain (for LEDs)
    //=======================================================================
    (* ASYNC_REG = "TRUE" *) reg cap_fok_meta;
    (* ASYNC_REG = "TRUE" *) reg cap_fok_sync;
    (* ASYNC_REG = "TRUE" *) reg cap_fhb_meta;
    (* ASYNC_REG = "TRUE" *) reg cap_fhb_sync;
    always @(posedge clk) begin
        cap_fok_meta <= cap_frame_format_ok;
        cap_fok_sync <= cap_fok_meta;
        cap_fhb_meta <= cap_frame_heartbeat;
        cap_fhb_sync <= cap_fhb_meta;
    end

    //=======================================================================
    // VGA timing
    //=======================================================================
    wire        vga_active;
    wire [9:0]  vga_x;
    wire [9:0]  vga_y;

    vga_controller vga_ctrl (
        .clk(clk_25mhz),
        .reset(rst_25),
        .hsync(vga_hsync),
        .vsync(vga_vsync),
        .active(vga_active),
        .x_pos(vga_x),
        .y_pos(vga_y)
    );

    //=======================================================================
    // VGA read address (×2 pixel doubling: 320x240 → 640x480)
    //
    // active/x_pos/y_pos out of vga_controller are combinational; the BRAM
    // read port has 1 cycle of latency. We register the timing signals once
    // to keep them aligned with the pixel data that arrives at the filter.
    // Without this the very first column of every line shows the previous
    // line's out-of-range read (which lands as black) -> a thin vertical
    // strip on the left edge.
    //=======================================================================
    wire [16:0] read_addr;
    wire [11:0] read_data;
    wire [16:0] row_offset = (vga_y[9:1] << 8) + (vga_y[9:1] << 6); // y/2 * 320
    assign read_addr = row_offset + vga_x[9:1];

    reg        vga_active_d;
    reg [9:0]  vga_x_d;
    reg [9:0]  vga_y_d;
    always @(posedge clk_25mhz) begin
        if (rst_25) begin
            vga_active_d <= 1'b0;
            vga_x_d      <= 10'd0;
            vga_y_d      <= 10'd0;
        end else begin
            vga_active_d <= vga_active;
            vga_x_d      <= vga_x;
            vga_y_d      <= vga_y;
        end
    end

    //=======================================================================
    // RGB444 frame buffer (camera ↔ VGA)
    //=======================================================================
    filter_frame_buffer fb (
        .clka(camera_pclk),
        .wea(write_enable),
        .addra(write_addr),
        .dina(write_data),

        .clkb(clk_25mhz),
        .addrb(read_addr),
        .doutb(read_data)
    );

    //=======================================================================
    // Display filter (operator-selectable visualisation, RGB444 in/out)
    //=======================================================================
    wire [11:0] filtered_pixel;

    image_filter filter (
        .pixel_in(read_data),
        .filter_sel(filter_sel),
        .pixel_out(filtered_pixel)
    );

    //=======================================================================
    // pclk → clk CDC for the detector pixel stream
    //=======================================================================
    wire        det_in_valid;
    wire        det_in_frame_start;
    wire        det_in_line_start;
    wire [7:0]  det_in_pixel;

    pixel_stream_cdc u_cdc (
        .src_clk(camera_pclk),
        .src_rst(reset || !config_done),
        .src_valid(cam_stream_valid),
        .src_frame_start(cam_stream_frame_start),
        .src_line_start(cam_stream_line_start),
        .src_pixel(cam_stream_pixel),

        .dst_clk(clk_25mhz),
        .dst_rst(rst_25),
        .dst_valid(det_in_valid),
        .dst_frame_start(det_in_frame_start),
        .dst_line_start(det_in_line_start),
        .dst_pixel(det_in_pixel)
    );

    //=======================================================================
    // NN face detector
    //=======================================================================
    wire        det_face_valid;
    wire [7:0]  det_face_x;
    wire [6:0]  det_face_y;
    wire [7:0]  det_face_w;
    wire [6:0]  det_face_h;
    wire        det_scan_done;

    // Use basenames so $readmemh resolves through Vivado's project sources
    // (build.tcl adds rtl/../weights/*.hex as Memory Initialization Files).
    detector_top #(
        // Confidence threshold on the raw int32 conf logit. From the golden
        // test set, true positives land in [1103, 4772] and true negatives in
        // [-4519, -386], so there's a wide pos/neg gap. 500 puts us safely
        // above every test negative while still accepting every test positive
        // — important because real-camera frames produce lower logits than
        // the cleaner LFW training images. Increase if false detections appear.
        .THRESHOLD(32'sd500),
        // Sub-sample stride within each 24x24 patch. DILATE=3 means each
        // patch covers a 72x72 region of the 160x120 frame, matching the
        // scale the network is trained on.
        .DILATE(3'd3),
        // Driven from weights/scales.vh (auto-generated by export_weights.py).
        .BBOX_SHIFT(`FC_OUT_SHIFT),
        .CONV1_W_FILE("conv1_w.hex"),
        .CONV1_B_FILE("conv1_b.hex"),
        .CONV2_W_FILE("conv2_w.hex"),
        .CONV2_B_FILE("conv2_b.hex"),
        .CONV3_W_FILE("conv3_w.hex"),
        .CONV3_B_FILE("conv3_b.hex"),
        .FC_W_FILE("fc_w.hex"),
        .FC_B_FILE("fc_b.hex")
    ) u_detector (
        .clk(clk_25mhz),
        .rst(rst_25),

        .pixel_valid(det_in_valid),
        .frame_start(det_in_frame_start),
        .line_start(det_in_line_start),
        .pixel(det_in_pixel),

        .face_valid(det_face_valid),
        .face_x(det_face_x),
        .face_y(det_face_y),
        .face_w(det_face_w),
        .face_h(det_face_h),
        .scan_done(det_scan_done)
    );

    //=======================================================================
    // CDC of face_* register file from clk → clk_25mhz (overlay)
    //
    //   - On the clk side, every scan_done pulse flips a toggle bit.
    //   - On the 25 MHz side, the toggle is 2-FF synchronized and edge-detected;
    //     on each edge we latch the (now-stable) face_* values.
    //
    // The face_* signals only update once per scan (~13 ms apart) so they are
    // stable for thousands of clk_25mhz cycles when we sample them.
    //=======================================================================
    reg det_update_toggle;
    always @(posedge clk_25mhz) begin
        if (rst_25)               det_update_toggle <= 1'b0;
        else if (det_scan_done)   det_update_toggle <= ~det_update_toggle;
    end

    (* ASYNC_REG = "TRUE" *) reg upd_meta;
    (* ASYNC_REG = "TRUE" *) reg upd_sync;
    reg                      upd_prev;

    reg        vga_face_valid;
    reg [7:0]  vga_face_x;
    reg [6:0]  vga_face_y;
    reg [7:0]  vga_face_w;
    reg [6:0]  vga_face_h;

    // Hold the last positive detection across a few empty scans. The CNN is
    // not 100% recall on every frame; without persistence the box blinks off
    // for every missed scan even while the face is clearly there. At ~8 scans
    // per second a hold of 8 keeps the box visible for ~1 s after the last
    // confirmed detection — long enough to ride out a few weak frames, short
    // enough that a real disappearance is still obvious.
    localparam [3:0] FACE_HOLD_FRAMES = 4'd8;
    reg [3:0] face_hold_cnt;

    always @(posedge clk_25mhz) begin
        if (rst_25) begin
            upd_meta       <= 1'b0;
            upd_sync       <= 1'b0;
            upd_prev       <= 1'b0;
            vga_face_valid <= 1'b0;
            vga_face_x     <= 8'd0;
            vga_face_y     <= 7'd0;
            vga_face_w     <= 8'd24;
            vga_face_h     <= 7'd24;
            face_hold_cnt  <= 4'd0;
        end else begin
            upd_meta <= det_update_toggle;
            upd_sync <= upd_meta;
            upd_prev <= upd_sync;
            if (upd_sync ^ upd_prev) begin
                if (det_face_valid) begin
                    vga_face_valid <= 1'b1;
                    vga_face_x     <= det_face_x;
                    vga_face_y     <= det_face_y;
                    vga_face_w     <= det_face_w;
                    vga_face_h     <= det_face_h;
                    face_hold_cnt  <= FACE_HOLD_FRAMES;
                end else if (face_hold_cnt != 4'd0) begin
                    // No face this scan, but we are still inside the hold
                    // window - keep the previous box on screen.
                    face_hold_cnt  <= face_hold_cnt - 1'b1;
                end else begin
                    vga_face_valid <= 1'b0;
                end
            end
        end
    end

    //=======================================================================
    // Bounding-box overlay (160x120 → ×4 → 640x480)
    //
    // 2-pixel-thick green rectangle when face_valid is high.
    //=======================================================================
    wire [9:0] box_x0 = {vga_face_x, 2'b00};            // 8b * 4 → 10b
    wire [9:0] box_y0 = {1'b0, vga_face_y, 2'b00};      // 7b * 4 → 9b, pad to 10b
    wire [9:0] box_x1 = box_x0 + {vga_face_w, 2'b00} - 10'd1;
    wire [9:0] box_y1 = box_y0 + {1'b0, vga_face_h, 2'b00} - 10'd1;

    // Use the registered timing signals so the overlay aligns with the
    // pixel data that arrives one cycle after read_addr is presented.
    wire in_box_x = (vga_x_d >= box_x0) && (vga_x_d <= box_x1);
    wire in_box_y = (vga_y_d >= box_y0) && (vga_y_d <= box_y1);

    wire on_top    = in_box_x && (vga_y_d >= box_y0) && (vga_y_d <= box_y0 + 10'd1);
    wire on_bottom = in_box_x && (vga_y_d >= box_y1 - 10'd1) && (vga_y_d <= box_y1);
    wire on_left   = in_box_y && (vga_x_d >= box_x0) && (vga_x_d <= box_x0 + 10'd1);
    wire on_right  = in_box_y && (vga_x_d >= box_x1 - 10'd1) && (vga_x_d <= box_x1);

    wire on_box = vga_face_valid && (on_top | on_bottom | on_left | on_right);

    //=======================================================================
    // VGA pixel output - gated by the registered active signal so the
    // BRAM data, the overlay, and the blanking interval all line up.
    //=======================================================================
    assign vga_red   = vga_active_d ? (on_box ? 4'hF : filtered_pixel[11:8]) : 4'h0;
    assign vga_green = vga_active_d ? (on_box ? 4'h0 : filtered_pixel[7:4])  : 4'h0;
    assign vga_blue  = vga_active_d ? (on_box ? 4'h0 : filtered_pixel[3:0])  : 4'h0;

    //=======================================================================
    // Debug LEDs
    //
    // After boot, with everything healthy:
    //   LD0 on, LD1 blinking with vsync, LD2 blinking with scans,
    //   LD3 on while a face is latched, LD4 off (idle SCCB),
    //   LD5 off (no NAKs after retries), LD6 on (frame format OK),
    //   LD7 toggling every frame (heartbeat).
    //
    // Trouble:
    //   LD5 on -> SCCB still failing -> camera in undefined state
    //   LD6 off -> capture is not seeing the expected 640x240 byte/line layout
    //   LD7 not toggling -> no frames are coming out of the camera
    //=======================================================================
    assign led[0] = config_done;
    assign led[1] = camera_vsync;
    assign led[2] = det_scan_done;       // blinks once per scan
    assign led[3] = det_face_valid;      // lit when a face is currently latched
    assign led[4] = sccb_busy;           // SCCB transaction in progress
    assign led[5] = sccb_nak_seen;       // latched: any register failed after retries
    assign led[6] = cap_fok_sync;        // last frame had 640 bytes/line and 240 lines
    assign led[7] = cap_fhb_sync;        // toggles every frame (capture heartbeat)

endmodule
