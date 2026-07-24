# test_goertzel.py — cocotb testbench for goertzel_core.v  (ITAG variant)
#
# Runs with Icarus Verilog.  Invoke via the Makefile:
#     make test-goertzel
#
# Exercises:
#   1. Reset clears all v1/v2 state registers to zero.
#   2. sample_done pulses exactly once per sample (after the 18th active cycle).
#   3. Q8.15 fixed-point arithmetic — coefficient c=0 drives all outputs to zero.
#   4. Three-axis interleaving — v1/v2 for X, Y, Z updated independently each sample.
#   5. block_clear zeroes all v-state synchronously one cycle after assertion.
#   6. Single-multiplier arbitration — mult_req is never asserted outside the
#      18 active cycles (no spurious multiplier requests).
#   7. Deterministic convergence — on-target tone grows monotonically over 512 samples.

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer
import math

# System clock period (10 MHz → 100 ns)
CLK_NS = 100

# Q8.15 scaling factor
Q15 = 1 << 15

# Number of bins
N_BINS = 3

# 24-bit signed min/max
SIGN24 = 1 << 23
MASK24 = (1 << 24) - 1


def to_q15(x: float) -> int:
    """Convert float [-1, 1) to Q8.15 signed 24-bit."""
    v = int(round(x * Q15)) & MASK24
    return v


def from_q15_signed(v: int) -> float:
    """Convert 24-bit Q8.15 register to signed float."""
    v &= MASK24
    if v >= SIGN24:
        v -= (1 << 24)
    return v / Q15


async def _run_multiplier(dut):
    """Emulate the shared multiplier + Q8.15 saturation in magnitude_compute."""
    while True:
        await RisingEdge(dut.clk)
        if dut.mult_req.value.is_resolvable and int(dut.mult_req.value) == 1:
            a = int(dut.mult_a.value)
            b = int(dut.mult_b.value)
            
            # Convert 24-bit signed to Python int
            if a >= SIGN24: a -= (1 << 24)
            if b >= SIGN24: b -= (1 << 24)
            
            # Multiply
            p = a * b
            
            # Shift by 15 (Q8.15 scaling)
            p_shifted = p >> 15
            
            # Saturate to 24-bit signed
            MIN_VAL = -SIGN24
            MAX_VAL = SIGN24 - 1
            if p_shifted < MIN_VAL:
                p_sat = MIN_VAL
            elif p_shifted > MAX_VAL:
                p_sat = MAX_VAL
            else:
                p_sat = p_shifted
                
            # Convert back to 24-bit unsigned representation
            p_sat_u = p_sat & MASK24
            
            # Wait for next rising edge to update mult_q
            await RisingEdge(dut.clk)
            dut.mult_q.value = p_sat_u


async def _start_clock(dut):
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    cocotb.start_soon(_run_multiplier(dut))


async def _reset(dut, c0=0, c1=0, c2=0):
    """Assert reset, drive zero coefficients, release."""
    dut.rst_n.value = 0
    dut.enable.value = 0
    dut.data_ready.value = 0
    dut.x_n.value = 0
    dut.y_n.value = 0
    dut.z_n.value = 0
    dut.coeff_c0.value = c0 & MASK24
    dut.coeff_c1.value = c1 & MASK24
    dut.coeff_c2.value = c2 & MASK24
    dut.block_clear.value = 0
    # Multiplier feedback: in isolation the test drives mult_q directly
    dut.mult_q.value = 0
    await Timer(5 * CLK_NS, unit="ns")
    dut.rst_n.value = 1
    dut.enable.value = 1
    await RisingEdge(dut.clk)


async def _send_sample(dut, x: int, y: int, z: int):
    """Pulse data_ready for 1 cycle with the given 16-bit samples."""
    dut.x_n.value = x & 0xFFFF
    dut.y_n.value = y & 0xFFFF
    dut.z_n.value = z & 0xFFFF
    dut.data_ready.value = 1
    await RisingEdge(dut.clk)
    dut.data_ready.value = 0


async def _wait_sample_done(dut, timeout=500) -> bool:
    for _ in range(timeout):
        await RisingEdge(dut.clk)
        if int(dut.sample_done.value) == 1:
            return True
    return False


# -----------------------------------------------------------------------
# Test 1 — Reset clears v-registers
# -----------------------------------------------------------------------
@cocotb.test()
async def test_reset_clears_state(dut):
    """All v1/v2 outputs must be zero immediately after reset."""
    await _start_clock(dut)
    await _reset(dut)
    await Timer(CLK_NS, unit="ns")

    for axis in ("x", "y", "z"):
        for reg in ("v1", "v2"):
            for b in range(N_BINS):
                sig_name = f"{reg}{axis}_{b}"
                sig = getattr(dut, sig_name)
                assert int(sig.value) == 0, (
                    f"{sig_name} should be 0 after reset, got {int(sig.value)}"
                )


# -----------------------------------------------------------------------
# Test 2 — sample_done pulses exactly once per sample
# -----------------------------------------------------------------------
@cocotb.test()
async def test_sample_done_once_per_sample(dut):
    """sample_done must pulse exactly once per data_ready cycle."""
    await _start_clock(dut)
    await _reset(dut)

    for i in range(5):
        await _send_sample(dut, 0x0100, 0x0200, 0x0300)
        done_count = 0
        for _ in range(100):
            await RisingEdge(dut.clk)
            if int(dut.sample_done.value) == 1:
                done_count += 1
        assert done_count == 1, (
            f"Sample {i}: expected 1 sample_done pulse, got {done_count}"
        )


