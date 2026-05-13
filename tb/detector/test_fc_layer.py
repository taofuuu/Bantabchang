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
FC_OUT_LEN      = 5    # conf, x0, y0, w, h
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
    assert len(logits) == N_TEST * FC_OUT_LEN, (
        f"logits.hex has {len(logits)}; expected {N_TEST * FC_OUT_LEN}")

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
        for _ in range(1000): # Increased range for safety
            await RisingEdge(dut.clk)
            if int(dut.done.value) == 1:
                await RisingEdge(dut.clk) # <--- CRITICAL: Wait for final WB to settle
                break
        else:
            assert False, f"fc_layer.done never asserted for patch {patch_idx}"

        # 4. Sample all five FC outputs.
        rtl_out = (
            dut.out_conf.value.to_signed(),
            dut.out_x0.value.to_signed(),
            dut.out_y0.value.to_signed(),
            dut.out_w.value.to_signed(),
            dut.out_h.value.to_signed(),
        )
        base_ref = patch_idx * FC_OUT_LEN
        ref_out = tuple(logits[base_ref + i] for i in range(FC_OUT_LEN))

        if rtl_out != ref_out:
            diffs = tuple(r - g for r, g in zip(rtl_out, ref_out))
            dut._log.error(
                f"patch {patch_idx}: rtl={rtl_out}  ref={ref_out}  diff={diffs}"
            )
            assert False, f"patch {patch_idx} fc output mismatch"
        else:
            dut._log.info(
                f"patch {patch_idx:2d}: "
                f"conf={rtl_out[0]:+8d}  "
                f"x0={rtl_out[1]:+6d} y0={rtl_out[2]:+6d} "
                f"w={rtl_out[3]:+6d} h={rtl_out[4]:+6d}  match"
            )

    dut._log.info(f"fc_layer: bit-exact on {NUM_PATCHES_TO_TEST} patches")
