// requantize: int32 accumulator -> int8 post-ReLU activation.
//
// y = clip( (acc + (1 << (SHIFT-1))) >>> SHIFT, 0, 127 )    // round-half-up, ReLU, sat
//
// Negative-shift case (SHIFT <= 0) is supported but unusual; for SHIFT==0 the
// rounding bias is 0 and we just relu+saturate. SHIFT < 0 left-shifts (rare).
//
// This must match scripts/quantize.py:arith_right_shift_round + relu_clip_int8
// bit-exactly for every value in the int32 domain.

`default_nettype none

module requantize #(
    parameter SHIFT = 8           // requantization right-shift, signed integer
) (
    input  wire signed [31:0] acc,
    output wire signed [7:0]  q
);

    localparam signed [31:0] BIAS = (SHIFT > 0) ? (32'sd1 <<< (SHIFT - 1)) : 32'sd0;

    wire signed [31:0] shifted;
    generate
        if (SHIFT > 0) begin : g_rshift
            assign shifted = (acc + BIAS) >>> SHIFT;
        end else if (SHIFT == 0) begin : g_noshift
            assign shifted = acc;
        end else begin : g_lshift
            assign shifted = acc <<< (-SHIFT);
        end
    endgenerate

    // ReLU + saturate to [0, 127].
    assign q = (shifted <= 32'sd0)   ? 8'sd0   :
               (shifted >= 32'sd127) ? 8'sd127 :
                                       shifted[7:0];

endmodule

`default_nettype wire
