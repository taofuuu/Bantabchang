// generic 2D conv + bias + relu + requantize. one mac per cycle.
// address layout: input [ic,iy,ix], weight [oc,ic,ky,kx], output [oc,oy,ox].

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

    // counters — guard: $clog2(1)=0 makes reg [-1:0] which is illegal in some simulators
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

    // FSM: IDLE → READ_BIAS → LOAD_BIAS → ISSUE → MAC → WB → FIN
    localparam [2:0] S_IDLE      = 3'd0;
    localparam [2:0] S_READ_BIAS = 3'd1;
    localparam [2:0] S_LOAD_BIAS = 3'd2;
    localparam [2:0] S_ISSUE     = 3'd3;
    localparam [2:0] S_MAC       = 3'd4;
    localparam [2:0] S_WB        = 3'd5;
    localparam [2:0] S_FIN       = 3'd6;

    reg [2:0] state, next;

    reg signed [31:0] acc;

    // 8x8 signed product; declared explicitly for clean sign-extension
    wire signed [15:0] mac_prod = in_data * w_data;

    // Requantize unit (combinational)
    wire signed [7:0] q_out;
    requantize #(.SHIFT(REQUANT_SHIFT)) u_rq (.acc(acc), .q(q_out));

    // next-state
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

    // sequential
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

                // bias from previous cycle's read
                S_LOAD_BIAS: begin
                    acc <= b_data;
                    ic  <= 0; ky <= 0; kx <= 0;
                end

                S_MAC: begin
                    // sign-extend 16-bit product to 32
                    acc <= acc + {{16{mac_prod[15]}}, mac_prod};

                    // advance kernel counters
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
                    // write requantized output
                    out_we   <= 1'b1;
                    out_addr <= oc * (OUT_H * OUT_W) + oy * OUT_W + ox;
                    out_data <= q_out;
                    // advance position
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

    // address drivers
    always @* begin
        b_addr = oc;

        // addresses for next mac
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
