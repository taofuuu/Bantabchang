// conv_layer: generic 2D convolution + bias + ReLU + requantize.
//
// One MAC per cycle (sequential). Bit-exact equivalent of:
//
//   for oc:                              # output channel
//     for oy:                            # output spatial y
//       for ox:                          # output spatial x
//         acc = bias[oc]                 # int32
//         for ic, ky, kx:                # accumulate
//           acc += w[oc,ic,ky,kx] * in[ic, oy*S+ky, ox*S+kx]
//         out[oc,oy,ox] = clip(round(max(0,acc) >> SHIFT), 0, 127)
//
// Address layout (matching scripts/export_weights.py and dump_golden.py):
//   input  : [ic, iy, ix]      addr = ic*IH*IW + iy*IW + ix
//   weight : [oc, ic, ky, kx]  addr = oc*IN_CH*KH*KW + ic*KH*KW + ky*KW + kx
//   bias   : [oc]
//   output : [oc, oy, ox]      addr = oc*OH*OW + oy*OW + ox
//
// Memory ports are fully synchronous (1-cycle read latency assumed).

`default_nettype none

module conv_layer #(
    parameter IN_CH         = 1,
    parameter OUT_CH        = 8,
    parameter IN_H          = 24,
    parameter IN_W          = 24,
    parameter K             = 3,
    parameter STRIDE        = 2,
    parameter OUT_H         = (IN_H - K) / STRIDE + 1,
    parameter OUT_W         = (IN_W - K) / STRIDE + 1,
    parameter REQUANT_SHIFT = 8
) (
    input  wire        clk,
    input  wire        rst,           // synchronous, active high
    input  wire        start,         // 1-cycle pulse to begin
    output reg         done,          // high for 1 cycle when finished

    // input activation memory (read port, 1-cycle latency)
    output reg  [$clog2(IN_CH*IN_H*IN_W)-1:0] in_addr,
    input  wire signed [7:0]                  in_data,

    // weight ROM (read port, 1-cycle latency)
    output reg  [$clog2(OUT_CH*IN_CH*K*K)-1:0] w_addr,
    input  wire signed [7:0]                   w_data,

    // bias ROM (read port, 1-cycle latency)
    output reg  [$clog2(OUT_CH)-1:0] b_addr,
    input  wire signed [31:0]        b_data,

    // output activation memory (write port)
    output reg                                  out_we,
    output reg  [$clog2(OUT_CH*OUT_H*OUT_W)-1:0] out_addr,
    output reg  signed [7:0]                    out_data
);

    // -------------------------------------------------------------------
    // counters
    //
    // Use safe bit widths that give >=1 bit even when the parameter is 1
    // (e.g., IN_CH=1 in conv1). Without the (>1) guard, $clog2(1)=0 forms
    // an illegal `reg [-1:0]` in some simulators.
    // -------------------------------------------------------------------
    localparam OC_BITS = (OUT_CH > 1) ? $clog2(OUT_CH) : 1;
    localparam OY_BITS = (OUT_H  > 1) ? $clog2(OUT_H ) : 1;
    localparam OX_BITS = (OUT_W  > 1) ? $clog2(OUT_W ) : 1;
    localparam IC_BITS = (IN_CH  > 1) ? $clog2(IN_CH ) : 1;
    localparam K_BITS  = (K      > 1) ? $clog2(K     ) : 1;

    reg [OC_BITS-1:0] oc;
    reg [OY_BITS-1:0] oy;
    reg [OX_BITS-1:0] ox;
    reg [IC_BITS-1:0] ic;
    reg [K_BITS-1:0]  ky;
    reg [K_BITS-1:0]  kx;

    // last-iteration flags
    wire ic_last = (ic == IN_CH - 1);
    wire ky_last = (ky == K - 1);
    wire kx_last = (kx == K - 1);
    wire ox_last = (ox == OUT_W - 1);
    wire oy_last = (oy == OUT_H - 1);
    wire oc_last = (oc == OUT_CH - 1);

    wire kernel_last = ic_last & ky_last & kx_last;

    // -------------------------------------------------------------------
    // FSM
    //   IDLE       : wait for start
    //   READ_BIAS  : drive bias addr; bias appears next cycle
    //   LOAD_BIAS  : capture bias into acc
    //   ISSUE      : drive in/w addrs; data appears next cycle
    //   MAC        : multiply-accumulate using just-arrived in/w; advance counters or finish
    //   WB         : requantize acc, write output, advance to next (oc,oy,ox)
    //   FIN        : pulse done
    // -------------------------------------------------------------------
    localparam [2:0] S_IDLE      = 3'd0;
    localparam [2:0] S_READ_BIAS = 3'd1;
    localparam [2:0] S_LOAD_BIAS = 3'd2;
    localparam [2:0] S_ISSUE     = 3'd3;
    localparam [2:0] S_MAC       = 3'd4;
    localparam [2:0] S_WB        = 3'd5;
    localparam [2:0] S_FIN       = 3'd6;

    reg [2:0] state, next;

    reg signed [31:0] acc;

    // 8x8 signed multiply -> 16-bit signed product. Declared explicitly so we
    // can sign-extend cleanly (Verilog-2001 does not allow bit-select on an
    // expression like (a*b)[15]).
    wire signed [15:0] mac_prod = in_data * w_data;

    // Requantize unit (combinational)
    wire signed [7:0] q_out;
    requantize #(.SHIFT(REQUANT_SHIFT)) u_rq (.acc(acc), .q(q_out));

    // -------------------------------------------------------------------
    // Combinational next-state.
    // -------------------------------------------------------------------
    always @* begin
        next = state;
        case (state)
            S_IDLE:      if (start) next = S_READ_BIAS;
            S_READ_BIAS: next = S_LOAD_BIAS;
            S_LOAD_BIAS: next = S_ISSUE;
            S_ISSUE:     next = S_MAC;
            S_MAC: begin
                if (kernel_last) next = S_WB;
                else             next = S_ISSUE;
            end
            S_WB: begin
                if (oc_last && oy_last && ox_last) next = S_FIN;
                else                                next = S_READ_BIAS;
            end
            S_FIN:       next = S_IDLE;
            default:     next = S_IDLE;
        endcase
    end

    // -------------------------------------------------------------------
    // Sequential logic
    // -------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            state    <= S_IDLE;
            oc       <= 0; oy <= 0; ox <= 0;
            ic       <= 0; ky <= 0; kx <= 0;
            acc      <= 32'sd0;
            done     <= 1'b0;
            out_we   <= 1'b0;
        end else begin
            state  <= next;
            done   <= (next == S_FIN);
            out_we <= 1'b0;

            case (state)
                S_IDLE: begin
                    oc <= 0; oy <= 0; ox <= 0;
                    ic <= 0; ky <= 0; kx <= 0;
                end

                // bias appears on b_data this cycle (we drove b_addr in S_READ_BIAS)
                S_LOAD_BIAS: begin
                    acc <= b_data;
                    ic  <= 0; ky <= 0; kx <= 0;
                end

                S_MAC: begin
                    // mac_prod (signed 16) auto-sign-extends to signed 32 in this add.
                    acc <= acc + {{16{mac_prod[15]}}, mac_prod};

                    // advance kernel/channel counters for next issue
                    if (kx_last) begin
                        kx <= 0;
                        if (ky_last) begin
                            ky <= 0;
                            if (!ic_last) ic <= ic + 1'b1;
                        end else begin
                            ky <= ky + 1'b1;
                        end
                    end else begin
                        kx <= kx + 1'b1;
                    end
                end

                S_WB: begin
                    // write requantized output for current (oc, oy, ox)
                    out_we   <= 1'b1;
                    out_addr <= oc * (OUT_H * OUT_W) + oy * OUT_W + ox;
                    out_data <= q_out;
                    // advance output position
                    if (ox_last) begin
                        ox <= 0;
                        if (oy_last) begin
                            oy <= 0;
                            if (!oc_last) oc <= oc + 1'b1;
                        end else begin
                            oy <= oy + 1'b1;
                        end
                    end else begin
                        ox <= ox + 1'b1;
                    end
                end

                default: ;
            endcase
        end
    end

    // -------------------------------------------------------------------
    // Address drivers (combinational; data returns next cycle)
    // -------------------------------------------------------------------
    always @* begin
        // bias address always reflects current oc
        b_addr = oc;

        // input/weight addresses correspond to the MAC the engine will perform
        // on the cycle after the address is sampled.
        in_addr = ic * (IN_H * IN_W)
                + (oy * STRIDE + ky) * IN_W
                + (ox * STRIDE + kx);
        w_addr  = oc * (IN_CH * K * K)
                + ic * (K * K)
                + ky * K
                + kx;
    end

endmodule

`default_nettype wire
