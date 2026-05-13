// pull a 24x24 patch from frame_buffer, convert uint8 → int8 (^0x80), write to input act_buffer
// DILATE stretches the patch to cover
// PATCH*DILATE pixels in the real frame (e.g. DILATE=3 → 72x72 region)

`default_nettype none

module patch_extractor #(
    parameter FRAME_W = 160,
    parameter PATCH   = 24
) (
    input  wire        clk,
    input  wire        rst,           // synchronous, active high
    input  wire        start,         // 1-cycle pulse to begin
    input  wire [7:0]  patch_x,       // 0 .. (FRAME_W - PATCH*dilate_in)
    input  wire [6:0]  patch_y,       // 0 .. (FRAME_H - PATCH*dilate_in)
    input  wire [2:0]  dilate_in,     // 1..7; runtime sub-sample stride
    output reg         done,          // 1-cycle pulse when finished

    // frame_buffer read port (1-cycle latency)
    output reg  [14:0] fb_r_addr,
    input  wire [7:0]  fb_r_data,

    // act_buffer write port
    output reg         ab_we,
    output reg  [9:0]  ab_w_addr,
    output reg  signed [7:0] ab_w_data
);

    // FSM
    localparam [1:0] S_IDLE  = 2'd0;
    localparam [1:0] S_WALK  = 2'd1;
    localparam [1:0] S_DRAIN = 2'd2;
    localparam [1:0] S_FIN   = 2'd3;

    reg [1:0] state, next;

    // read counters — address being issued this cycle
    reg [4:0] ky;       // 0..23 in 5 bits
    reg [4:0] kx;       // 0..23

    // delayed by one cycle for write-back
    reg [4:0] ky_d;
    reg [4:0] kx_d;
    reg       valid_d;  // we issued a read on the previous cycle

    // latch inputs so caller can deassert after start
    reg [7:0] saved_px;
    reg [6:0] saved_py;
    reg [2:0] saved_dilate;

    wire kx_last   = (kx == PATCH - 1);
    wire ky_last   = (ky == PATCH - 1);
    wire walk_last = ky_last && kx_last;   // last read cycle

    // next-state
    always @* begin
        next = state;
        case (state)
            S_IDLE:  if (start)     next = S_WALK;
            S_WALK:  if (walk_last) next = S_DRAIN;
            S_DRAIN:                next = S_FIN;
            S_FIN:                  next = S_IDLE;
            default:                next = S_IDLE;
        endcase
    end

    // sequential
    always @(posedge clk) begin
        if (rst) begin
            state        <= S_IDLE;
            ky           <= 0; kx <= 0;
            ky_d         <= 0; kx_d <= 0;
            valid_d      <= 1'b0;
            done         <= 1'b0;
            ab_we        <= 1'b0;
            saved_px     <= 0;
            saved_py     <= 0;
            saved_dilate <= 3'd1;
        end else begin
            state <= next;
            done  <= (next == S_FIN);
            ab_we <= 1'b0;       // default each cycle

            case (state)
                S_IDLE: begin
                    if (start) begin
                        saved_px     <= patch_x;
                        saved_py     <= patch_y;
                        saved_dilate <= (dilate_in == 3'd0) ? 3'd1 : dilate_in;
                        ky           <= 0;
                        kx           <= 0;
                        valid_d      <= 1'b0;
                    end
                end

                S_WALK: begin
                    // data from last cycle's read is ready; write it now
                    if (valid_d) begin
                        ab_we     <= 1'b1;
                        ab_w_addr <= ky_d * PATCH + kx_d;
                        // uint8 → int8 by flipping sign bit
                        ab_w_data <= fb_r_data ^ 8'h80;
                    end
                    // save for next cycle's write
                    ky_d    <= ky;
                    kx_d    <= kx;
                    valid_d <= 1'b1;

                    // advance read counters
                    if (kx_last) begin
                        kx <= 0;
                        if (!ky_last) ky <= ky + 1'b1;
                    end else begin
                        kx <= kx + 1'b1;
                    end
                end

                S_DRAIN: begin
                    // drain the last read
                    ab_we     <= 1'b1;
                    ab_w_addr <= ky_d * PATCH + kx_d;
                    ab_w_data <= fb_r_data ^ 8'h80;
                end

                default: ;
            endcase
        end
    end

    // address driver — combinational
    always @* begin
        fb_r_addr = (saved_py + ky*saved_dilate) * FRAME_W
                  + (saved_px + kx*saved_dilate);
    end

endmodule

`default_nettype wire
