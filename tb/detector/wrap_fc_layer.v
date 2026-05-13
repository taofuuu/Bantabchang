// Test wrapper for fc_layer: instantiates fc_layer + its activation buffer +
// weight/bias ROMs preloaded from weights/fc_w.hex and weights/fc_b.hex. The
// test pre-loads conv3 activations through the wrapper's act_buffer write
// port, kicks off fc_layer, and reads the five int32 outputs
// (out_conf / out_x0 / out_y0 / out_w / out_h).

`default_nettype none

module wrap_fc_layer (
    input  wire        clk,
    input  wire        rst,

    // act_buffer preload port (test writes conv3 activations here)
    input  wire              ab_we,
    input  wire [7:0]        ab_w_addr,
    input  wire signed [7:0] ab_w_data,

    // fc_layer control
    input  wire        start,
    output wire        done,

    // five int32 outputs (matches fc_layer.v)
    output wire signed [31:0] out_conf,
    output wire signed [31:0] out_x0,
    output wire signed [31:0] out_y0,
    output wire signed [31:0] out_w,
    output wire signed [31:0] out_h
);

    // act_buffer wires (read port driven by fc_layer)
    wire [7:0]        in_addr;
    wire signed [7:0] in_data;

    // weight rom wires (720 entries = 5*144 -> 10-bit address)
    wire [9:0]        w_addr;
    wire signed [7:0] w_data;

    // bias rom wires (5 entries -> 3-bit address)
    wire [2:0]        b_addr;
    wire signed [31:0] b_data;

    act_buffer #(
        .WIDTH(8), .DEPTH(144), .ADDR_W(8)
    ) u_ab (
        .clk(clk),
        .we(ab_we), .w_addr(ab_w_addr), .w_data(ab_w_data),
        .r_addr(in_addr), .r_data(in_data)
    );

    weight_rom #(
        .WIDTH(8), .DEPTH(720), .ADDR_W(10),
        .MEM_FILE("/mnt/d/CU/Bantabchang/weights/fc_w.hex")
    ) u_w_rom (.clk(clk), .addr(w_addr), .data(w_data));

    weight_rom #(
        .WIDTH(32), .DEPTH(5), .ADDR_W(3),
        .MEM_FILE("/mnt/d/CU/Bantabchang/weights/fc_b.hex")
    ) u_b_rom (.clk(clk), .addr(b_addr), .data(b_data));

    fc_layer #(
        .IN_LEN(144), .OUT_LEN(5)
    ) u_fc (
        .clk(clk), .rst(rst),
        .start(start), .done(done),
        .in_addr(in_addr), .in_data(in_data),
        .w_addr(w_addr),   .w_data(w_data),
        .b_addr(b_addr),   .b_data(b_data),
        .out_conf(out_conf),
        .out_x0  (out_x0),
        .out_y0  (out_y0),
        .out_w   (out_w),
        .out_h   (out_h)
    );

endmodule

`default_nettype wire