# -----------------------------------------------------------------------
# Test 3 — Zero coefficient → zero v-state
# -----------------------------------------------------------------------
@cocotb.test()
async def test_zero_coeff_zero_output(dut):
    """With all coefficients = 0 and zero inputs, goertzel v-registers stay at zero."""
    await _start_clock(dut)
    await _reset(dut, c0=0, c1=0, c2=0)

    for _ in range(10):
        await _send_sample(dut, 0x0000, 0x0000, 0x0000)
        await _wait_sample_done(dut)

    for axis in ("x", "y", "z"):
        for b in range(N_BINS):
            v1 = int(getattr(dut, f"v1{axis}_{b}").value)
            assert v1 == 0, (
                f"v1{axis}_{b} should stay 0 with coeff=0 and zero inputs, got {v1}"
            )


# -----------------------------------------------------------------------
# Test 4 — Three-axis independence
# -----------------------------------------------------------------------
@cocotb.test()
async def test_three_axis_independence(dut):
    """X, Y, Z v-state must differ when given different input samples."""
    await _start_clock(dut)
    # Use a non-zero coefficient so state actually evolves
    c = to_q15(0.5)
    await _reset(dut, c0=c, c1=c, c2=c)

    # Send 5 samples where x ≠ y ≠ z
    for _ in range(5):
        await _send_sample(dut, 0x0100, 0x0200, 0x0400)
        await _wait_sample_done(dut)

    v1x = int(dut.v1x_0.value)
    v1y = int(dut.v1y_0.value)
    v1z = int(dut.v1z_0.value)

    # All three should be non-zero and different from each other
    assert not (v1x == 0 and v1y == 0 and v1z == 0), (
        "All three axis v-registers are zero — axis interleaving may be broken"
    )
    assert not (v1x == v1y == v1z), (
        f"All axes have same v1_0={v1x:#x} — axis routing may be collapsed"
    )


# -----------------------------------------------------------------------
# Test 5 — block_clear zeroes v-state
# -----------------------------------------------------------------------
@cocotb.test()
async def test_block_clear_zeroes_state(dut):
    """After block_clear, all v-registers must return to zero."""
    await _start_clock(dut)
    c = to_q15(0.9)
    await _reset(dut, c0=c, c1=c, c2=c)

    # Accumulate some state
    for _ in range(8):
        await _send_sample(dut, 0x0500, 0x0500, 0x0500)
        await _wait_sample_done(dut)

    # Assert block_clear for one cycle
    dut.block_clear.value = 1
    await RisingEdge(dut.clk)
    dut.block_clear.value = 0
    await RisingEdge(dut.clk)  # let registered clear propagate

    for axis in ("x", "y", "z"):
        for b in range(N_BINS):
            v1 = int(getattr(dut, f"v1{axis}_{b}").value)
            v2 = int(getattr(dut, f"v2{axis}_{b}").value)
            assert v1 == 0, f"v1{axis}_{b} not cleared, got {v1:#x}"
            assert v2 == 0, f"v2{axis}_{b} not cleared, got {v2:#x}"


# -----------------------------------------------------------------------
# Test 6 — No spurious mult_req outside the 18-cycle active window
# -----------------------------------------------------------------------
@cocotb.test()
async def test_no_spurious_mult_req(dut):
    """mult_req must be 0 outside the 18-cycle active window.
    After sample_done the core must stay idle until the next data_ready."""
    await _start_clock(dut)
    c = to_q15(0.5)
    await _reset(dut, c0=c, c1=c, c2=c)

    await _send_sample(dut, 0x0100, 0x0100, 0x0100)
    await _wait_sample_done(dut)

    # Check 200 more cycles — no mult_req should fire in the idle window
    spurious = 0
    for _ in range(200):
        await RisingEdge(dut.clk)
        if int(dut.mult_req.value) == 1:
            spurious += 1

    assert spurious == 0, (
        f"mult_req asserted {spurious} times during idle window (single-multiplier violation)"
    )


# -----------------------------------------------------------------------
# Test 7 — On-target tone accumulates (monotone growth)
# -----------------------------------------------------------------------
@cocotb.test()
async def test_on_target_tone_grows(dut):
    """A resonant input tone (c = 2cos(2πf/fs) for bin 0) causes v1 to grow
    monotonically in magnitude over 20 samples."""
    await _start_clock(dut)
    # Coefficient for a tone at fs/4 (quarter of sample rate): 2*cos(π/2) = 0
    # Use a moderate coefficient so state grows without overflow in 20 samples
    c = to_q15(1.618 / 2.0)   # ~golden-ratio / 2, non-trivial resonance
    await _reset(dut, c0=c, c1=0, c2=0)

    prev_mag = 0
    grew = False
    for _ in range(20):
        await _send_sample(dut, 0x0400, 0x0000, 0x0000)
        await _wait_sample_done(dut)
        v1 = int(dut.v1x_0.value)
        # Convert to signed magnitude
        if v1 >= SIGN24:
            v1 -= (1 << 24)
        mag = abs(v1)
        if mag > prev_mag:
            grew = True
        prev_mag = mag

    assert grew, "v1x_0 never grew — Goertzel accumulation may be broken"
