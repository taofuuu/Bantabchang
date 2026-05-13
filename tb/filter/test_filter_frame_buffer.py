import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

@cocotb.test()
async def test_dual_port_buffer(dut):
    """Write 256 entries via Port A and read back via Port B."""
    
    # Initialize clocks: 42ns period (~24MHz) and 40ns period (25MHz) [cite: 10, 11]
    cocotb.start_soon(Clock(dut.clka, 42, units="ns").start())
    cocotb.start_soon(Clock(dut.clkb, 40, units="ns").start())

    # Initialize signals
    dut.wea.value = 0
    dut.addra.value = 0
    dut.dina.value = 0
    dut.addrb.value = 0
    await Timer(100, units="ns")

    # --- Write Phase --- [cite: 22]
    for i in range(256):
        await RisingEdge(dut.clka)
        dut.addra.value = i
        dut.dina.value = i & 0xFFF # addr[11:0]
        dut.wea.value = 1
        await RisingEdge(dut.clka)
        dut.wea.value = 0

    # Wait for writes to settle [cite: 23]
    for _ in range(4):
        await RisingEdge(dut.clkb)

    # --- Read & Verify Phase --- [cite: 24, 25]
    for i in range(256):
        await RisingEdge(dut.clkb)
        dut.addrb.value = i
        await RisingEdge(dut.clkb) # Registered read delay [cite: 19]
        
        got = int(dut.doutb.value)
        expected = i & 0xFFF
        assert got == expected, f"Addr {i}: Expected {expected:03x}, got {got:03x}"

    # Spot-check high address [cite: 26, 27]
    await RisingEdge(dut.clka)
    dut.addra.value = 76799
    dut.dina.value = 0xABC
    dut.wea.value = 1
    await RisingEdge(dut.clka)
    dut.wea.value = 0
    
    for _ in range(4): await RisingEdge(dut.clkb)
    
    dut.addrb.value = 76799
    await RisingEdge(dut.clkb)
    assert int(dut.doutb.value) == 0xABC, "High address check failed"