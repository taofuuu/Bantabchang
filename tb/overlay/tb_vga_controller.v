`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Testbench for VGA Controller
// 
// This testbench verifies the VGA timing signals for 640x480 @ 60Hz
// Expected timing:
// - Horizontal: 800 clocks per line (640 active + 160 blanking)
// - Vertical: 525 lines per frame (480 active + 45 blanking)
// - Frame rate: 25MHz / (800 * 525) = 59.52 Hz ≈ 60 Hz
//////////////////////////////////////////////////////////////////////////////////

module tb_vga_controller();

    // Testbench signals
    reg clk;
    reg reset;
    wire hsync;
    wire vsync;
    wire active;
    wire [9:0] x_pos;
    wire [9:0] y_pos;
    
    // Clock generation (25 MHz = 40ns period)
    parameter CLK_PERIOD = 40;
    
    initial begin
        clk = 0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end
    
    // Instantiate VGA controller
    vga_controller uut (
        .clk(clk),
        .reset(reset),
        .hsync(hsync),
        .vsync(vsync),
        .active(active),
        .x_pos(x_pos),
        .y_pos(y_pos)
    );
    
    // Monitoring variables
    integer h_count;
    integer v_count;
    integer frame_count;
    integer pixel_count;
    
    // Test procedure
    initial begin
        $display("========================================");
        $display("VGA Controller Testbench Starting");
        $display("Clock Period: %0d ns (25 MHz)", CLK_PERIOD);
        $display("========================================");
        
        // Initialize
        reset = 1;
        h_count = 0;
        v_count = 0;
        frame_count = 0;
        pixel_count = 0;
        
        // Release reset
        #(CLK_PERIOD * 10);
        reset = 0;
        $display("Time %0t: Reset released", $time);
        
        // Monitor first horizontal line
        $display("\n--- Monitoring First Horizontal Line ---");
        @(negedge hsync);
        $display("Time %0t: HSYNC pulse detected at pixel %0d", $time, x_pos);
        
        // Wait for full horizontal line
        repeat(800) @(posedge clk);
        
        // Check horizontal timing
        $display("Horizontal line complete");
        $display("  Display pixels: 0-639 (should be active)");
        $display("  Blanking: 640-799 (should be inactive)");
        
        // Monitor VSYNC timing
        $display("\n--- Monitoring Vertical Sync ---");
        @(negedge vsync);
        $display("Time %0t: VSYNC pulse started at line %0d", $time, y_pos);
        @(posedge vsync);
        $display("Time %0t: VSYNC pulse ended", $time);
        
        // Monitor complete frame
        $display("\n--- Monitoring Complete Frame ---");
        pixel_count = 0;
        
        // Count active pixels in one frame
        fork
            begin
                // Wait for one complete frame
                @(posedge vsync);
                @(posedge vsync);
            end
            
            begin
                // Count active pixels
                while(1) begin
                    @(posedge clk);
                    if (active) pixel_count = pixel_count + 1;
                    if (vsync) break;
                end
            end
        join
        
        $display("Active pixels in frame: %0d", pixel_count);
        $display("Expected: 640 × 480 = 307200");
        
        if (pixel_count == 307200) begin
            $display("✓ PASS: Correct number of active pixels");
        end else begin
            $display("✗ FAIL: Incorrect pixel count");
        end
        
        // Test pixel doubling addressing
        $display("\n--- Testing Pixel Doubling ---");
        $display("VGA Position (0,0) should map to frame buffer (0,0)");
        $display("VGA Position (1,0) should map to frame buffer (0,0)");
        $display("VGA Position (2,0) should map to frame buffer (1,0)");
        $display("VGA Position (0,2) should map to frame buffer (0,1)");
        
        // Reset and check specific positions
        reset = 1;
        #(CLK_PERIOD * 2);
        reset = 0;
        
        // Wait for active region
        while(!active) @(posedge clk);
        
        $display("\nSampling VGA positions:");
        repeat(10) begin
            @(posedge clk);
            if (active) begin
                $display("  VGA (%0d,%0d) → Frame buffer (%0d,%0d)", 
                    x_pos, y_pos, x_pos[9:1], y_pos[9:1]);
            end
        end
        
        // Summary
        $display("\n========================================");
        $display("VGA Controller Testbench Complete");
        $display("========================================");
        
        #1000;
        $finish;
    end
    
    // Timing verification
    always @(negedge hsync) begin
        if (h_count > 0 && h_count != 800) begin
            $display("ERROR: Horizontal timing incorrect! Expected 800, got %0d", h_count);
        end
        h_count = 0;
    end
    
    always @(posedge clk) begin
        if (!reset) h_count = h_count + 1;
    end
    
    // Optional: Generate VCD waveform file
    initial begin
        $dumpfile("vga_controller.vcd");
        $dumpvars(0, tb_vga_controller);
    end

endmodule
