// Test-only wrapper that fixes weight_rom's parameters and MEM_FILE for the
// cocotb test. Not used in synthesis; the real instantiator (detector_top)
// will supply its own paths.

`default_nettype none

module wrap_weight_rom (
    input  wire              clk,
    input  wire [6:0]        addr,
    output wire signed [7:0] data
);
    weight_rom #(
        .WIDTH(8),
        .DEPTH(72),
        .ADDR_W(7),
        .MEM_FILE("/mnt/d/CU/HWSynProject/weights/conv1_w.hex")
    ) u (
        .clk(clk),
        .addr(addr),
        .data(data)
    );
endmodule

`default_nettype wire
