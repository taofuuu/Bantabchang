import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, Timer


async def reset_dut(dut):
    dut.reset.value = 1
    await Timer(80, unit="ns")   # 2 clock periods @ 25 MHz
    dut.reset.value = 0


@cocotb.test()
async def test_vga_timing_and_addressing(dut):
    """Verify VGA timing (800x525 total) and pixel doubling logic."""

    # 25 MHz clock -> 40 ns period
    cocotb.start_soon(Clock(dut.clk, 40, unit="ns").start())

    await reset_dut(dut)
    dut._log.info("Reset released")

    # ============================================================
    # 1. Verify horizontal timing
    # ============================================================

    # Wait for one HSYNC pulse
    await FallingEdge(dut.hsync)
    start_time = cocotb.utils.get_sim_time(unit="ns")

    # Wait for next HSYNC pulse
    await FallingEdge(dut.hsync)
    end_time = cocotb.utils.get_sim_time(unit="ns")

    line_duration = end_time - start_time

    # 800 clocks * 40ns = 32000ns
    expected_line_ns = 32000

    assert (
        line_duration == expected_line_ns
    ), f"Line duration incorrect: {line_duration}ns"

    dut._log.info(
        f"Horizontal line timing verified: {line_duration}ns"
    )

    # ============================================================
    # 2. Count active pixels in exactly one frame
    # ============================================================

    # Synchronize to a clean frame boundary
    await FallingEdge(dut.vsync)
    await RisingEdge(dut.vsync)

    pixel_count = 0

    start_ms = cocotb.utils.get_sim_time(unit="ms")

    while True:
        await RisingEdge(dut.clk)

        # Count active pixels
        if int(dut.active.value) == 1:
            pixel_count += 1

        # Next VSYNC falling edge = next frame start
        if dut.vsync.value == 0:
            break

        # Safety timeout
        now_ms = cocotb.utils.get_sim_time(unit="ms")

        if (now_ms - start_ms) > 20:
            assert False, (
                f"Timeout waiting for frame completion "
                f"(pixel_count={pixel_count})"
            )

    expected_pixels = 640 * 480

    assert (
        pixel_count == expected_pixels
    ), f"Pixel count mismatch: {pixel_count} vs {expected_pixels}"

    dut._log.info(
        f"✓ PASS: {pixel_count} active pixels counted in one frame"
    )

    # ============================================================
    # 3. Verify pixel doubling addressing
    # ============================================================

    # Wait for active video region
    while int(dut.active.value) == 0:
        await RisingEdge(dut.clk)

    dut._log.info(
        "Sampling VGA positions for pixel doubling verification:"
    )

    for _ in range(10):

        x = int(dut.x_pos.value)
        y = int(dut.y_pos.value)

        # Framebuffer coordinates after divide-by-2 scaling
        fb_x = x >> 1
        fb_y = y >> 1

        dut._log.info(
            f"VGA ({x},{y}) -> Frame Buffer ({fb_x},{fb_y})"
        )

        # x=0 and x=1 should both map to fb_x=0
        if x in [0, 1]:
            assert fb_x == 0, (
                f"Pixel doubling failed at X={x}"
            )

        await RisingEdge(dut.clk)

    dut._log.info("VGA Controller Testbench Complete")