"""Cocotb test for rtl/requantize.v.

Exercises the combinational requantize unit against the same Python reference
function used in scripts/quantize.py. This is a smoke test for the cocotb +
iverilog toolchain AND a real bit-exact check of the requantize math.

Run with:
  cd tb && make TEST=requantize
"""
import os
import random

import cocotb
from cocotb.triggers import Timer


# ---- Python bit-exact reference (mirrors scripts/quantize.py) ----

def _arith_right_shift_round(x: int, n: int) -> int:
    if n <= 0:
        return x << (-n)
    bias = 1 << (n - 1)
    # Python `>>` on signed ints is arithmetic shift (floor toward -inf), which
    # matches Verilog `>>>` on signed values. With the rounding bias added, we
    # get the same round-half-up behavior as the RTL.
    return (x + bias) >> n


def _relu_clip_int8(x: int) -> int:
    return max(0, min(127, x))


def _reference(acc: int, shift: int) -> int:
    return _relu_clip_int8(_arith_right_shift_round(acc, shift))


# ---- The test ----

@cocotb.test()
async def requantize_matches_reference(dut):
    """For a wide range of acc values, RTL output must equal the Python ref."""
    shift = int(os.environ.get("SHIFT", "8"))
    rng = random.Random(0)

    # Realistic accumulator range: |max_acc| ≤ IN_CH*K*K * 127*127 + |bias|.
    # Worst case in this network is conv3 (IN_CH=16, K=3 → 144 MACs), giving
    # ~2.32M peak. Use ±2^24 (16.7M) to add comfortable margin without
    # provoking int32 overflow when the RTL adds the rounding bias.
    LIMIT = 1 << 24
    edge_cases = [
        -LIMIT, -(2**20), -65536, -32768, -1024, -128, -1, 0,
        1, 127, 128, 256, 1024, 32768, 65536, 2**20, LIMIT - 1,
    ]
    random_cases = [rng.randint(-LIMIT, LIMIT - 1) for _ in range(4000)]
    cases = edge_cases + random_cases

    fail_count = 0
    first_fails = []
    for acc_val in cases:
        dut.acc.value = acc_val
        await Timer(1, unit="ns")
        rtl_q = dut.q.value.to_signed()
        ref_q = _reference(acc_val, shift)
        if rtl_q != ref_q:
            fail_count += 1
            if len(first_fails) < 5:
                first_fails.append((acc_val, rtl_q, ref_q))

    if fail_count > 0:
        for acc_val, rtl_q, ref_q in first_fails:
            dut._log.error(f"SHIFT={shift} acc={acc_val}: rtl={rtl_q} ref={ref_q}")
        assert False, f"{fail_count}/{len(cases)} mismatches"

    dut._log.info(
        f"requantize SHIFT={shift}: all {len(cases)} cases match Python reference"
    )
