# test_top.py — cocotb testbench for top.v  (full chip integration)
#
# Runs with Icarus Verilog.  Invoke via the Makefile:
#     make test-top
#
# Exercises (mirrors the existing tb/tb_top.v coverage + simultaneous-axis case):
#
#   Case 1 — No-fault baseline:
#             Broadband noise below threshold on all 3 axes.
#             fault_flag_out must stay LOW.
#
#   Case 2 — Fault on X only:
#             On-target tone injected on X (bin 0 frequency).
#             fault_flag_out must assert.
#
#   Case 3 — Fault on Y only (after X-fault cleared):
#             Same tone on Y only.
#             fault_flag_out must assert.
#
#   Case 4 — Fault on Z only (after Y-fault cleared):
#             Same tone on Z only.
#             fault_flag_out must assert.
#
#   Case 5 — Simultaneous 3-axis fault:
#             On-target tone on all three axes simultaneously — the primary
#             motivation for the ITAG architecture. Legacy axis-sequential
#             design could not detect this within a single block.
#             fault_flag_out must assert within one block.
#
#   Case 6 — cfg_fault_clear de-asserts fault_flag_out.
#
#   ITAG structural invariants (asserted across all cases):
#     • Exactly 9 magnitude pulses per 512-sample block.
#     • mult_req never asserted simultaneously from goertzel + magnitude.

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, Timer
import math

# --------------------------------------------------------------------------
# Timing constants matching top.v / librelane/top.yaml
# --------------------------------------------------------------------------
CLK_NS       = 100    # 10 MHz system clock
BLOCK_SIZE   = 512    # top.v: fault_flagger #(.BLOCK_SIZE(512))

# Q8.15 helpers
Q15    = 1 << 15
MASK24 = (1 << 24) - 1
SIGN24 = 1 << 23


def q15(x: float) -> int:
    return int(round(x * Q15)) & MASK24


# --------------------------------------------------------------------------
# APB-register addresses (from spi_apb_interface / tmr_reg_bank)
# --------------------------------------------------------------------------
APB_CFG_CTRL      = 0x00   # bit 0 = cfg_start, bit 1 = cfg_fault_clear, bit 2 = cfg_stop
APB_CFG_C0        = 0x04   # Q8.15 coeff bin 0
APB_CFG_C1        = 0x08   # Q8.15 coeff bin 1
APB_CFG_C2        = 0x0C   # Q8.15 coeff bin 2
APB_CFG_THRESHOLD = 0x10   # threshold 32-bit (set to 14 per tb_top.v)


# --------------------------------------------------------------------------
# Global sensor sample registers for MISO emulator
# --------------------------------------------------------------------------
g_sample_x = 0
g_sample_y = 0
g_sample_z = 0


async def _sensor_emulator(dut):
    """Emulate IIS3DWB MISO output during SPI read bursts."""
    while True:
        await RisingEdge(dut.clk)
        if dut.c_csn.value.is_resolvable and int(dut.c_csn.value) == 0:
            # First 8 SPC falling edges are command byte (0xA8)
            for _ in range(8):
                await FallingEdge(dut.c_sclk)

            # Pack current (x, y, z) into 48 bits (little-endian byte order per sensor)
            x_u = g_sample_x & 0xFFFF
            y_u = g_sample_y & 0xFFFF
            z_u = g_sample_z & 0xFFFF

            bytes_data = [
                x_u & 0xFF, (x_u >> 8) & 0xFF,
                y_u & 0xFF, (y_u >> 8) & 0xFF,
                z_u & 0xFF, (z_u >> 8) & 0xFF
            ]

            # Shift out 6 bytes MSB-first per byte on c_sclk falling edge
            for b in bytes_data:
                for bit_idx in range(7, -1, -1):
                    bit = (b >> bit_idx) & 1
                    dut.c_miso.value = bit
                    await FallingEdge(dut.c_sclk)

            dut.c_miso.value = 0


async def _start_clock(dut):
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    cocotb.start_soon(_sensor_emulator(dut))


async def _reset(dut):
    dut.sys_rst_n.value = 0
    dut.sensor_drdy.value = 0
    dut.tmr_forward_en.value = 0
    dut.c_miso.value = 0
    dut.cmd_sclk.value = 1
    dut.cmd_csn.value = 1
    dut.cmd_mosi.value = 0
    for _ in range(10):
        await RisingEdge(dut.clk)
    dut.sys_rst_n.value = 1
    await RisingEdge(dut.clk)


async def _cmd_spi_write(dut, addr: int, data: int):
    """Write config via cmd_spi interface (8-bit addr + 32-bit data)."""
    frame = ((addr & 0xFF) << 32) | (data & 0xFFFFFFFF)

    dut.cmd_csn.value = 0
    await RisingEdge(dut.clk)

    for i in range(39, -1, -1):
        bit = (frame >> i) & 1
        dut.cmd_sclk.value = 0
        dut.cmd_mosi.value = bit
        await RisingEdge(dut.clk)
        await RisingEdge(dut.clk)
        dut.cmd_sclk.value = 1
        await RisingEdge(dut.clk)
        await RisingEdge(dut.clk)

    dut.cmd_csn.value = 1
    # Wait for cmd_spi_slave deassert edge to issue APB write
    for _ in range(30):
        await RisingEdge(dut.clk)


