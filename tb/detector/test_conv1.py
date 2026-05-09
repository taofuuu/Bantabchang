"""The big bit-exact gate: conv_layer.v (configured as conv1) must produce
byte-for-byte the same output as IntegerFaceCNN's conv1, across all 50 test
patches in data/golden/.

Pre-loads the 24x24 input patch into the input act_buffer, runs conv_layer,
and reads back the 968-byte (8 channels x 11x11) output, comparing every byte
to data/golden/conv1_act.hex.

Any single mismatch fails the test with the patch index and the (oc, oy, ox)
of the offending output. Any byte that matches across 50 patches × 968 outputs
= 48,400 individual checks gives strong confidence the conv engine is correct.

Run with:
  cd tb && make TEST=conv1
"""
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer


PROJ_ROOT = Path(__file__).resolve().parents[2]
GOLDEN_DIR = PROJ_ROOT / "data" / "golden"

N_TEST = 50
INPUT_PER_PATCH  = 24 * 24      # 576
CONV1_PER_PATCH  = 8 * 11 * 11  # 968


def parse_int_hex(path: Path, width: int) -> list[int]:
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
async def conv1_matches_golden(dut):
    """For all 50 patches, RTL conv1 output must equal Python reference output."""
    inputs = parse_int_hex(GOLDEN_DIR / "inputs.hex", 8)
    conv1  = parse_int_hex(GOLDEN_DIR / "conv1_act.hex", 8)
    assert len(inputs) == N_TEST * INPUT_PER_PATCH
    assert len(conv1)  == N_TEST * CONV1_PER_PATCH

    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())

    # global reset
    dut.rst.value = 1
    dut.start.value = 0
    dut.ab_in_we.value = 0
    dut.ab_in_w_addr.value = 0
    dut.ab_in_w_data.value = 0
    dut.ab_out_r_addr.value = 0
    for _ in range(2):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)

    total_checks = 0
    total_mismatches = 0

    for patch_idx in range(N_TEST):
        # 1. Preload input act_buffer with this patch's int8 inputs.
        in_base = patch_idx * INPUT_PER_PATCH
        for i in range(INPUT_PER_PATCH):
            dut.ab_in_we.value = 1
            dut.ab_in_w_addr.value = i
            dut.ab_in_w_data.value = inputs[in_base + i]
            await RisingEdge(dut.clk)
        dut.ab_in_we.value = 0
        await RisingEdge(dut.clk)  # let the last write retire

        # 2. Trigger conv_layer.
        dut.start.value = 1
        await RisingEdge(dut.clk)
        dut.start.value = 0

        # 3. Wait for done. Per-output ~21 cycles * 968 outputs ≈ 20,330.
        # Cap at 30,000 with margin.
        for _ in range(30000):
            await RisingEdge(dut.clk)
            await Timer(1, unit="ps")
            if int(dut.done.value) == 1:
                break
        else:
            assert False, f"conv1.done never asserted for patch {patch_idx}"

        # 4. Read every output byte.
        out_base = patch_idx * CONV1_PER_PATCH
        first_fails = []
        for a in range(CONV1_PER_PATCH):
            dut.ab_out_r_addr.value = a
            await RisingEdge(dut.clk)
            await Timer(1, unit="ps")
            rtl = dut.ab_out_r_data.value.to_signed()
            ref = conv1[out_base + a]
            total_checks += 1
            if rtl != ref:
                total_mismatches += 1
                if len(first_fails) < 3:
                    # decode address back to (oc, oy, ox)
                    oc = a // (11 * 11)
                    oy = (a // 11) % 11
                    ox = a % 11
                    first_fails.append((a, oc, oy, ox, rtl, ref))

        if first_fails:
            for a, oc, oy, ox, rtl, ref in first_fails:
                dut._log.error(
                    f"patch {patch_idx} addr={a} (oc={oc},oy={oy},ox={ox}): "
                    f"rtl={rtl} ref={ref} diff={rtl-ref:+d}"
                )
            assert False, f"patch {patch_idx}: {len(first_fails)} mismatches in conv1 output"

        if patch_idx % 10 == 0:
            dut._log.info(f"patch {patch_idx:2d}/50: 968 outputs match")

    dut._log.info(
        f"conv1 bit-exact: {total_checks} byte comparisons, "
        f"{total_mismatches} mismatches across {N_TEST} patches"
    )
