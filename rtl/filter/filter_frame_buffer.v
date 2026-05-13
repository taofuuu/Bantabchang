`timescale 1ns / 1ps
// Frame Buffer Module (Dual-Port Block RAM)

module filter_frame_buffer(
    // Port A (Write - Camera side)
    input wire clka,
    input wire wea,
    input wire [16:0] addra,    // 17 bits for 76800 addresses
    input wire [11:0] dina,
    
    // Port B (Read - VGA side)
    input wire clkb,
    input wire [16:0] addrb,
    output reg [11:0] doutb
);

    // Block RAM storage
    (* ram_style = "block" *) reg [11:0] ram [0:76799];
    
    // Initialize RAM to black
    integer i;
    initial begin
        for (i = 0; i < 76800; i = i + 1) begin
            ram[i] = 12'h000;
        end
    end
    
    // Port A: Write operation
    always @(posedge clka) begin
        if (wea) begin
            ram[addra] <= dina;
        end
    end
    
    // Port B: Read operation
    always @(posedge clkb) begin
        doutb <= ram[addrb];
    end

endmodule