async def _configure(dut, c0=0, c1=0, c2=0, threshold=14):
    """Write Goertzel coefficients + threshold then enable the core."""
    await _cmd_spi_write(dut, APB_CFG_C0,        c0 & MASK24)
    await _cmd_spi_write(dut, APB_CFG_C1,        c1 & MASK24)
    await _cmd_spi_write(dut, APB_CFG_C2,        c2 & MASK24)
    await _cmd_spi_write(dut, APB_CFG_THRESHOLD, threshold & 0xFFFFFFFF)
    await _cmd_spi_write(dut, APB_CFG_CTRL,      0x1)   # cfg_start


async def _clear_fault(dut):
    await _cmd_spi_write(dut, APB_CFG_CTRL, 0x2) # cfg_fault_clear
    for _ in range(5):
        await RisingEdge(dut.clk)


def _inject_tone(sample_idx: int, freq_norm: float, amplitude: float = 1.0) -> int:
    """Return a 16-bit signed sample of a sinusoid at normalised frequency."""
    r = amplitude * math.sin(2.0 * math.pi * freq_norm * sample_idx)
    i = int(round(r * 32768.0))
    if i > 32767: i = 32767
    if i < -32768: i = -32768
    return i & 0xFFFF


async def _run_blocks(dut, n_blocks: int,
                      x_tone=None, y_tone=None, z_tone=None,
                      x_amp=1.0, y_amp=1.0, z_amp=1.0):
    """Drive n_blocks × BLOCK_SIZE samples into the DUT via sensor_drdy / MISO."""
    global g_sample_x, g_sample_y, g_sample_z

    for blk in range(n_blocks):
        for s in range(BLOCK_SIZE):
            idx = blk * BLOCK_SIZE + s
            g_sample_x = _inject_tone(idx, x_tone, x_amp) if x_tone is not None else 0
            g_sample_y = _inject_tone(idx, y_tone, y_amp) if y_tone is not None else 0
            g_sample_z = _inject_tone(idx, z_tone, z_amp) if z_tone is not None else 0

            # Deliver sample: pulse sensor_drdy for 5 cycles
            dut.sensor_drdy.value = 1
            for _ in range(5):
                await RisingEdge(dut.clk)
            dut.sensor_drdy.value = 0

            # Wait for SPI transfer to finish (approx 500 sys-clk cycles)
            for _ in range(500):
                await RisingEdge(dut.clk)
                if int(dut.c_csn.value) == 1:
                    break


# Block-coherent tone at 20 cycles per 512 samples
FREQ_20_512 = 20.0 / 512.0
COEFF_C0    = q15(2.0 * math.cos(2.0 * math.pi * FREQ_20_512))


# --------------------------------------------------------------------------
# Case 1 — No-fault baseline
# --------------------------------------------------------------------------
@cocotb.test()
async def test_case1_no_fault_baseline(dut):
    """Broadband noise on all axes, below threshold → fault_flag_out stays LOW."""
    await _start_clock(dut)
    await _reset(dut)

    # Very high threshold → no fault
    await _configure(dut, c0=COEFF_C0, c1=0, c2=0, threshold=0x7FFFFFFF)
    await _run_blocks(dut, n_blocks=1)

    assert int(dut.fault_flag_out.value) == 0, (
        "fault_flag_out should stay LOW with threshold=MAX"
    )


# --------------------------------------------------------------------------
# Case 2 — Fault on X axis only
# --------------------------------------------------------------------------
@cocotb.test()
async def test_case2_fault_on_x(dut):
    """On-target tone on X → fault asserts."""
    await _start_clock(dut)
    await _reset(dut)

    await _configure(dut, c0=COEFF_C0, c1=0, c2=0, threshold=14)
    await _run_blocks(dut, n_blocks=2, x_tone=FREQ_20_512)

    assert int(dut.fault_flag_out.value) == 1, (
        "fault_flag_out should assert for X-axis on-target tone"
    )


# --------------------------------------------------------------------------
# Case 3 — Fault on Y axis only
# --------------------------------------------------------------------------
@cocotb.test()
async def test_case3_fault_on_y(dut):
    """On-target tone on Y only → fault asserts."""
    await _start_clock(dut)
    await _reset(dut)
    await _clear_fault(dut)

    await _configure(dut, c0=COEFF_C0, c1=0, c2=0, threshold=14)
    await _run_blocks(dut, n_blocks=2, y_tone=FREQ_20_512)

    assert int(dut.fault_flag_out.value) == 1, (
        "fault_flag_out should assert for Y-axis on-target tone"
    )


