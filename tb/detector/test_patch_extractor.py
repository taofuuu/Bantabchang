"""Cocotb test for rtl/patch_extractor.v.

Ingests a deterministic 160x120 frame into frame_buffer, then asks
patch_extractor to pull a 24x24 region at several test corners. Verifies the
input act_buffer ends up with the exact int8 representation expected by
IntegerFaceCNN's input shaping (uint8 ^ 0x80, equivalent to uint8 - 128).

Run with:
  cd tb && make TEST=patch_extractor
"""
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer


FRAME_W = 160
FRAME_H = 120
FRAME_PIXELS = FRAME_W * FRAME_H
PATCH = 24


def uint8_to_int8(p: int) -> int:
    v = p ^ 0x80
    return v - 256 if v >= 128 else v


async def _reset(dut):
    dut.rst.value = 1
    dut.pixel_valid.value = 0
    dut.frame_start.value = 0
    dut.line_start.value = 0
    dut.pixel.value = 0
    dut.start.value = 0
    dut.patch_x.value = 0
    dut.patch_y.value = 0
    dut.ab_r_addr.value = 0
    for _ in range(2):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)


async def _ingest_frame(dut, pixels: list[int]) -> None:
    """Stream pixels into the frame_buffer using the agreed handshake."""
    for i, p in enumerate(pixels):
        x = i % FRAME_W
        dut.pixel_valid.value = 1
        dut.frame_start.value = 1 if i == 0 else 0
        dut.line_start.value = 1 if x == 0 else 0
        dut.pixel.value = p
        await RisingEdge(dut.clk)
    dut.pixel_valid.value = 0
    dut.frame_start.value = 0
    dut.line_start.value = 0
    await RisingEdge(dut.clk)


async def _extract_patch_and_check(dut, frame: list[int], px: int, py: int) -> None:
    """Trigger patch_extractor, wait for done, then read back the act_buffer
    and verify every entry equals the expected int8 conversion."""
    dut.patch_x.value = px
    dut.patch_y.value = py
    dut.start.value = 1
    await RisingEdge(dut.clk)
    dut.start.value = 0

    # Wait for done. Cap the wait so a stuck FSM doesn't hang forever.
    for _ in range(2000):
        await RisingEdge(dut.clk)
        await Timer(1, unit="ps")
        if int(dut.pe_done.value) == 1:
            break
    else:
        assert False, "patch_extractor.done never asserted"

    # Read back all 576 bytes.
    fail_count = 0
    first_fails = []
    for ky in range(PATCH):
        for kx in range(PATCH):
            ab_addr = ky * PATCH + kx
            dut.ab_r_addr.value = ab_addr
            await RisingEdge(dut.clk)
            await Timer(1, unit="ps")
            rtl = dut.ab_r_data.value.to_signed()
            fb_idx = (py + ky) * FRAME_W + (px + kx)
            ref = uint8_to_int8(frame[fb_idx])
            if rtl != ref:
                fail_count += 1
                if len(first_fails) < 5:
                    first_fails.append((kx, ky, rtl, ref))

    if fail_count > 0:
        for kx, ky, rtl, ref in first_fails:
            dut._log.error(f"patch=(px={px},py={py}) (kx={kx},ky={ky}): rtl={rtl} ref={ref}")
        assert False, f"{fail_count}/576 mismatches at (px={px}, py={py})"

    dut._log.info(f"patch (px={px}, py={py}): all 576 entries match int8(frame[..] - 128)")


@cocotb.test()
async def extract_known_patches(dut):
    """Ingest a frame, then extract several patches at different corners."""
    rng = random.Random(0)
    frame = [rng.randint(0, 255) for _ in range(FRAME_PIXELS)]

    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await _reset(dut)
    await _ingest_frame(dut, frame)

    # Test several corners covering edges and a typical mid-frame position.
    corners = [
        (0, 0),                                # top-left
        (FRAME_W - PATCH, 0),                  # top-right (px=136)
        (0, FRAME_H - PATCH),                  # bottom-left (py=96)
        (FRAME_W - PATCH, FRAME_H - PATCH),    # bottom-right (px=136, py=96)
        (96, 48),                              # the corner that fired in test_image.py
        (40, 60),                              # arbitrary middle
    ]
    for px, py in corners:
        await _extract_patch_and_check(dut, frame, px, py)
