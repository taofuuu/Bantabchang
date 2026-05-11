// fc_layer: 144-input, 5-output fully-connected layer.
//
// Output channel layout (set by scripts/export_weights.py):
//   out_conf : face / no-face confidence logit
//   out_x0   : face top-left X inside the 24x24 patch  (int32 in scaled units)
//   out_y0   : face top-left Y inside the 24x24 patch
//   out_w    : face width  inside the 24x24 patch
//   out_h    : face height inside the 24x24 patch
//
// The four bounding-box outputs are dequantized in detector_top by right-
// shifting by FC_OUT_SHIFT bits (= W_FC_SCALE_EXP + ACT3_SCALE_EXP); the
// result is in patch pixel coordinates [0, 24].
//
// Address layout (matches scripts/export_weights.py):
//   input  : addr = i
//   weight : addr = oc * IN_LEN + i               (oc 0..4, i 0..143)
//   bias   : addr = oc
//
// One MAC per cycle, sequential per output channel. Same FSM skeleton as
// the previous 2-output classifier; only the output port width and the
// writeback case expand.

`default_nettype none

module fc_layer #(
    parameter IN_LEN  = 144,
    parameter OUT_LEN = 5
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,
    output reg         done,

    // input act_buffer (1-cycle synchronous read)
    output reg  [7:0]        in_addr,
    input  wire signed [7:0] in_data,

    // weight ROM (1-cycle synchronous read) - need ceil(log2(IN_LEN*OUT_LEN)) bits
    output reg  [9:0]        w_addr,
    input  wire signed [7:0] w_data,

    // bias ROM (1-cycle synchronous read) - 3 bits supports up to 8 outputs
    output reg  [2:0]         b_addr,
    input  wire signed [31:0] b_data,

    // five int32 outputs
    output reg  signed [31:0] out_conf,
    output reg  signed [31:0] out_x0,
    output reg  signed [31:0] out_y0,
    output reg  signed [31:0] out_w,
    output reg  signed [31:0] out_h
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

    reg [2:0] oc;             // 0..4
    reg [7:0] i;              // 0..143

    wire i_last  = (i  == IN_LEN  - 1);
    wire oc_last = (oc == OUT_LEN - 1);

    reg signed [31:0] acc;

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
            state    <= S_IDLE;
            oc       <= 3'd0;
            i        <= 8'd0;
            acc      <= 32'sd0;
            done     <= 1'b0;
            out_conf <= 32'sd0;
            out_x0   <= 32'sd0;
            out_y0   <= 32'sd0;
            out_w    <= 32'sd0;
            out_h    <= 32'sd0;
        end else begin
            state <= next;
            done  <= (next == S_FIN);

            case (state)
                S_IDLE: begin
                    if (start) begin
                        oc <= 3'd0;
                        i  <= 8'd0;
                    end
                end

                S_LOAD_BIAS: begin
                    acc <= b_data;
                    i   <= 8'd0;
                end

                S_MAC: begin
                    acc <= acc + {{16{mac_prod[15]}}, mac_prod};
                    if (!i_last) i <= i + 1'b1;
                end

                S_WB: begin
                    case (oc)
                        3'd0: out_conf <= acc;
                        3'd1: out_x0   <= acc;
                        3'd2: out_y0   <= acc;
                        3'd3: out_w    <= acc;
                        3'd4: out_h    <= acc;
                        default: ;
                    endcase
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