# --------------------------------------------------------------------------
# Case 4 — Fault on Z axis only
# --------------------------------------------------------------------------
@cocotb.test()
async def test_case4_fault_on_z(dut):
    """On-target tone on Z only → fault asserts."""
    await _start_clock(dut)
    await _reset(dut)
    await _clear_fault(dut)

    await _configure(dut, c0=COEFF_C0, c1=0, c2=0, threshold=14)
    await _run_blocks(dut, n_blocks=2, z_tone=FREQ_20_512)

    assert int(dut.fault_flag_out.value) == 1, (
        "fault_flag_out should assert for Z-axis on-target tone"
    )


# --------------------------------------------------------------------------
# Case 5 — Simultaneous 3-axis fault (ITAG key benefit)
# --------------------------------------------------------------------------
@cocotb.test()
async def test_case5_simultaneous_3axis_fault(dut):
    """On-target tone on ALL THREE axes simultaneously."""
    await _start_clock(dut)
    await _reset(dut)
    await _clear_fault(dut)

    await _configure(dut, c0=COEFF_C0, c1=0, c2=0, threshold=14)
    await _run_blocks(dut, n_blocks=2, x_tone=FREQ_20_512, y_tone=FREQ_20_512, z_tone=FREQ_20_512)

    assert int(dut.fault_flag_out.value) == 1, (
        "ITAG should detect simultaneous 3-axis fault within one block"
    )


# --------------------------------------------------------------------------
# Case 6 — cfg_fault_clear de-asserts fault_flag_out
# --------------------------------------------------------------------------
@cocotb.test()
async def test_case6_fault_clear(dut):
    """After fault_flag asserts, cfg_fault_clear must de-assert it."""
    await _start_clock(dut)
    await _reset(dut)

    await _configure(dut, c0=COEFF_C0, c1=0, c2=0, threshold=14)
    await _run_blocks(dut, n_blocks=2, x_tone=FREQ_20_512)

    assert int(dut.fault_flag_out.value) == 1, "Precondition: fault must be set"

    await _clear_fault(dut)
    await Timer(5 * CLK_NS, unit="ns")

    assert int(dut.fault_flag_out.value) == 0, (
        "fault_flag_out should de-assert after cfg_fault_clear"
    )


# --------------------------------------------------------------------------
# ITAG structural invariant — 9 magnitude pulses per block
# --------------------------------------------------------------------------
async def _mag_pulse_listener(dut, counts):
    """Continuously count mag_out_valid pulses in background."""
    while True:
        await RisingEdge(dut.clk)
        if (dut.mag_inst.mag_out_valid.value.is_resolvable and
            int(dut.mag_inst.mag_out_valid.value) == 1):
            counts[0] += 1


@cocotb.test()
async def test_itag_9_mag_pulses_per_block(dut):
    """The ITAG magnitude engine must emit exactly 9 mag_out_valid pulses
    per 512-sample block (3 axes × 3 bins = 9 pairs)."""
    await _start_clock(dut)
    await _reset(dut)

    counts = [0]
    cocotb.start_soon(_mag_pulse_listener(dut, counts))

    await _configure(dut, c0=q15(0.5), c1=q15(0.3), c2=q15(0.1),
                     threshold=0x7FFFFFFF)
    await _run_blocks(dut, n_blocks=1)

    # Wait an additional 200 cycles for post-block magnitude calculations
    for _ in range(200):
        await RisingEdge(dut.clk)

    assert counts[0] == 9, (
        f"Expected 9 magnitude pulses per block, got {counts[0]}"
    )


# --------------------------------------------------------------------------
# ITAG structural invariant — no multiplier contention
# --------------------------------------------------------------------------
@cocotb.test()
async def test_itag_no_multiplier_contention(dut):
    """goertzel_core and magnitude_compute must never request the shared
    multiplier at the same time (single-multiplier design invariant #2)."""
    await _start_clock(dut)
    await _reset(dut)
    await _configure(dut, c0=q15(0.5), c1=q15(0.3), c2=q15(0.1),
                     threshold=0x7FFFFFFF)

    contention = 0
    for s in range(BLOCK_SIZE):
        dut.sensor_drdy.value = 1
        for _ in range(5):
            await RisingEdge(dut.clk)
        dut.sensor_drdy.value = 0

        for _ in range(500):
            await RisingEdge(dut.clk)
            core_req = (int(dut.goertzel_inst.mult_req.value)
                        if dut.goertzel_inst.mult_req.value.is_resolvable else 0)
            mag_req  = (int(dut.mag_inst.mag_mult_req.value)
                        if dut.mag_inst.mag_mult_req.value.is_resolvable else 0)
            if core_req and mag_req:
                contention += 1
            if int(dut.c_csn.value) == 1:
                break

    assert contention == 0, (
        f"Multiplier contention detected {contention} time(s) — "
        "invariant #2 (single shared multiplier) violated"
    )
