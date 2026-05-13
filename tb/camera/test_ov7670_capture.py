"""cocotb test for ov7670_capture: drive VSYNC/HREF/data, verify frame buffer writes and stream output."""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge


# native VGA dimensions (camera output)
NATIVE_W = 640
NATIVE_H = 480

# formula must match RTL: gray8 = chan_sum * 5, chan_sum = px_r + px_g + px_b
def rgb565_to_gray8(hi, lo):
    px_r = (hi >> 4) & 0xF
    px_g = ((hi & 0x07) << 1) | (lo >> 7)
    px_b = (lo >> 1) & 0xF
    chan_sum = px_r + px_g + px_b
    return (chan_sum * 5) & 0xFF

def rgb565_to_rgb444(hi, lo):
    px_r = (hi >> 4) & 0xF
    px_g = ((hi & 0x07) << 1) | (lo >> 7)
    px_b = (lo >> 1) & 0xF
    return (px_r << 8) | (px_g << 4) | px_b


async def send_frame(dut, rows, pixel_fn):
    """send `rows` lines of NATIVE_W pixels; pixel_fn(col, row) -> (hi_byte, lo_byte)."""
    # rising VSYNC = blanking start, resets state
    dut.vsync.value = 1
    dut.href.value = 0
    for _ in range(4):
        await RisingEdge(dut.pclk)
    dut.vsync.value = 0
    for _ in range(4):
        await RisingEdge(dut.pclk)

    for row in range(rows):
        dut.href.value = 1
        for col in range(NATIVE_W):
            hi, lo = pixel_fn(col, row)
            # hi byte
            dut.data_in.value = hi
            await RisingEdge(dut.pclk)
            # lo byte
            dut.data_in.value = lo
            await RisingEdge(dut.pclk)
        dut.href.value = 0
        # brief blanking between lines
        for _ in range(4):
            await RisingEdge(dut.pclk)


@cocotb.test()
async def test_reset_clears_outputs(dut):
    """all outputs must be 0 while reset is asserted."""
    cocotb.start_soon(Clock(dut.pclk, 42, units="ns").start())

    dut.reset.value = 1
    dut.vsync.value = 0
    dut.href.value = 0
    dut.data_in.value = 0

    for _ in range(10):
        await RisingEdge(dut.pclk)
        assert dut.frame_we.value == 0,    "frame_we non-zero during reset"
        assert dut.stream_valid.value == 0, "stream_valid non-zero during reset"

    dut.reset.value = 0


@cocotb.test()
async def test_frame_buffer_write_on_2x2_blocks(dut):
    """rows 0 and 2 (even rows) columns 0 and 2 produce frame buffer writes; odd do not."""
    cocotb.start_soon(Clock(dut.pclk, 42, units="ns").start())

    dut.reset.value = 1
    dut.vsync.value = 0
    dut.href.value = 0
    dut.data_in.value = 0
    for _ in range(8):
        await RisingEdge(dut.pclk)
    dut.reset.value = 0

    writes = []

    # only send 4 rows to keep test fast
    ROWS = 4
    FIXED_HI = 0xF8   # R=0xF, G=0x7
    FIXED_LO = 0x1E   # G lsb=0, B=0xF -> px_g=7, px_b=0xF

    async def collect():
        for _ in range(NATIVE_W * ROWS * 2 + 100):
            await RisingEdge(dut.pclk)
            if dut.frame_we.value == 1:
                writes.append(int(dut.frame_addr.value))

    cocotb.start_soon(collect())
    await send_frame(dut, ROWS, lambda c, r: (FIXED_HI, FIXED_LO))
    # wait a few more cycles for last write
    for _ in range(20):
        await RisingEdge(dut.pclk)

    # rows 0,2 cols 0,2,4,...638 -> 320 writes per 2 rows -> 320 total for 4 rows
    # keep_for_buffer: col[0]==0 && row[0]==0
    expected_count = (ROWS // 2) * (NATIVE_W // 2)   # 2 * 320 = 640
    assert len(writes) == expected_count, \
        f"expected {expected_count} writes, got {len(writes)}"

    # addresses must be monotonically increasing (0..639 for 4 rows)
    for i, addr in enumerate(writes):
        assert addr == i, f"write {i}: expected addr {i}, got {addr}"


@cocotb.test()
async def test_stream_on_4x4_blocks(dut):
    """stream_valid fires for every 4th col on every 4th row; pixel value matches gray8 formula."""
    cocotb.start_soon(Clock(dut.pclk, 42, units="ns").start())

    dut.reset.value = 1
    dut.vsync.value = 0
    dut.href.value = 0
    dut.data_in.value = 0
    for _ in range(8):
        await RisingEdge(dut.pclk)
    dut.reset.value = 0

    stream_pixels = []

    ROWS = 8
    HI, LO = 0x84, 0x42   # arbitrary non-zero RGB565 pair

    async def collect():
        for _ in range(NATIVE_W * ROWS * 2 + 100):
            await RisingEdge(dut.pclk)
            if dut.stream_valid.value == 1:
                stream_pixels.append(int(dut.stream_pixel.value))

    cocotb.start_soon(collect())
    await send_frame(dut, ROWS, lambda c, r: (HI, LO))
    for _ in range(20):
        await RisingEdge(dut.pclk)

    # keep_for_stream: col[1:0]==0 && row[1:0]==0
    expected_count = (ROWS // 4) * (NATIVE_W // 4)   # 2 * 160 = 320
    assert len(stream_pixels) == expected_count, \
        f"expected {expected_count} stream events, got {len(stream_pixels)}"

    expected_gray = rgb565_to_gray8(HI, LO)
    for i, px in enumerate(stream_pixels):
        assert px == expected_gray, \
            f"stream pixel {i}: expected {expected_gray:#04x}, got {px:#04x}"


@cocotb.test()
async def test_frame_start_and_line_start_flags(dut):
    """stream_frame_start must fire only on first pixel; stream_line_start on col=0 of each row."""
    cocotb.start_soon(Clock(dut.pclk, 42, units="ns").start())

    dut.reset.value = 1
    dut.vsync.value = 0
    dut.href.value = 0
    dut.data_in.value = 0
    for _ in range(8):
        await RisingEdge(dut.pclk)
    dut.reset.value = 0

    frame_starts = []
    line_starts  = []

    ROWS = 8

    async def collect():
        for _ in range(NATIVE_W * ROWS * 2 + 100):
            await RisingEdge(dut.pclk)
            if dut.stream_valid.value == 1:
                if dut.stream_frame_start.value == 1:
                    frame_starts.append(1)
                if dut.stream_line_start.value == 1:
                    line_starts.append(1)

    cocotb.start_soon(collect())
    await send_frame(dut, ROWS, lambda c, r: (0x42, 0x18))
    for _ in range(20):
        await RisingEdge(dut.pclk)

    assert len(frame_starts) == 1, f"expected 1 frame_start, got {len(frame_starts)}"
    # one line_start per stream row (every 4th native row)
    expected_lines = ROWS // 4
    assert len(line_starts) == expected_lines, \
        f"expected {expected_lines} line_starts, got {len(line_starts)}"
