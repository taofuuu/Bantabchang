`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// OV7670 Camera Capture Module
// 
// Captures pixel data from the OV7670 camera and writes to frame buffer
// Input: RGB565 from camera (2 bytes per pixel)
// Output: RGB444 to frame buffer (12 bits per pixel)
// Resolution: 320x240 pixels
//////////////////////////////////////////////////////////////////////////////////

module ov7670_capture(
    input wire pclk,              // Pixel clock from camera (~24MHz)
    input wire vsync,             // Vertical sync (0 during frame)
    input wire href,              // Horizontal reference (1 during valid line)
    input wire [7:0] data_in,     // Pixel data from camera
    input wire reset,
    
    output reg [16:0] frame_addr,  // Address in frame buffer (0-76799)
    output reg [11:0] frame_pixel, // RGB444 pixel data
    output reg frame_we            // Write enable
);

    // Frame buffer size: 320 x 240 = 76,800 pixels
    parameter FRAME_WIDTH = 320;
    parameter FRAME_HEIGHT = 240;
    parameter MAX_ADDR = FRAME_WIDTH * FRAME_HEIGHT - 1;
    
    // States for pixel capture
    localparam WAIT_FRAME = 0;
    localparam CAPTURE_BYTE1 = 1;
    localparam CAPTURE_BYTE2 = 2;
    
    reg [1:0] state;
    reg [7:0] byte1;           // First byte of RGB565
    reg prev_vsync;
    reg prev_href;
    reg frame_active;
    
    // Pixel coordinates
    reg [8:0] pixel_x;         // 0-319
    reg [7:0] pixel_y;         // 0-239
    
    // RGB565 to RGB444 conversion
    // Input format (RGB565): RRRRR GGG GGG BBBBB (16 bits, 2 bytes)
    // Output format (RGB444): RRRR GGGG BBBB (12 bits)
    wire [4:0] rgb565_r;
    wire [5:0] rgb565_g;
    wire [4:0] rgb565_b;
    wire [3:0] rgb444_r;
    wire [3:0] rgb444_g;
    wire [3:0] rgb444_b;
    
    // Extract RGB565 components
    assign rgb565_r = {data_in[7:3]};           // First 5 bits of byte1
    assign rgb565_g = {data_in[2:0], byte1[7:5]};  // Last 3 of byte1 + first 3 of byte2
    assign rgb565_b = {byte1[4:0]};         // Last 5 bits of byte2
    
    // Convert to RGB444 (take most significant bits)
    assign rgb444_r = rgb565_r[4:1];
    assign rgb444_g = rgb565_g[5:2];
    assign rgb444_b = rgb565_b[4:1];
    
always @(posedge pclk or posedge reset) begin
        if (reset) begin
            state <= WAIT_FRAME;
            frame_addr <= 0;
            frame_we <= 0;
            prev_vsync <= 0;
        end else begin
            prev_vsync <= vsync;
            frame_we <= 0;

            // ตรวจจับ VSYNC เพื่อเริ่ม Frame ใหม่ (สมมติ VSYNC Active High ตามปกติของ OV7670)
            if (!prev_vsync && vsync) begin 
                frame_addr <= 0;
                state <= WAIT_FRAME;
            end 
            else begin
                case (state)
                    WAIT_FRAME: begin
                        if (href) state <= CAPTURE_BYTE1;
                    end
                    
                    CAPTURE_BYTE1: begin
                        if (href) begin
                            byte1 <= data_in;
                            state <= CAPTURE_BYTE2;
                        end else begin
                            state <= WAIT_FRAME;
                        end
                    end
                    
                    CAPTURE_BYTE2: begin
                        if (href) begin
                            frame_pixel <= {rgb444_r, rgb444_g, rgb444_b};
                            frame_we <= 1;
                            
                            // ใช้การบวกหนึ่งแทนการคูณ เพื่อความเสถียร
                            if (frame_addr < MAX_ADDR)
                                frame_addr <= frame_addr + 1;
                                
                            state <= CAPTURE_BYTE1;
                        end else begin
                            state <= WAIT_FRAME;
                        end
                    end
                endcase
            end
        end
    end

endmodule
