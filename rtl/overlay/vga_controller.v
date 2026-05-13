`timescale 1ns / 1ps
// Generates VGA 640x480@60Hz timing signals by tracking pixel coordinates,
// maintaining proper horizontal/vertical sync pulses and active display regions.

module vga_controller(
    input wire clk,           // 25 MHz pixel clock from clk_wiz_0
    input wire reset,
    
    output reg hsync,
    output reg vsync,
    output wire active,       // High during active display region
    output wire [9:0] x_pos,  // Current X position (0-799)
    output wire [9:0] y_pos   // Current Y position (0-524)
);

    // VGA 640x480 @ 60Hz timing parameters
    // Horizontal timing (pixels)
    parameter H_DISPLAY    = 640;
    parameter H_FRONT      = 16;
    parameter H_SYNC       = 96;
    parameter H_BACK       = 48;
    parameter H_TOTAL      = H_DISPLAY + H_FRONT + H_SYNC + H_BACK; // 800
    
    // Vertical timing (lines)
    parameter V_DISPLAY    = 480;
    parameter V_FRONT      = 10;
    parameter V_SYNC       = 2;
    parameter V_BACK       = 33;
    parameter V_TOTAL      = V_DISPLAY + V_FRONT + V_SYNC + V_BACK; // 525
    
    // Current position counters
    reg [9:0] h_count;
    reg [9:0] v_count;
    
    assign x_pos = h_count;
    assign y_pos = v_count;
    
    // Active display region
    assign active = (h_count < H_DISPLAY) && (v_count < V_DISPLAY);
    
    // Horizontal counter
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            h_count <= 0;
        end else begin
            if (h_count >= H_TOTAL - 1) begin
                h_count <= 0;
            end else begin
                h_count <= h_count + 1;
            end
        end
    end
    
    // Vertical counter
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            v_count <= 0;
        end else begin
            if (h_count >= H_TOTAL - 1) begin
                if (v_count >= V_TOTAL - 1) begin
                    v_count <= 0;
                end else begin
                    v_count <= v_count + 1;
                end
            end
        end
    end
    
    // Generate HSYNC
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            hsync <= 1;
        end else begin
            //sync period
            if (h_count >= (H_DISPLAY + H_FRONT) && 
                h_count < (H_DISPLAY + H_FRONT + H_SYNC)) begin
                hsync <= 0;
            end else begin
                hsync <= 1;
            end
        end
    end
    
    // Generate VSYNC
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            vsync <= 1;
        end else begin
            //sync period
            if (v_count >= (V_DISPLAY + V_FRONT) && 
                v_count < (V_DISPLAY + V_FRONT + V_SYNC)) begin
                vsync <= 0;
            end else begin
                vsync <= 1;
            end
        end
    end

endmodule
