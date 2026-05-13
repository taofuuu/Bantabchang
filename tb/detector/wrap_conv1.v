// Test wrapper for conv_layer parameterized as conv1.
// conv1: IN_CH=1, OUT_CH=8, IN=24x24, K=3, STRIDE=2. REQUANT_SHIFT comes
// from weights/scales.vh so it always tracks the latest export_weights.py run.

`include "scales.vh"
`default_nettype none

module wrap_conv1 (
    input  wire        clk,
    input  wire        rst,

    // input act_buffer preload (test writes the 24x24 patch here)
    input  wire              ab_in_we,
    input  wire [9:0]        ab_in_w_addr,
    input  wire signed [7:0] ab_in_w_data,

    // start/done
    input  wire        start,
    output wire        done,

    // output act_buffer read port (test reads 968-entry conv1 output)
    input  wire [9:0]        ab_out_r_addr,
    output wire signed [7:0] ab_out_r_data
);

    // input act_buffer (576 entries)
    wire [9:0]        in_r_addr;
    wire signed [7:0] in_r_data;
    act_buffer #(.WIDTH(8), .DEPTH(576), .ADDR_W(10)) u_in_ab (
        .clk(clk),
        .we(ab_in_we), .w_addr(ab_in_w_addr), .w_data(ab_in_w_data),
        .r_addr(in_r_addr), .r_data(in_r_data)
    );

    // weight ROM (72 int8) and bias ROM (8 int32)
    wire [6:0]         w_addr;
    wire signed [7:0]  w_data;
    weight_rom #(
        .WIDTH(8), .DEPTH(72), .ADDR_W(7),
        .MEM_FILE("/mnt/d/CU/Bantabchang/weights/conv1_w.hex")
    ) u_w_rom (.clk(clk), .addr(w_addr), .data(w_data));

    wire [2:0]         b_addr;
    wire signed [31:0] b_data;
    weight_rom #(
        .WIDTH(32), .DEPTH(8), .ADDR_W(3),
        .MEM_FILE("/mnt/d/CU/Bantabchang/weights/conv1_b.hex")
    ) u_b_rom (.clk(clk), .addr(b_addr), .data(b_data));

    // output act_buffer (968 entries)
    wire             ab_out_we;
    wire [9:0]       ab_out_w_addr;
    wire signed [7:0] ab_out_w_data;
    act_buffer #(.WIDTH(8), .DEPTH(968), .ADDR_W(10)) u_out_ab (
        .clk(clk),
        .we(ab_out_we), .w_addr(ab_out_w_addr), .w_data(ab_out_w_data),
        .r_addr(ab_out_r_addr), .r_data(ab_out_r_data)
    );

    conv_layer #(
        .IN_CH(1), .OUT_CH(8),
        .IN_H(24), .IN_W(24),
        .K(3), .STRIDE(2),
        .REQUANT_SHIFT(`CONV1_SHIFT)
    ) u_conv (
        .clk(clk), .rst(rst),
        .start(start), .done(done),
        .in_addr(in_r_addr),       .in_data(in_r_data),
        .w_addr(w_addr),           .w_data(w_data),
        .b_addr(b_addr),           .b_data(b_data),
        .out_we(ab_out_we),
        .out_addr(ab_out_w_addr),  .out_data(ab_out_w_data)
    );

endmodule

`default_nettype wire
