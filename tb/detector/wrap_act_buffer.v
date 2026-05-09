// Test-only wrapper sizing act_buffer at WIDTH=8, DEPTH=576 (matches the
// 24x24 input-patch buffer that will sit between patch_extractor and conv1).

`default_nettype none

module wrap_act_buffer (
    input  wire              clk,
    input  wire              we,
    input  wire [9:0]        w_addr,
    input  wire signed [7:0] w_data,
    input  wire [9:0]        r_addr,
    output wire signed [7:0] r_data
);
    act_buffer #(
        .WIDTH(8),
        .DEPTH(576),
        .ADDR_W(10)
    ) u (
        .clk(clk),
        .we(we), .w_addr(w_addr), .w_data(w_data),
        .r_addr(r_addr), .r_data(r_data)
    );
endmodule

`default_nettype wire
