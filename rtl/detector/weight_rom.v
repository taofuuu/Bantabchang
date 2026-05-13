// synchronous ROM for weights and biases, 1-cycle read latency.
// initialized from a hex file (readmemh, one value per line).
// set MEM_FILE="" to skip loading (useful for testbenches).

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
