"""Cocotb test for rtl/act_buffer.v.

Sanity check: write a known pattern (signed values covering the int8 range)
into all 576 entries, then read every entry back and verify byte-for-byte.

Run with:
  cd tb && make TEST=act_buffer
"""
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer


DEPTH = 576


@cocotb.test()
async def write_then_read_full_buffer(dut):
    """Write all 576 entries, then read them all back."""
    rng = random.Random(0)
    pattern = [rng.randint(-128, 127) for _ in range(DEPTH)]

    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())

    # idle a cycle
    dut.we.value = 0
    dut.w_addr.value = 0
    dut.w_data.value = 0
    dut.r_addr.value = 0
    await RisingEdge(dut.clk)

    # write phase
    for a in range(DEPTH):
        dut.we.value = 1
        dut.w_addr.value = a
        dut.w_data.value = pattern[a]
        await RisingEdge(dut.clk)
    dut.we.value = 0

    # one cycle of dead time so the last write retires before we start reads
    await RisingEdge(dut.clk)

    # read phase
    fail_count = 0
    first_fails = []
    for a in range(DEPTH):
        dut.r_addr.value = a
        await RisingEdge(dut.clk)
        await Timer(1, unit="ps")
        rtl = dut.r_data.value.to_signed()
        if rtl != pattern[a]:
            fail_count += 1
            if len(first_fails) < 5:
                first_fails.append((a, rtl, pattern[a]))

    if fail_count > 0:
        for a, rtl, ref in first_fails:
            dut._log.error(f"addr={a}: rtl={rtl} expected={ref}")
        assert False, f"{fail_count}/{DEPTH} mismatches"

    dut._log.info(f"act_buffer: all {DEPTH} entries written and read back correctly")
