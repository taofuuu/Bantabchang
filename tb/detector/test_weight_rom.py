"""Cocotb test for rtl/weight_rom.v (via tb/wrap_weight_rom.v).

Verifies two things at once:
  1. $readmemh correctly parses the hex file produced by export_weights.py.
  2. The synchronous read (1-cycle latency) returns the right value.

The wrapper fixes MEM_FILE = weights/conv1_w.hex (72 int8 entries). The test
parses the same file in Python and compares every address byte-for-byte.

Run with:
  cd tb && make TEST=weight_rom
"""
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer


PROJ_ROOT = Path(__file__).resolve().parents[2]
HEX_FILE = PROJ_ROOT / "weights" / "conv1_w.hex"


def parse_int8_hex(path: Path) -> list[int]:
    """Parse a $readmemh-style file into signed int8 values."""
    out = []
    with open(path) as f:
        for line in f:
            line = line.split("//")[0].strip()
            if not line:
                continue
            v = int(line, 16) & 0xFF
            if v >= 0x80:
                v -= 0x100
            out.append(v)
    return out


@cocotb.test()
async def weight_rom_matches_hex_file(dut):
    """Read every address; compare to the Python parse of conv1_w.hex."""
    ref = parse_int8_hex(HEX_FILE)
    assert len(ref) == 72, f"expected 72 weights in {HEX_FILE}, got {len(ref)}"

    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())

    # Let initial blocks ($readmemh) finish before we start clocking.
    await Timer(1, unit="ns")

    fail_count = 0
    first_fails = []
    for a in range(72):
        dut.addr.value = a
        await RisingEdge(dut.clk)
        # Wait one delta cycle for the NBA region to settle so we read the
        # newly-registered data rather than the previous cycle's value.
        await Timer(1, unit="ps")
        raw = dut.data.value
        if not raw.is_resolvable:
            if len(first_fails) < 3:
                first_fails.append((a, str(raw), ref[a]))
            fail_count += 1
            continue
        rtl = raw.to_signed()
        if rtl != ref[a]:
            fail_count += 1
            if len(first_fails) < 5:
                first_fails.append((a, rtl, ref[a]))

    if fail_count > 0:
        for a, rtl, ref_val in first_fails:
            dut._log.error(f"addr={a}: rtl={rtl} ref={ref_val}")
        assert False, f"{fail_count}/72 mismatches"

    dut._log.info(f"weight_rom: all 72 entries match {HEX_FILE.name}")
