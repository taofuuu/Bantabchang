// detector_top: full streaming face detector.
//
//   pixel stream (filter teammate)
//        │  pixel, pixel_valid, frame_start, line_start
//        ▼
//   ┌───────────────┐
//   │ frame_buffer  │  19200 B
//   └─────┬─────────┘
//         │ random read
//   ┌─────▼───────────┐
//   │ patch_extractor │  -> input act_buffer
//   └─────┬───────────┘
//         │
//   ┌─────▼────────────┐    ┌─────▼────────────┐    ┌─────▼────────────┐    ┌─────▼─────┐
//   │ conv1 + ROMs +ab │ -> │ conv2 + ROMs +ab │ -> │ conv3 + ROMs +ab │ -> │ fc + ROMs │
//   └──────────────────┘    └──────────────────┘    └──────────────────┘    └─────┬─────┘
//                                                                                 │
//                                                                  score = logit1 - logit0
//                                                                                 │
//                                            if score > best & score > THRESHOLD ─▶ latch best
//
// One sliding-window scan per frame. Stride is a parameter (default 16,
// 63 patches/frame, ~13 fps at 100 MHz with single-MAC convolution).
//
// Output register file is held stable across the next ingest+scan, so the
// downstream VGA overlay always sees a coherent (face_x, face_y, face_w,
// face_h, face_valid) until we replace it.

