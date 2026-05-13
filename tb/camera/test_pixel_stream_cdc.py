"""cocotb test for pixel_stream_cdc: two async clocks, verify data crosses the CDC."""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer


async def reset_dut(dut):
    dut.src_rst.value = 1
    dut.dst_rst.value = 1
    dut.src_valid.value = 0
    dut.src_frame_start.value = 0
    dut.src_line_start.value = 0
    dut.src_pixel.value = 0
    await Timer(100, units="ns")
    dut.src_rst.value = 0
    dut.dst_rst.value = 0
    await Timer(50, units="ns")


@cocotb.test()
async def test_pixel_crosses_cdc(dut):
    """single pixel with known data must appear on dst side within 10 dst cycles."""
    cocotb.start_soon(Clock(dut.src_clk, 42, units="ns").start())   # ~24 MHz
    cocotb.start_soon(Clock(dut.dst_clk, 10, units="ns").start())   # 100 MHz

    await reset_dut(dut)

    # drive one pixel on src side for exactly one src clock
    await RisingEdge(dut.src_clk)
    dut.src_valid.value = 1
    dut.src_pixel.value = 0xAB
    dut.src_frame_start.value = 1
    dut.src_line_start.value = 1
    await RisingEdge(dut.src_clk)
    dut.src_valid.value = 0
    dut.src_frame_start.value = 0
    dut.src_line_start.value = 0

    # poll dst_valid for up to 20 dst cycles
    for _ in range(20):
        await RisingEdge(dut.dst_clk)
        if dut.dst_valid.value == 1:
            break
    else:
        assert False, "dst_valid never asserted after 20 dst clk cycles"

    assert dut.dst_pixel.value == 0xAB,       f"pixel mismatch: {dut.dst_pixel.value}"
    assert dut.dst_frame_start.value == 1,    "frame_start not set"
    assert dut.dst_line_start.value == 1,     "line_start not set"


@cocotb.test()
async def test_dst_valid_is_single_cycle(dut):
    """dst_valid must be a one-cycle pulse, not held."""
    cocotb.start_soon(Clock(dut.src_clk, 42, units="ns").start())
    cocotb.start_soon(Clock(dut.dst_clk, 10, units="ns").start())

    await reset_dut(dut)

    await RisingEdge(dut.src_clk)
    dut.src_valid.value = 1
    dut.src_pixel.value = 0x55
    await RisingEdge(dut.src_clk)
    dut.src_valid.value = 0

    # find the pulse
    for _ in range(20):
        await RisingEdge(dut.dst_clk)
        if dut.dst_valid.value == 1:
            break
    else:
        assert False, "dst_valid never asserted"

    # next cycle must deassert
    await RisingEdge(dut.dst_clk)
    assert dut.dst_valid.value == 0, "dst_valid stayed high for more than one cycle"


@cocotb.test()
async def test_multiple_pixels_in_sequence(dut):
    """send 8 pixels back-to-back (one per src clk); all must arrive on dst."""
    cocotb.start_soon(Clock(dut.src_clk, 42, units="ns").start())
    cocotb.start_soon(Clock(dut.dst_clk, 10, units="ns").start())

    await reset_dut(dut)

    expected = [0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88]
    received = []

    # send all pixels
    for val in expected:
        await RisingEdge(dut.src_clk)
        dut.src_valid.value = 1
        dut.src_pixel.value = val
        await RisingEdge(dut.src_clk)
        dut.src_valid.value = 0

    # collect on dst side (generous timeout: 8 * 20 dst cycles)
    for _ in range(8 * 20):
        await RisingEdge(dut.dst_clk)
        if dut.dst_valid.value == 1:
            received.append(int(dut.dst_pixel.value))
        if len(received) == len(expected):
            break

    assert received == expected, f"received {received} expected {expected}"


@cocotb.test()
async def test_no_spurious_valid_at_reset(dut):
    """dst_valid must stay low for 30 dst cycles after reset with no src traffic."""
    cocotb.start_soon(Clock(dut.src_clk, 42, units="ns").start())
    cocotb.start_soon(Clock(dut.dst_clk, 10, units="ns").start())

    await reset_dut(dut)

    for _ in range(30):
        await RisingEdge(dut.dst_clk)
        assert dut.dst_valid.value == 0, "spurious dst_valid after reset"
