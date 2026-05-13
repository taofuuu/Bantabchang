// int32 acc → int8 post-relu
// must match quantize.py

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

    // relu + saturate to [0, 127]
    assign q = (shifted <= 32'sd0)   ? 8'sd0   :
               (shifted >= 32'sd127) ? 8'sd127 :
                                       shifted[7:0];

endmodule

`default_nettype wire
