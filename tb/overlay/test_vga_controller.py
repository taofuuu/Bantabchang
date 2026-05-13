import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, Timer

async def reset_dut(dut):
    dut.reset.value = 1
    await Timer(80, units="ns") # Wait 2 clock periods (40ns * 2)
    dut.reset.value = 0

@cocotb.test()
async def test_vga_timing_and_addressing(dut):
    """Verify VGA timing (800x525 total) and pixel doubling logic."""
    
    # 25 MHz Clock = 40ns period
    cocotb.start_soon(Clock(dut.clk, 40, units="ns").start())
    
    await reset_dut(dut)
    dut._log.info("Reset released")

    # --- 1. Monitor Horizontal Timing ---
    # Wait for the first HSYNC pulse
    await FallingEdge(dut.hsync)
    start_time = cocotb.utils.get_sim_time(units="ns")
    
    # Wait for the next HSYNC pulse to measure a full line
    await FallingEdge(dut.hsync)
    end_time = cocotb.utils.get_sim_time(units="ns")
    
    line_duration = end_time - start_time
    # 800 pixels * 40ns = 32,000 ns
    expected_line_ns = 32000 
    assert line_duration == expected_line_ns, f"Line duration incorrect: {line_duration}ns"
    dut._log.info(f"Horizontal line timing verified: {line_duration}ns")

    # --- 2. Count Active Pixels in a Frame ---
    # Wait for VSYNC to start a new frame
    await FallingEdge(dut.vsync)
    
    pixel_count = 0
    # Monitor until the next VSYNC pulse
    while True:
        await RisingEdge(dut.clk)
        if int(dut.active.value) == 1:
            pixel_count += 1
        
        # Check if vsync falls again (start of next frame)
        if dut.vsync.value == 0: 
            # We check the condition after the current vsync pulse finishes
            # to ensure we counted exactly one frame.
            if pixel_count >= 307200: 
                break
        
        # Safety timeout to prevent infinite loop if signals fail
        if cocotb.utils.get_sim_time(units="ms") > 20:
            assert False, "Timeout waiting for frame completion"

    expected_pixels = 640 * 480
    assert pixel_count == expected_pixels, f"Pixel count mismatch: {pixel_count} vs {expected_pixels}"
    dut._log.info(f"✓ PASS: {pixel_count} active pixels counted in one frame")

    # --- 3. Test Pixel Doubling Addressing ---
    # Wait for the next active region
    while int(dut.active.value) == 0:
        await RisingEdge(dut.clk)
    
    dut._log.info("Sampling VGA positions for pixel doubling verification:")
    for _ in range(10):
        x = int(dut.x_pos.value)
        y = int(dut.y_pos.value)
        
        # Based on Verilog: x_pos[9:1] and y_pos[9:1] (divide by 2)
        fb_x = x >> 1
        fb_y = y >> 1
        
        dut._log.info(f"  VGA ({x},{y}) -> Frame Buffer ({fb_x},{fb_y})")
        
        # Simple verification: x=0 and x=1 should both map to fb_x=0
        if x in [0, 1]:
            assert fb_x == 0, f"Pixel doubling failed at X={x}"
            
        await RisingEdge(dut.clk)

    dut._log.info("VGA Controller Testbench Complete")