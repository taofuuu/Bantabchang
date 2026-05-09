"""Cocotb test for rtl/fc_layer.v.

Loads real conv3 activations from data/golden/conv3_act.hex (per-patch 144
int8 values), preloads them into the activation buffer via the wrapper, runs
fc_layer with weights from weights/fc_w.hex + weights/fc_b.hex, and checks
that the resulting (logit0, logit1) match data/golden/logits.hex bit-exactly.

This is the first end-to-end bit-exact gate against the Python reference: any
mismatch means the FC compute, the weight/bias loading, or the act_buffer
preload is broken.

Run with:
  cd tb && make TEST=fc_layer
"""
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer


PROJ_ROOT = Path(__file__).resolve().parents[2]
GOLDEN_DIR = PROJ_ROOT / "data" / "golden"

N_TEST = 50            # matches dump_golden.py --n-test 50
CONV3_PER_PATCH = 144  # 16 * 3 * 3
NUM_PATCHES_TO_TEST = 5  # subset; the conv_layer integration test will hit all 50


def parse_int_hex(path: Path, width: int) -> list[int]:
    """Parse a $readmemh file. Returns signed values."""
    out = []
    with open(path) as f:
        for line in f:
            line = line.split("//")[0].strip()
            if not line:
                continue
            v = int(line, 16) & ((1 << width) - 1)
            if v >= (1 << (width - 1)):
                v -= (1 << width)
            out.append(v)
    return out


@cocotb.test()
async def fc_logits_match_golden(dut):
    """For several patches, RTL fc must produce the same int32 logits as the
    Python IntegerFaceCNN reference."""
    conv3 = parse_int_hex(GOLDEN_DIR / "conv3_act.hex", 8)
    logits = parse_int_hex(GOLDEN_DIR / "logits.hex", 32)
    assert len(conv3) == N_TEST * CONV3_PER_PATCH, (
        f"conv3_act.hex has {len(conv3)} entries; expected {N_TEST * CONV3_PER_PATCH}")
    assert len(logits) == N_TEST * 2, f"logits.hex has {len(logits)}; expected {N_TEST * 2}"

    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())

    # global reset
    dut.rst.value = 1
    dut.start.value = 0
    dut.ab_we.value = 0
    dut.ab_w_addr.value = 0
    dut.ab_w_data.value = 0
    for _ in range(2):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)

    for patch_idx in range(NUM_PATCHES_TO_TEST):
        # 1. Preload conv3 activations for this patch.
        base = patch_idx * CONV3_PER_PATCH
        for i in range(CONV3_PER_PATCH):
            dut.ab_we.value = 1
            dut.ab_w_addr.value = i
            dut.ab_w_data.value = conv3[base + i]
            await RisingEdge(dut.clk)
        dut.ab_we.value = 0
        # let the last write retire
        await RisingEdge(dut.clk)

        # 2. Trigger fc_layer.
        dut.start.value = 1
        await RisingEdge(dut.clk)
        dut.start.value = 0

        # 3. Wait for done (cap at 600 cycles — fc takes ~290).
        for _ in range(600):
            await RisingEdge(dut.clk)
            await Timer(1, unit="ps")
            if int(dut.done.value) == 1:
                break
        else:
            assert False, f"fc_layer.done never asserted for patch {patch_idx}"

        # 4. Sample logits.
        rtl_l0 = dut.logit0.value.to_signed()
        rtl_l1 = dut.logit1.value.to_signed()
        ref_l0 = logits[patch_idx * 2 + 0]
        ref_l1 = logits[patch_idx * 2 + 1]

        if (rtl_l0, rtl_l1) != (ref_l0, ref_l1):
            dut._log.error(
                f"patch {patch_idx}: rtl=({rtl_l0}, {rtl_l1}) "
                f"ref=({ref_l0}, {ref_l1})  "
                f"diff=({rtl_l0 - ref_l0:+d}, {rtl_l1 - ref_l1:+d})"
            )
            assert False, f"patch {patch_idx} logit mismatch"
        else:
            dut._log.info(
                f"patch {patch_idx:2d}: logits=({rtl_l0:+8d}, {rtl_l1:+8d}) "
                f"score={rtl_l1-rtl_l0:+d}  match"
            )

    dut._log.info(f"fc_layer: bit-exact on {NUM_PATCHES_TO_TEST} patches")
