"""cocotb test for ov7670_config: verify config_done asserts and SIOC toggles.
uses wrap_ov7670_config which overrides PHASE_TICKS=4 so the test runs fast."""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

# 36 commands * (24 bits * 4 phases + start/stop overhead) * 4 ticks/phase
# generously upper-bound: 36 * 40 * 4 * 4 = ~23k cycles; use 50k to be safe
MAX_WAIT_CYCLES = 50_000


@cocotb.test()
async def test_config_done_asserts(dut):
    """config_done must go high within MAX_WAIT_CYCLES after reset is released."""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())

    dut.reset.value = 1
    await Timer(100, units="ns")
    dut.reset.value = 0

    for cycle in range(MAX_WAIT_CYCLES):
        await RisingEdge(dut.clk)
        if dut.config_done.value == 1:
            cocotb.log.info(f"config_done asserted after {cycle} cycles")
            break
    else:
        assert False, f"config_done never asserted within {MAX_WAIT_CYCLES} cycles"


@cocotb.test()
async def test_sioc_toggles_during_config(dut):
    """sioc must toggle at least once before config_done (proves clock is being driven)."""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())

    dut.reset.value = 1
    await Timer(100, units="ns")
    dut.reset.value = 0

    sioc_transitions = 0
    prev_sioc = 1

    for _ in range(MAX_WAIT_CYCLES):
        await RisingEdge(dut.clk)
        cur = int(dut.sioc.value)
        if cur != prev_sioc:
            sioc_transitions += 1
        prev_sioc = cur
        if dut.config_done.value == 1:
            break

    assert sioc_transitions > 0, "sioc never toggled — FSM did not start"


@cocotb.test()
async def test_sccb_busy_deasserts_at_done(dut):
    """sccb_busy must be 0 when config_done is 1."""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())

    dut.reset.value = 1
    await Timer(100, units="ns")
    dut.reset.value = 0

    for _ in range(MAX_WAIT_CYCLES):
        await RisingEdge(dut.clk)
        if dut.config_done.value == 1:
            break

    assert dut.sccb_busy.value == 0,    "sccb_busy should be 0 when config_done"
    assert dut.sccb_nak_seen.value == 0, "sccb_nak_seen should always be 0 (open-loop)"


@cocotb.test()
async def test_config_done_stays_high(dut):
    """config_done must remain high for at least 10 cycles once asserted."""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())

    dut.reset.value = 1
    await Timer(100, units="ns")
    dut.reset.value = 0

    for _ in range(MAX_WAIT_CYCLES):
        await RisingEdge(dut.clk)
        if dut.config_done.value == 1:
            break

    for i in range(10):
        await RisingEdge(dut.clk)
        assert dut.config_done.value == 1, f"config_done dropped after {i} cycles"
