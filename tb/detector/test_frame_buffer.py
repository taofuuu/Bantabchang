"""Cocotb test for rtl/frame_buffer.v.

Streams a synthetic 160x120 frame through the handshake interface, then reads
back every byte and verifies it. Also checks that frame_done pulses on the
cycle the last pixel is written.

Run with:
  cd tb && make TEST=frame_buffer
"""
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer


FRAME_W = 160
FRAME_H = 120
FRAME_PIXELS = FRAME_W * FRAME_H


async def _reset(dut):
    dut.rst.value = 1
    dut.pixel_valid.value = 0
    dut.frame_start.value = 0
    dut.line_start.value = 0
    dut.pixel.value = 0
    dut.r_addr.value = 0
    for _ in range(2):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)


@cocotb.test()
async def stream_frame_then_read_back(dut):
    """Write a full 160x120 frame, then read every byte and check."""
    rng = random.Random(0)
    pixels = [rng.randint(0, 255) for _ in range(FRAME_PIXELS)]

    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await _reset(dut)

    # Stream the frame with proper handshake.
    frame_done_seen = False
    for i, p in enumerate(pixels):
        x = i % FRAME_W
        y = i // FRAME_W
        dut.pixel_valid.value = 1
        dut.frame_start.value = 1 if i == 0 else 0
        dut.line_start.value = 1 if x == 0 else 0
        dut.pixel.value = p
        await RisingEdge(dut.clk)
        # frame_done should pulse on the cycle the 19200th pixel is written
        await Timer(1, unit="ps")
        if int(dut.frame_done.value) == 1:
            if i != FRAME_PIXELS - 1:
                assert False, f"frame_done pulsed early at pixel {i}"
            frame_done_seen = True

    dut.pixel_valid.value = 0
    dut.frame_start.value = 0
    dut.line_start.value = 0

    assert frame_done_seen, "frame_done never pulsed"

    # Let the last write retire before we start reading.
    await RisingEdge(dut.clk)

    # Read back every address and verify.
    fail_count = 0
    first_fails = []
    for a in range(FRAME_PIXELS):
        dut.r_addr.value = a
        await RisingEdge(dut.clk)
        await Timer(1, unit="ps")
        rtl = int(dut.r_data.value)
        if rtl != pixels[a]:
            fail_count += 1
            if len(first_fails) < 5:
                first_fails.append((a, rtl, pixels[a]))

    if fail_count > 0:
        for a, rtl, ref in first_fails:
            x, y = a % FRAME_W, a // FRAME_W
            dut._log.error(f"addr={a} (x={x},y={y}): rtl={rtl} expected={ref}")
        assert False, f"{fail_count}/{FRAME_PIXELS} mismatches"

    dut._log.info(f"frame_buffer: {FRAME_PIXELS} pixels round-tripped, frame_done pulsed correctly")


@cocotb.test()
async def frame_start_mid_frame_restarts(dut):
    """If frame_start arrives mid-frame, the next pixel should write to addr 0."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await _reset(dut)

    # Stream 100 pixels of garbage, then issue a fresh frame_start at pixel 0.
    for i in range(100):
        dut.pixel_valid.value = 1
        dut.frame_start.value = 1 if i == 0 else 0
        dut.line_start.value = 1 if (i % FRAME_W) == 0 else 0
        dut.pixel.value = 0xAA
        await RisingEdge(dut.clk)

    # Now restart — frame_start with a known pixel value 0x55.
    dut.pixel_valid.value = 1
    dut.frame_start.value = 1
    dut.line_start.value = 1
    dut.pixel.value = 0x55
    await RisingEdge(dut.clk)

    dut.pixel_valid.value = 0
    dut.frame_start.value = 0
    dut.line_start.value = 0

    # Read addr 0 and confirm it's 0x55, not 0xAA.
    await RisingEdge(dut.clk)
    dut.r_addr.value = 0
    await RisingEdge(dut.clk)
    await Timer(1, unit="ps")
    rtl = int(dut.r_data.value)
    assert rtl == 0x55, f"after mid-frame restart, addr 0 should be 0x55, got 0x{rtl:02x}"
    dut._log.info("frame_buffer: mid-frame frame_start correctly restarts at addr 0")
