// act_buffer: simple dual-port BRAM for inter-layer activations.
//
//   Port A (write): synchronous, write-when-we
//   Port B (read):  synchronous, 1-cycle latency
//
// One instance per inter-layer activation tensor:
//   input patch buffer:  24*24    = 576 entries  -> ADDR_W=10
//   conv1 output:        11*11*8  = 968 entries  -> ADDR_W=10
//   conv2 output:        5*5*16   = 400 entries  -> ADDR_W=9
//   conv3 output:        3*3*16   = 144 entries  -> ADDR_W=8
//
// Vivado will infer a Block RAM (or distributed RAM for the smallest sizes).
// The producer drives port A; the consumer (next conv_layer) drives port B
// for read-back. Same clock domain throughout (single 100 MHz clk).

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

    // read port (1-cycle synchronous read)
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
