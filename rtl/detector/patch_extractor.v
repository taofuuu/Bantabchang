// patch_extractor: pull a 24x24 patch out of frame_buffer, convert
// uint8 pixel -> int8 (pixel - 128), and store it in the input act_buffer
// for conv1 to consume.
//
// This is the FPGA analog of IntegerFaceCNN's input shaping in
// scripts/quantize.py:
//   a0 = (x_uint8.to(int16) - 128).clamp(-128, 127).to(int8)
// Since we only feed in valid uint8 (0..255), the clamp is a no-op and the
// conversion reduces to flipping the high bit: int8 = uint8 ^ 0x80.
//
// Pipeline:
//   cycle T   : drive fb_r_addr for (ky=0, kx=0)
//   cycle T+1 : fb_r_data = pixel(0,0); drive r_addr for (0,1); write (0,0)?
//   ...
//   one extra "drain" cycle at the end to retire the last write.
//
// Total run length: 24*24 + 1 = 577 cycles for the read+write phases, plus a
// 1-cycle done pulse one cycle after the last write.
//
// Inputs:
//   patch_x / patch_y : top-left corner of the patch in 160x120 frame coords
//
// Address layout (matches scripts/dump_golden.py):
//   input act_buffer addr = ky * 24 + kx
//   frame_buffer addr     = (patch_y + ky) * 160 + (patch_x + kx)

`default_nettype none

module patch_extractor #(
    parameter FRAME_W = 160,
    parameter PATCH   = 24
) (
    input  wire        clk,
    input  wire        rst,           // synchronous, active high
    input  wire        start,         // 1-cycle pulse to begin
    input  wire [7:0]  patch_x,       // 0 .. (FRAME_W - PATCH)
    input  wire [6:0]  patch_y,       // 0 .. (FRAME_H - PATCH)
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

    // read counters (the (ky, kx) we are *issuing the read for* this cycle)
    reg [4:0] ky;       // 0..23 in 5 bits
    reg [4:0] kx;       // 0..23

    // delayed counters for the write that goes with last cycle's read
    reg [4:0] ky_d;
    reg [4:0] kx_d;
    reg       valid_d;  // we issued a read on the previous cycle

    // latched patch corner so the caller can deassert patch_x/patch_y after start
    reg [7:0] saved_px;
    reg [6:0] saved_py;

    wire kx_last   = (kx == PATCH - 1);
    wire ky_last   = (ky == PATCH - 1);
    wire walk_last = ky_last && kx_last;   // the cycle issuing the LAST read

    // -------------------------------------------------------------------
    // next-state
    // -------------------------------------------------------------------
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

    // -------------------------------------------------------------------
    // sequential
    // -------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            state    <= S_IDLE;
            ky       <= 0; kx <= 0;
            ky_d     <= 0; kx_d <= 0;
            valid_d  <= 1'b0;
            done     <= 1'b0;
            ab_we    <= 1'b0;
            saved_px <= 0;
            saved_py <= 0;
        end else begin
            state <= next;
            done  <= (next == S_FIN);
            ab_we <= 1'b0;       // default each cycle

            case (state)
                S_IDLE: begin
                    if (start) begin
                        saved_px <= patch_x;
                        saved_py <= patch_y;
                        ky       <= 0;
                        kx       <= 0;
                        valid_d  <= 1'b0;
                    end
                end

                S_WALK: begin
                    // We drove fb_r_addr for (ky, kx) this cycle. The data
                    // for the *previous* cycle's (ky_d, kx_d) is on fb_r_data,
                    // so we issue the write for that prior coordinate.
                    if (valid_d) begin
                        ab_we     <= 1'b1;
                        ab_w_addr <= ky_d * PATCH + kx_d;
                        // uint8 -> int8 by flipping the sign bit
                        ab_w_data <= fb_r_data ^ 8'h80;
                    end
                    // remember (ky, kx) so next cycle's write knows where it goes
                    ky_d    <= ky;
                    kx_d    <= kx;
                    valid_d <= 1'b1;

                    // advance read counters for the next cycle
                    if (kx_last) begin
                        kx <= 0;
                        if (!ky_last) ky <= ky + 1'b1;
                    end else begin
                        kx <= kx + 1'b1;
                    end
                end

                S_DRAIN: begin
                    // retire the very last read (no more reads to issue)
                    ab_we     <= 1'b1;
                    ab_w_addr <= ky_d * PATCH + kx_d;
                    ab_w_data <= fb_r_data ^ 8'h80;
                end

                default: ;
            endcase
        end
    end

    // -------------------------------------------------------------------
    // address driver — combinational, drives the frame_buffer read addr
    // for the read we are issuing this cycle.
    // -------------------------------------------------------------------
    always @* begin
        fb_r_addr = (saved_py + ky) * FRAME_W + (saved_px + kx);
    end

endmodule

`default_nettype wire
