`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Frame Buffer Module (Dual-Port Block RAM)
// 
// This is a wrapper for Vivado Block Memory Generator IP
// Configuration:
// - Memory Type: True Dual Port RAM
// - Port A Width: 12 bits (RGB444)
// - Port A Depth: 76800 (320x240)
// - Port B Width: 12 bits
// - Port B Depth: 76800
// - Enable Port Type: Always Enabled
// - Write Enable: Byte Write Enable
// - Operating Mode: Write First
// 
// TO CREATE IN VIVADO:
// 1. IP Catalog -> Memories & Storage Elements -> Block Memory Generator
// 2. Configure as True Dual Port RAM
// 3. Set both ports to 12 bits width, 76800 depth (requires 17-bit addressing)
// 4. Generate the IP core
// 5. Instantiate it as shown below
//////////////////////////////////////////////////////////////////////////////////

// For simulation and initial testing, here's a behavioral model
// Replace this with the Vivado-generated IP core for synthesis

// Renamed from `frame_buffer` to avoid module-name collision with rtl/detector/frame_buffer.v.
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

//////////////////////////////////////////////////////////////////////////////////
// Alternative: Use Vivado Block Memory Generator IP
// 
// Uncomment this section and comment out the behavioral model above
// after generating the IP core in Vivado
//////////////////////////////////////////////////////////////////////////////////

/*
module frame_buffer(
    input wire clka,
    input wire wea,
    input wire [16:0] addra,
    input wire [11:0] dina,
    input wire clkb,
    input wire [16:0] addrb,
    output wire [11:0] doutb
);

    blk_mem_gen_0 bram_inst (
        .clka(clka),
        .wea(wea),
        .addra(addra),
        .dina(dina),
        .clkb(clkb),
        .addrb(addrb),
        .doutb(doutb)
    );

endmodule
*/
