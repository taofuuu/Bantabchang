// fc_layer: 144-input, 2-output fully-connected layer.
//
// One MAC per cycle (sequential). Bit-exact equivalent of:
//
//   for oc in 0..1:
//     acc = bias[oc]                      # int32
//     for i in 0..143:
//       acc += w[oc, i] * input[i]        # signed 8x8 -> 16, accumulated in 32
//     logit[oc] = acc                     # raw int32, no requantize, no ReLU
//
// Address layout (matches scripts/export_weights.py):
//   input  : [i]                addr = i
//   weight : [out_feat, in_feat] addr = oc * IN_LEN + i
//   bias   : [oc]
//
// Output is two int32 logits exposed as separate ports. The detector_top
// computes (logit1 - logit0) for the face-vs-no-face score.

`default_nettype none

module fc_layer #(
    parameter IN_LEN  = 144,
    parameter OUT_LEN = 2
) (
    input  wire        clk,
    input  wire        rst,           // synchronous, active high
    input  wire        start,         // 1-cycle pulse
    output reg         done,          // 1-cycle pulse when finished

    // input act_buffer (1-cycle synchronous read)
    output reg  [7:0]        in_addr,
    input  wire signed [7:0] in_data,

    // weight ROM (1-cycle synchronous read)
    output reg  [8:0]        w_addr,
    input  wire signed [7:0] w_data,

    // bias ROM (1-cycle synchronous read)
    output reg               b_addr,
    input  wire signed [31:0] b_data,

    // outputs
    output reg signed [31:0] logit0,
    output reg signed [31:0] logit1
);

    // FSM
    localparam [2:0] S_IDLE      = 3'd0;
    localparam [2:0] S_READ_BIAS = 3'd1;
    localparam [2:0] S_LOAD_BIAS = 3'd2;
    localparam [2:0] S_ISSUE     = 3'd3;
    localparam [2:0] S_MAC       = 3'd4;
    localparam [2:0] S_WB        = 3'd5;
    localparam [2:0] S_FIN       = 3'd6;

    reg [2:0] state, next;

    reg       oc;             // 0 or 1
    reg [7:0] i;              // 0..143

    wire i_last  = (i == IN_LEN - 1);
    wire oc_last = (oc == OUT_LEN - 1);

    reg signed [31:0] acc;

    // Signed 8x8 multiply -> 16-bit signed product, sign-extended to 32 in the add.
    wire signed [15:0] mac_prod = in_data * w_data;

    // -------------------------------------------------------------------
    // next-state
    // -------------------------------------------------------------------
    always @* begin
        next = state;
        case (state)
            S_IDLE:      if (start) next = S_READ_BIAS;
            S_READ_BIAS: next = S_LOAD_BIAS;
            S_LOAD_BIAS: next = S_ISSUE;
            S_ISSUE:     next = S_MAC;
            S_MAC: begin
                if (i_last) next = S_WB;
                else        next = S_ISSUE;
            end
            S_WB: begin
                if (oc_last) next = S_FIN;
                else         next = S_READ_BIAS;
            end
            S_FIN:       next = S_IDLE;
            default:     next = S_IDLE;
        endcase
    end

    // -------------------------------------------------------------------
    // sequential
    // -------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            state  <= S_IDLE;
            oc     <= 1'b0;
            i      <= 0;
            acc    <= 32'sd0;
            done   <= 1'b0;
            logit0 <= 32'sd0;
            logit1 <= 32'sd0;
        end else begin
            state <= next;
            done  <= (next == S_FIN);

            case (state)
                S_IDLE: begin
                    if (start) begin
                        oc <= 1'b0;
                        i  <= 0;
                    end
                end

                S_LOAD_BIAS: begin
                    acc <= b_data;
                    i   <= 0;
                end

                S_MAC: begin
                    acc <= acc + {{16{mac_prod[15]}}, mac_prod};
                    if (!i_last) i <= i + 1'b1;
                end

                S_WB: begin
                    if (oc == 1'b0) logit0 <= acc;
                    else            logit1 <= acc;
                    if (!oc_last) oc <= oc + 1'b1;
                end

                default: ;
            endcase
        end
    end

    // -------------------------------------------------------------------
    // address drivers
    // -------------------------------------------------------------------
    always @* begin
        b_addr  = oc;
        in_addr = i;
        w_addr  = oc * IN_LEN + i;
    end

endmodule

`default_nettype wire
