`default_nettype none

module fc_layer #(
    parameter IN_LEN  = 144,
    parameter OUT_LEN = 5
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,
    output reg         done,

    // input act_buffer
    output wire [7:0]        in_addr,
    input  wire signed [7:0] in_data,

    // weight ROM
    output wire [9:0]        w_addr,
    input  wire signed [7:0] w_data,

    // bias ROM
    output wire [2:0]         b_addr,
    input  wire signed [31:0] b_data,

    // outputs
    output reg signed [31:0] out_conf,
    output reg signed [31:0] out_x0,
    output reg signed [31:0] out_y0,
    output reg signed [31:0] out_w,
    output reg signed [31:0] out_h
);

    // FSM States
    localparam [2:0] S_IDLE      = 3'd0;
    localparam [2:0] S_READ_BIAS = 3'd1;
    localparam [2:0] S_LOAD_BIAS = 3'd2;
    localparam [2:0] S_MAC       = 3'd3;
    localparam [2:0] S_WB        = 3'd4;
    localparam [2:0] S_FIN       = 3'd5;

    reg [2:0] state, next;
    reg [2:0] oc;
    reg [7:0] i;
    reg signed [31:0] acc;
    reg pipe_vld;

    // --- FIX: Explicitly declare the multiplier wire ---
    wire signed [15:0] mac_prod = in_data * w_data;

    // FSM Next State Logic
    always @* begin
        next = state;
        case (state)
            S_IDLE:      if (start) next = S_READ_BIAS;
            S_READ_BIAS: next = S_LOAD_BIAS;
            S_LOAD_BIAS: next = S_MAC;
            S_MAC:       if (i == IN_LEN-1 && pipe_vld) next = S_WB;
                         else next = S_MAC;
            S_WB:        if (oc == OUT_LEN-1) next = S_FIN;
                         else next = S_READ_BIAS;
            S_FIN:       next = S_IDLE;
            default:     next = S_IDLE;
        endcase
    end

    // Sequential Logic
    always @(posedge clk) begin
        if (rst) begin
            state    <= S_IDLE;
            oc       <= 0;
            i        <= 0;
            acc      <= 0;
            pipe_vld <= 0;
            done     <= 0;
            out_conf <= 0; out_x0 <= 0; out_y0 <= 0; out_w <= 0; out_h <= 0;
        end else begin
            state <= next;
            done  <= (next == S_FIN);

            case (state)
                S_IDLE: begin
                    oc <= 0;
                end

                S_LOAD_BIAS: begin
                    acc <= b_data;
                    i <= 0;
                    pipe_vld <= 0;
                end

                S_MAC: begin
                    // Accumulate data from previous cycle's address
                    if (pipe_vld) begin
                        acc <= acc + $signed(mac_prod);
                    end
                    
                    if (i < IN_LEN - 1) begin
                        i <= i + 1;
                        pipe_vld <= 1;
                    end else begin
                        // Staying at i=143 for one last cycle to let pipe_vld catch the last data
                    end
                end

                S_WB: begin
                    case (oc)
                        3'd0: out_conf <= acc;
                        3'd1: out_x0   <= acc;
                        3'd2: out_y0   <= acc;
                        3'd3: out_w    <= acc;
                        3'd4: out_h    <= acc;
                    endcase
                    if (oc < OUT_LEN - 1) oc <= oc + 1;
                end
            endcase
        end
    end

    // Continuous Assignments for Addresses
    assign b_addr  = oc;
    assign in_addr = i;
    assign w_addr  = (oc * 144) + i; // Explicitly using 144 for clarity

endmodule