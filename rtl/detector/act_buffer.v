// simple dual-port BRAM for inter-layer activations.
// write port: synchronous. read port: 1-cycle latency.

`default_nettype none

module act_buffer #(
    parameter WIDTH  = 8,
    parameter DEPTH  = 576,
    parameter ADDR_W = 10
) (
    input  wire                    clk,

    // write port
    input  wire                    we,
    input  wire [ADDR_W-1:0]       w_addr,
    input  wire signed [WIDTH-1:0] w_data,

    // read port, 1-cycle latency
    input  wire [ADDR_W-1:0]       r_addr,
    output reg  signed [WIDTH-1:0] r_data
);

    reg [WIDTH-1:0] mem [0:DEPTH-1];

    always @(posedge clk) begin
        if (we) mem[w_addr] <= w_data;
        r_data <= mem[r_addr];
    end

endmodule

`default_nettype wire
