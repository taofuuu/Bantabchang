// weight_rom: parameterized synchronous ROM, one-cycle read latency.
//
// Initialized at simulation/synthesis startup from a hex file (matches the
// $readmemh format produced by scripts/export_weights.py: one signed value
// per line, two's complement, comments allowed).
//
// Usage example (one ROM per weight tensor or bias tensor):
//   weight_rom #(
//       .WIDTH(8), .DEPTH(72), .ADDR_W(7),
//       .MEM_FILE("weights/conv1_w.hex")
//   ) u_conv1_w (.clk(clk), .addr(w_addr), .data(w_data));
//
//   weight_rom #(
//       .WIDTH(32), .DEPTH(8), .ADDR_W(3),
//       .MEM_FILE("weights/conv1_b.hex")
//   ) u_conv1_b (.clk(clk), .addr(b_addr), .data(b_data));
//
// Vivado synthesis will infer Block RAM (or distributed RAM for small DEPTH).
// Leaving MEM_FILE = "" skips $readmemh — useful when a testbench wants to
// poke memory contents directly via hierarchical access.

`default_nettype none

module weight_rom #(
    parameter WIDTH    = 8,
    parameter DEPTH    = 256,
    parameter ADDR_W   = 8,
    parameter MEM_FILE = ""
) (
    input  wire                    clk,
    input  wire [ADDR_W-1:0]       addr,
    output reg  signed [WIDTH-1:0] data
);

    reg [WIDTH-1:0] mem [0:DEPTH-1];

    initial begin
        if (MEM_FILE != "") begin
            $readmemh(MEM_FILE, mem);
        end
    end

    always @(posedge clk) begin
        data <= mem[addr];
    end

endmodule

`default_nettype wire
