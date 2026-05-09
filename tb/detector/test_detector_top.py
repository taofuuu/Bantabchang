"""Cocotb test for rtl/detector_top.v — full pipeline streaming test.

Loads data/test_input.jpg, downsamples to 160x120 grayscale, streams it into
detector_top using the agreed handshake, then waits for scan_done. The output
register file should match the Python reference (test_image.py at stride 16):

    face_valid = 1
    face_x     = 96
    face_y     = 48
    face_w     = 24
    face_h     = 24

Run with:
  cd tb && make TEST=detector_top
"""
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer


PROJ_ROOT = Path(__file__).resolve().parents[2]
# Pre-processed by `.venv/bin/python` (PIL + numpy aren't on the cocotb runner's
# Python). Generated via:  data/test_input.jpg -> grayscale -> 160x120 -> hex.
TEST_FRAME_HEX = PROJ_ROOT / "data" / "test_frame.hex"

FRAME_W = 160
FRAME_H = 120
FRAME_PIXELS = FRAME_W * FRAME_H

# Expected output (matches `python scripts/test_image.py --stride 16`)
EXPECTED_FACE_X = 96
EXPECTED_FACE_Y = 48
EXPECTED_FACE_W = 24
EXPECTED_FACE_H = 24


def load_test_frame() -> list[int]:
    out = []
    with open(TEST_FRAME_HEX) as f:
        for line in f:
            line = line.split("//")[0].strip()
            if not line:
                continue
            out.append(int(line, 16))
    return out


async def _reset(dut):
    dut.rst.value = 1
    dut.pixel_valid.value = 0
    dut.frame_start.value = 0
    dut.line_start.value = 0
    dut.pixel.value = 0
    for _ in range(2):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)


async def _stream_frame(dut, pixels: list[int]) -> None:
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


@cocotb.test()
async def detect_face_in_test_image(dut):
    """Stream a real frame; expect detector_top to converge on (96, 48)."""
    pixels = load_test_frame()
    assert len(pixels) == FRAME_PIXELS

    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await _reset(dut)
    await _stream_frame(dut, pixels)

    dut._log.info("frame streamed; waiting for scan_done...")

    # Wait for scan_done. Per-patch ~122K cycles * 63 patches = ~7.7M cycles.
    # Cap with margin at 12M.
    for cycles_waited in range(12_000_000):
        await RisingEdge(dut.clk)
        await Timer(1, unit="ps")
        if int(dut.scan_done.value) == 1:
            dut._log.info(f"scan_done at cycle {cycles_waited}")
            break
        if cycles_waited % 500_000 == 0 and cycles_waited > 0:
            dut._log.info(f"  ...still scanning at cycle {cycles_waited}")
    else:
        assert False, "scan_done never asserted within 12M cycles"

    # Sample the output register file.
    fv = int(dut.face_valid.value)
    fx = int(dut.face_x.value)
    fy = int(dut.face_y.value)
    fw = int(dut.face_w.value)
    fh = int(dut.face_h.value)

    dut._log.info(
        f"detector output: face_valid={fv} face_x={fx} face_y={fy} "
        f"face_w={fw} face_h={fh}"
    )

    assert fv == 1, f"expected face_valid=1, got {fv}"
    assert fx == EXPECTED_FACE_X, f"face_x: expected {EXPECTED_FACE_X}, got {fx}"
    assert fy == EXPECTED_FACE_Y, f"face_y: expected {EXPECTED_FACE_Y}, got {fy}"
    assert fw == EXPECTED_FACE_W, f"face_w: expected {EXPECTED_FACE_W}, got {fw}"
    assert fh == EXPECTED_FACE_H, f"face_h: expected {EXPECTED_FACE_H}, got {fh}"

    dut._log.info("detector_top: bit-exact match with Python stride-16 reference")