`default_nettype none

module detector_top #(
    parameter FRAME_W   = 160,
    parameter FRAME_H   = 120,
    parameter PATCH     = 24,
    parameter STRIDE    = 16,
    parameter signed [31:0] THRESHOLD = 32'sd1000,

    // Hex paths — passed in by the wrapper / synthesis script.
    parameter CONV1_W_FILE = "weights/conv1_w.hex",
    parameter CONV1_B_FILE = "weights/conv1_b.hex",
    parameter CONV2_W_FILE = "weights/conv2_w.hex",
    parameter CONV2_B_FILE = "weights/conv2_b.hex",
    parameter CONV3_W_FILE = "weights/conv3_w.hex",
    parameter CONV3_B_FILE = "weights/conv3_b.hex",
    parameter FC_W_FILE    = "weights/fc_w.hex",
    parameter FC_B_FILE    = "weights/fc_b.hex"
) (
    input  wire        clk,
    input  wire        rst,                  // sync, active high

    // streaming input
    input  wire        pixel_valid,
    input  wire        frame_start,
    input  wire        line_start,
    input  wire [7:0]  pixel,

    // output register file (held until next scan completes)
    output reg         face_valid,
    output reg  [7:0]  face_x,
    output reg  [6:0]  face_y,
    output reg  [7:0]  face_w,
    output reg  [6:0]  face_h,

    // diagnostic (used by testbench)
    output reg         scan_done             // 1-cycle pulse at end of scan
);

    // -------------------------------------------------------------------
    // 1.  Top-level FSM
    // -------------------------------------------------------------------
    localparam [3:0] S_WAIT      = 4'd0;     // idle, waiting for frame_start
    localparam [3:0] S_INGEST    = 4'd1;     // accepting pixel stream
    localparam [3:0] S_INIT_SCAN = 4'd2;
    localparam [3:0] S_PE_START  = 4'd3;     // 1-cycle pulse to patch_extractor
    localparam [3:0] S_PE_WAIT   = 4'd4;
    localparam [3:0] S_C1_START  = 4'd5;
    localparam [3:0] S_C1_WAIT   = 4'd6;
    localparam [3:0] S_C2_START  = 4'd7;
    localparam [3:0] S_C2_WAIT   = 4'd8;
    localparam [3:0] S_C3_START  = 4'd9;
    localparam [3:0] S_C3_WAIT   = 4'd10;
    localparam [3:0] S_FC_START  = 4'd11;
    localparam [3:0] S_FC_WAIT   = 4'd12;
    localparam [3:0] S_SCORE     = 4'd13;
    localparam [3:0] S_LATCH     = 4'd14;

    reg [3:0] state, next;

    // Scan-position counters.
    reg [7:0] scan_x;
    reg [6:0] scan_y;

    // Best detection so far (this scan).
    reg [7:0]         best_x;
    reg [6:0]         best_y;
    reg signed [31:0] best_score;
    reg               best_valid;

    // -------------------------------------------------------------------
    // 2.  Sub-module wires
    // -------------------------------------------------------------------
    // frame_buffer
    wire             fb_frame_done;
    wire [14:0]      fb_r_addr;
    wire [7:0]       fb_r_data;

    // patch_extractor
    reg              pe_start;
    wire             pe_done;
    wire [14:0]      pe_fb_addr;
    wire             pe_ab_we;
    wire [9:0]       pe_ab_w_addr;
    wire signed [7:0] pe_ab_w_data;

    // input act_buffer (576 entries) - read by conv1
    wire [9:0]       inab_r_addr;
    wire signed [7:0] inab_r_data;

    // conv1 ROMs
    wire [6:0]       c1_w_addr;
    wire signed [7:0] c1_w_data;
    wire [2:0]       c1_b_addr;
    wire signed [31:0] c1_b_data;

    // conv1
    reg              c1_start;
    wire             c1_done;
    wire             c1_out_we;
    wire [9:0]       c1_out_w_addr;
    wire signed [7:0] c1_out_w_data;

    // conv1_out act_buffer (968 entries) - read by conv2
    wire [9:0]       c1ab_r_addr;
    wire signed [7:0] c1ab_r_data;

    // conv2 ROMs
    wire [10:0]      c2_w_addr;       // 16*8*9 = 1152 -> 11 bits
    wire signed [7:0] c2_w_data;
    wire [3:0]       c2_b_addr;
    wire signed [31:0] c2_b_data;

    // conv2
    reg              c2_start;
    wire             c2_done;
    wire             c2_out_we;
    wire [8:0]       c2_out_w_addr;   // 16*5*5 = 400 -> 9 bits
    wire signed [7:0] c2_out_w_data;

    // conv2_out act_buffer (400 entries) - read by conv3
    wire [8:0]       c2ab_r_addr;
    wire signed [7:0] c2ab_r_data;

    // conv3 ROMs
    wire [11:0]      c3_w_addr;       // 16*16*9 = 2304 -> 12 bits
    wire signed [7:0] c3_w_data;
    wire [3:0]       c3_b_addr;
    wire signed [31:0] c3_b_data;

    // conv3
    reg              c3_start;
    wire             c3_done;
    wire             c3_out_we;
    wire [7:0]       c3_out_w_addr;   // 16*3*3 = 144 -> 8 bits
    wire signed [7:0] c3_out_w_data;

    // conv3_out act_buffer (144 entries) - read by fc
    wire [7:0]       c3ab_r_addr;
    wire signed [7:0] c3ab_r_data;

    // fc_layer ROMs
    wire [8:0]       fc_w_addr;       // 2*144 = 288 -> 9 bits
    wire signed [7:0] fc_w_data;
    wire             fc_b_addr;
    wire signed [31:0] fc_b_data;

    // fc_layer
    reg              fc_start;
    wire             fc_done;
    wire signed [31:0] fc_logit0;
    wire signed [31:0] fc_logit1;

    // -------------------------------------------------------------------
    // 3.  Sub-module instances
    // -------------------------------------------------------------------
    frame_buffer u_fb (
        .clk(clk), .rst(rst),
        .pixel_valid(pixel_valid), .frame_start(frame_start), .line_start(line_start),
        .pixel(pixel), .frame_done(fb_frame_done),
        .r_addr(fb_r_addr), .r_data(fb_r_data)
    );

    patch_extractor #(.FRAME_W(FRAME_W), .PATCH(PATCH)) u_pe (
        .clk(clk), .rst(rst),
        .start(pe_start), .patch_x(scan_x), .patch_y(scan_y), .done(pe_done),
        .fb_r_addr(fb_r_addr), .fb_r_data(fb_r_data),
        .ab_we(pe_ab_we), .ab_w_addr(pe_ab_w_addr), .ab_w_data(pe_ab_w_data)
    );

    // input act_buffer: written by patch_extractor, read by conv1
    act_buffer #(.WIDTH(8), .DEPTH(576), .ADDR_W(10)) u_inab (
        .clk(clk),
        .we(pe_ab_we), .w_addr(pe_ab_w_addr), .w_data(pe_ab_w_data),
        .r_addr(inab_r_addr), .r_data(inab_r_data)
    );

    // conv1 weight + bias ROMs
    weight_rom #(.WIDTH(8),  .DEPTH(72), .ADDR_W(7), .MEM_FILE(CONV1_W_FILE))
        u_c1_w (.clk(clk), .addr(c1_w_addr), .data(c1_w_data));
    weight_rom #(.WIDTH(32), .DEPTH(8),  .ADDR_W(3), .MEM_FILE(CONV1_B_FILE))
        u_c1_b (.clk(clk), .addr(c1_b_addr), .data(c1_b_data));

    conv_layer #(.IN_CH(1), .OUT_CH(8), .IN_H(24), .IN_W(24),
                 .K(3), .STRIDE(2), .REQUANT_SHIFT(10)) u_c1 (
        .clk(clk), .rst(rst), .start(c1_start), .done(c1_done),
        .in_addr(inab_r_addr), .in_data(inab_r_data),
        .w_addr(c1_w_addr),    .w_data(c1_w_data),
        .b_addr(c1_b_addr),    .b_data(c1_b_data),
        .out_we(c1_out_we), .out_addr(c1_out_w_addr), .out_data(c1_out_w_data)
    );

    // conv1_out act_buffer: written by conv1, read by conv2
    act_buffer #(.WIDTH(8), .DEPTH(968), .ADDR_W(10)) u_c1ab (
        .clk(clk),
        .we(c1_out_we), .w_addr(c1_out_w_addr), .w_data(c1_out_w_data),
        .r_addr(c1ab_r_addr), .r_data(c1ab_r_data)
    );

    // conv2 ROMs
    weight_rom #(.WIDTH(8),  .DEPTH(1152), .ADDR_W(11), .MEM_FILE(CONV2_W_FILE))
        u_c2_w (.clk(clk), .addr(c2_w_addr), .data(c2_w_data));
    weight_rom #(.WIDTH(32), .DEPTH(16),   .ADDR_W(4),  .MEM_FILE(CONV2_B_FILE))
        u_c2_b (.clk(clk), .addr(c2_b_addr), .data(c2_b_data));

    conv_layer #(.IN_CH(8), .OUT_CH(16), .IN_H(11), .IN_W(11),
                 .K(3), .STRIDE(2), .REQUANT_SHIFT(8)) u_c2 (
        .clk(clk), .rst(rst), .start(c2_start), .done(c2_done),
        .in_addr(c1ab_r_addr), .in_data(c1ab_r_data),
        .w_addr(c2_w_addr),    .w_data(c2_w_data),
        .b_addr(c2_b_addr),    .b_data(c2_b_data),
        .out_we(c2_out_we), .out_addr(c2_out_w_addr), .out_data(c2_out_w_data)
    );

    // conv2_out act_buffer
    act_buffer #(.WIDTH(8), .DEPTH(400), .ADDR_W(9)) u_c2ab (
        .clk(clk),
        .we(c2_out_we), .w_addr(c2_out_w_addr), .w_data(c2_out_w_data),
        .r_addr(c2ab_r_addr), .r_data(c2ab_r_data)
    );

    // conv3 ROMs
    weight_rom #(.WIDTH(8),  .DEPTH(2304), .ADDR_W(12), .MEM_FILE(CONV3_W_FILE))
        u_c3_w (.clk(clk), .addr(c3_w_addr), .data(c3_w_data));
    weight_rom #(.WIDTH(32), .DEPTH(16),   .ADDR_W(4),  .MEM_FILE(CONV3_B_FILE))
        u_c3_b (.clk(clk), .addr(c3_b_addr), .data(c3_b_data));

    conv_layer #(.IN_CH(16), .OUT_CH(16), .IN_H(5), .IN_W(5),
                 .K(3), .STRIDE(1), .REQUANT_SHIFT(10)) u_c3 (
        .clk(clk), .rst(rst), .start(c3_start), .done(c3_done),
        .in_addr(c2ab_r_addr), .in_data(c2ab_r_data),
        .w_addr(c3_w_addr),    .w_data(c3_w_data),
        .b_addr(c3_b_addr),    .b_data(c3_b_data),
        .out_we(c3_out_we), .out_addr(c3_out_w_addr), .out_data(c3_out_w_data)
    );

    // conv3_out act_buffer
    act_buffer #(.WIDTH(8), .DEPTH(144), .ADDR_W(8)) u_c3ab (
        .clk(clk),
        .we(c3_out_we), .w_addr(c3_out_w_addr), .w_data(c3_out_w_data),
        .r_addr(c3ab_r_addr), .r_data(c3ab_r_data)
    );

    // fc ROMs
    weight_rom #(.WIDTH(8),  .DEPTH(288), .ADDR_W(9), .MEM_FILE(FC_W_FILE))
        u_fc_w (.clk(clk), .addr(fc_w_addr), .data(fc_w_data));
    weight_rom #(.WIDTH(32), .DEPTH(2),   .ADDR_W(1), .MEM_FILE(FC_B_FILE))
        u_fc_b (.clk(clk), .addr({fc_b_addr}), .data(fc_b_data));

    fc_layer #(.IN_LEN(144), .OUT_LEN(2)) u_fc (
        .clk(clk), .rst(rst), .start(fc_start), .done(fc_done),
        .in_addr(c3ab_r_addr), .in_data(c3ab_r_data),
        .w_addr(fc_w_addr),    .w_data(fc_w_data),
        .b_addr(fc_b_addr),    .b_data(fc_b_data),
        .logit0(fc_logit0), .logit1(fc_logit1)
    );

    // -------------------------------------------------------------------
    // 4.  FSM next-state
    // -------------------------------------------------------------------
    wire signed [31:0] score = fc_logit1 - fc_logit0;

    // True when current scan_x is the rightmost position we visit.
    wire scan_x_last = (scan_x + STRIDE > FRAME_W - PATCH);
    wire scan_y_last = (scan_y + STRIDE > FRAME_H - PATCH);

    always @* begin
        next = state;
        case (state)
            S_WAIT:      if (frame_start && pixel_valid) next = S_INGEST;
            S_INGEST:    if (fb_frame_done) next = S_INIT_SCAN;
            S_INIT_SCAN: next = S_PE_START;
            S_PE_START:  next = S_PE_WAIT;
            S_PE_WAIT:   if (pe_done) next = S_C1_START;
            S_C1_START:  next = S_C1_WAIT;
            S_C1_WAIT:   if (c1_done) next = S_C2_START;
            S_C2_START:  next = S_C2_WAIT;
            S_C2_WAIT:   if (c2_done) next = S_C3_START;
            S_C3_START:  next = S_C3_WAIT;
            S_C3_WAIT:   if (c3_done) next = S_FC_START;
            S_FC_START:  next = S_FC_WAIT;
            S_FC_WAIT:   if (fc_done) next = S_SCORE;
            S_SCORE: begin
                if (scan_x_last && scan_y_last) next = S_LATCH;
                else                            next = S_PE_START;
            end
            S_LATCH:     next = S_WAIT;
            default:     next = S_WAIT;
        endcase
    end

    // -------------------------------------------------------------------
    // 5.  Sequential logic
    // -------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            state      <= S_WAIT;
            scan_x     <= 0;
            scan_y     <= 0;
            best_x     <= 0;
            best_y     <= 0;
            best_score <= 32'sd0;
            best_valid <= 1'b0;
            face_valid <= 1'b0;
            face_x     <= 0;
            face_y     <= 0;
            face_w     <= PATCH[7:0];
            face_h     <= PATCH[6:0];
            scan_done  <= 1'b0;
            pe_start   <= 1'b0;
            c1_start   <= 1'b0;
            c2_start   <= 1'b0;
            c3_start   <= 1'b0;
            fc_start   <= 1'b0;
        end else begin
            state     <= next;
            scan_done <= 1'b0;
            pe_start  <= 1'b0;
            c1_start  <= 1'b0;
            c2_start  <= 1'b0;
            c3_start  <= 1'b0;
            fc_start  <= 1'b0;

            case (state)
                S_INIT_SCAN: begin
                    scan_x     <= 0;
                    scan_y     <= 0;
                    best_x     <= 0;
                    best_y     <= 0;
                    best_score <= THRESHOLD;       // anything <= threshold gets ignored
                    best_valid <= 1'b0;
                end

                S_PE_START: pe_start <= 1'b1;
                S_C1_START: c1_start <= 1'b1;
                S_C2_START: c2_start <= 1'b1;
                S_C3_START: c3_start <= 1'b1;
                S_FC_START: fc_start <= 1'b1;

                S_SCORE: begin
                    if (score > best_score) begin
                        best_score <= score;
                        best_x     <= scan_x;
                        best_y     <= scan_y;
                        best_valid <= 1'b1;
                    end
                    // advance scan position
                    if (scan_x_last) begin
                        scan_x <= 0;
                        if (!scan_y_last) scan_y <= scan_y + STRIDE[6:0];
                    end else begin
                        scan_x <= scan_x + STRIDE[7:0];
                    end
                end

                S_LATCH: begin
                    face_valid <= best_valid;
                    face_x     <= best_x;
                    face_y     <= best_y;
                    face_w     <= PATCH[7:0];
                    face_h     <= PATCH[6:0];
                    scan_done  <= 1'b1;
                end

                default: ;
            endcase
        end
    end

endmodule

`default_nettype wire
