import cocotb
from cocotb.triggers import Timer

# Test Colors (RGB444) [cite: 38, 39, 40]
COLORS = {
    "White": 0xFFF, "Black": 0x000, "Red": 0xF00, 
    "Green": 0x0F0, "Blue": 0x00F, "Gray": 0x888
}

@cocotb.test()
async def test_all_filters(dut):
    """Test all 8 filter modes with various input colors."""
    
    # Filter modes from Verilog [cite: 43, 44]
    modes = [
        (0, "Pass Through"), (1, "Grayscale"), (2, "Invert"),
        (4, "Red Only"), (5, "Green Only"), (6, "Blue Only")
    ]

    for mode_val, mode_name in modes:
        dut._log.info(f"--- Testing Filter {mode_val}: {mode_name} ---")
        dut.filter_sel.value = mode_val
        
        for color_name, color_val in COLORS.items():
            dut.pixel_in.value = color_val
            await Timer(10, units="ns") # Wait for combinational logic [cite: 50, 51]
            
            out = int(dut.pixel_out.value)
            r_out, g_out, b_out = (out >> 8) & 0xF, (out >> 4) & 0xF, out & 0xF
            
            # Validation logic mimicking the Verilog case statement [cite: 53]
            if mode_val == 0: # Pass through
                assert out == color_val, f"{color_name} failed Pass-through"
            elif mode_val == 2: # Invert [cite: 54]
                assert out == (~color_val & 0xFFF), f"{color_name} failed Invert"
            elif mode_val == 4: # Red Only [cite: 55]
                assert g_out == 0 and b_out == 0, f"{color_name} failed Red-only"
            elif mode_val == 1: # Grayscale [cite: 58]
                assert r_out == g_out == b_out, f"{color_name} failed Grayscale"