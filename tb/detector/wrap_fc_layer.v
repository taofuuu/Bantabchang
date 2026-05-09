// Test wrapper for fc_layer: instantiates fc_layer + its activation buffer +
// weight/bias ROMs preloaded from weights/fc_w.hex and weights/fc_b.hex. The
// test pre-loads conv3 activations through the wrapper's act_buffer write
// port, kicks off fc_layer, and reads logit0 / logit1.

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

    // outputs
    output wire signed [31:0] logit0,
    output wire signed [31:0] logit1
);

    // act_buffer wires (read port driven by fc_layer)
    wire [7:0]        in_addr;
    wire signed [7:0] in_data;

    // weight rom wires
    wire [8:0]        w_addr;
    wire signed [7:0] w_data;

    // bias rom wires
    wire              b_addr;
    wire signed [31:0] b_data;

    act_buffer #(
        .WIDTH(8), .DEPTH(144), .ADDR_W(8)
    ) u_ab (
        .clk(clk),
        .we(ab_we), .w_addr(ab_w_addr), .w_data(ab_w_data),
        .r_addr(in_addr), .r_data(in_data)
    );

    weight_rom #(
        .WIDTH(8), .DEPTH(288), .ADDR_W(9),
        .MEM_FILE("/mnt/d/CU/HWSynProject/weights/fc_w.hex")
    ) u_w_rom (.clk(clk), .addr(w_addr), .data(w_data));

    weight_rom #(
        .WIDTH(32), .DEPTH(2), .ADDR_W(1),
        .MEM_FILE("/mnt/d/CU/HWSynProject/weights/fc_b.hex")
    ) u_b_rom (.clk(clk), .addr({b_addr}), .data(b_data));

    fc_layer #(
        .IN_LEN(144), .OUT_LEN(2)
    ) u_fc (
        .clk(clk), .rst(rst),
        .start(start), .done(done),
        .in_addr(in_addr), .in_data(in_data),
        .w_addr(w_addr),   .w_data(w_data),
        .b_addr(b_addr),   .b_data(b_data),
        .logit0(logit0), .logit1(logit1)
    );

endmodule

`default_nettype wire
