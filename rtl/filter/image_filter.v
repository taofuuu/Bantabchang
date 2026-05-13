`timescale 1ns / 1ps

// Implements image processing filters:
// 000: No filter (original image)
// 001: Grayscale conversion
// 010: Color inversion (negative)
// 011: Threshold (binary black/white)
// 100: Red channel only
// 101: Green channel only
// 110: Blue channel only
// 111: Brightness boost

module image_filter(
    input wire [11:0] pixel_in,    // RGB444 input
    input wire [2:0] filter_sel,   // Filter selection
    output reg [11:0] pixel_out    // RGB444 output
);

    // Extract color channels
    wire [3:0] red_in   = pixel_in[11:8];
    wire [3:0] green_in = pixel_in[7:4];
    wire [3:0] blue_in  = pixel_in[3:0];
    
    // Intermediate values
    reg [3:0] red_out;
    reg [3:0] green_out;
    reg [3:0] blue_out;
    
    // Grayscale calculation (weighted average)
    // Y = 0.299*R + 0.587*G + 0.114*B
    // Approximation: Y = (R + 2*G + B) / 4
    wire [5:0] gray_sum = {2'b00, red_in} + {1'b0, green_in, 1'b0} + {2'b00, blue_in};
    wire [3:0] gray = gray_sum[5:2];  // Divide by 4
    
    // Threshold calculation (for binary image)
    wire [5:0] brightness = {2'b00, red_in} + {2'b00, green_in} + {2'b00, blue_in};
    wire is_bright = (brightness > 6'd24);  // Threshold at mid-level
    
    always @(*) begin
        case (filter_sel)
            3'b000: begin
                // No filter - pass through
                red_out = red_in;
                green_out = green_in;
                blue_out = blue_in;
            end
            
            3'b001: begin
                // Grayscale filter
                red_out = gray;
                green_out = gray;
                blue_out = gray;
            end
            
            3'b010: begin
                // Color inversion (negative)
                red_out = ~red_in;
                green_out = ~green_in;
                blue_out = ~blue_in;
            end
            
            3'b011: begin
                // Threshold (binary black/white)
                if (is_bright) begin
                    red_out = 4'hF;
                    green_out = 4'hF;
                    blue_out = 4'hF;
                end else begin
                    red_out = 4'h0;
                    green_out = 4'h0;
                    blue_out = 4'h0;
                end
            end
            
            3'b100: begin
                // Red channel only
                red_out = red_in;
                green_out = 4'h0;
                blue_out = 4'h0;
            end
            
            3'b101: begin
                // Green channel only
                red_out = 4'h0;
                green_out = green_in;
                blue_out = 4'h0;
            end
            
            3'b110: begin
                // Blue channel only
                red_out = 4'h0;
                green_out = 4'h0;
                blue_out = blue_in;
            end
            
            3'b111: begin
                // Brightness boost (saturate at max)
                red_out = (red_in >= 4'hC) ? 4'hF : red_in + 4'h3;
                green_out = (green_in >= 4'hC) ? 4'hF : green_in + 4'h3;
                blue_out = (blue_in >= 4'hC) ? 4'hF : blue_in + 4'h3;
            end
            
            default: begin
                red_out = red_in;
                green_out = green_in;
                blue_out = blue_in;
            end
        endcase
        
        pixel_out = {red_out, green_out, blue_out};
    end

endmodule
