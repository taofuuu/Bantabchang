`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Testbench for Image Filter Module
// 
// Tests all 8 filter modes with various input colors
//////////////////////////////////////////////////////////////////////////////////

module tb_image_filter();

    // Testbench signals
    reg [11:0] pixel_in;
    reg [2:0] filter_sel;
    wire [11:0] pixel_out;
    
    // Instantiate filter
    image_filter uut (
        .pixel_in(pixel_in),
        .filter_sel(filter_sel),
        .pixel_out(pixel_out)
    );
    
    // Extract output colors
    wire [3:0] r_out = pixel_out[11:8];
    wire [3:0] g_out = pixel_out[7:4];
    wire [3:0] b_out = pixel_out[3:0];
    
    // Test colors (RGB444 format)
    localparam WHITE  = 12'hFFF;
    localparam BLACK  = 12'h000;
    localparam RED    = 12'hF00;
    localparam GREEN  = 12'h0F0;
    localparam BLUE   = 12'h00F;
    localparam YELLOW = 12'hFF0;
    localparam CYAN   = 12'h0FF;
    localparam MAGENTA= 12'hF0F;
    localparam GRAY   = 12'h888;
    
    // Test procedure
    initial begin
        $display("========================================");
        $display("Image Filter Testbench");
        $display("========================================\n");
        
        // Test each filter with multiple colors
        test_filter(3'b000, "No Filter (Pass Through)");
        test_filter(3'b001, "Grayscale");
        test_filter(3'b010, "Invert (Negative)");
        test_filter(3'b011, "Binary Threshold");
        test_filter(3'b100, "Red Channel Only");
        test_filter(3'b101, "Green Channel Only");
        test_filter(3'b110, "Blue Channel Only");
        test_filter(3'b111, "Brightness Boost");
        
        $display("\n========================================");
        $display("All tests complete!");
        $display("========================================");
        $finish;
    end
    
    // Task to test a filter with various colors
    task test_filter;
        input [2:0] mode;
        input [200:0] filter_name;
        begin
            $display("--- Testing Filter %0d: %0s ---", mode, filter_name);
            filter_sel = mode;
            
            test_color(WHITE,   "White");
            test_color(BLACK,   "Black");
            test_color(RED,     "Red");
            test_color(GREEN,   "Green");
            test_color(BLUE,    "Blue");
            test_color(YELLOW,  "Yellow");
            test_color(CYAN,    "Cyan");
            test_color(MAGENTA, "Magenta");
            test_color(GRAY,    "Gray");
            
            $display("");
        end
    endtask
    
    // Task to test a single color
    task test_color;
        input [11:0] color;
        input [80:0] color_name;
        reg [3:0] r_in, g_in, b_in;
        begin
            pixel_in = color;
            #10;  // Wait for combinational logic
            
            r_in = color[11:8];
            g_in = color[7:4];
            b_in = color[3:0];
            
            $display("  %0s: RGB(%h,%h,%h) → RGB(%h,%h,%h)", 
                color_name, r_in, g_in, b_in, r_out, g_out, b_out);
            
            // Verify specific expected results
            case (filter_sel)
                3'b000: begin // Pass through
                    if (pixel_out != pixel_in) 
                        $display("    ERROR: Pass-through filter changed pixel!");
                end
                
                3'b010: begin // Invert
                    if (pixel_out != ~pixel_in)
                        $display("    ERROR: Invert filter incorrect!");
                end
                
                3'b100: begin // Red only
                    if (g_out != 0 || b_out != 0)
                        $display("    ERROR: Red-only filter has G or B components!");
                end
                
                3'b101: begin // Green only
                    if (r_out != 0 || b_out != 0)
                        $display("    ERROR: Green-only filter has R or B components!");
                end
                
                3'b110: begin // Blue only
                    if (r_out != 0 || g_out != 0)
                        $display("    ERROR: Blue-only filter has R or G components!");
                end
                
                3'b001: begin // Grayscale
                    if (r_out != g_out || g_out != b_out)
                        $display("    ERROR: Grayscale should have R=G=B!");
                end
            endcase
        end
    endtask
    
    // Generate waveform file
    initial begin
        $dumpfile("image_filter.vcd");
        $dumpvars(0, tb_image_filter);
    end

endmodule
