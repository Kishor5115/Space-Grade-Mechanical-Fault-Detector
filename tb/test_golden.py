# test_golden.py — golden values for post-silicon Gates 6 and 8 (documents/test_plan.md)
#
# Runs with Icarus Verilog.  Invoke via the Makefile:
#     make test-golden
#
# Plays the bench emulator's stimulus through the RTL and writes the magnitude of
# all 9 (axis, bin) pairs to golden_values.json. Each sample is one DRDY every 600
# clocks (26.667 kHz at 16 MHz), starting from reset so the block counter is aligned.
#
# Samples: round(amp * sin(2*pi*k*n/512) * 32768), clamped to 16-bit signed.
# Coefficients: round(2*cos(2*pi*k/512) * 32768), 24-bit two's complement.

import json
import math
import os

import cocotb
from cocotb.triggers import ClockCycles, ReadOnly, RisingEdge

import test_top as tt

DRDY_PERIOD = 600
BIN_K       = (20, 96, 192)   # 1041.7, 5000.1, 10000.1 Hz at 26.667 kHz
AMPS        = (1.0, 0.25, 0.0625)
LOW_AMP     = 1.0 / 256.0     # small enough that a byte swap changes the result strongly
TH_MAX      = 0x7FFFFFFF
AXES        = "XYZ"
OUT         = os.path.join(os.path.dirname(os.path.abspath(__file__)), "golden_values.json")

g_mags = []


def _coeffs(active_bin):
    c = [0, 0, 0]
    if active_bin is not None:
        c[active_bin] = tt.q15(2.0 * math.cos(2.0 * math.pi * BIN_K[active_bin] / 512.0))
    return c


def _swap(v):
    return ((v & 0xFF) << 8) | (v >> 8)


async def _mag_monitor(dut):
    while True:
        await RisingEdge(dut.mag_inst.mag_out_valid)
        await ReadOnly()
        g_mags.append((int(dut.mag_inst.mag_axis_idx.value),
                       int(dut.mag_inst.mag_bin_idx.value),
                       int(dut.mag_inst.mag_out.value)))


async def _start(dut):
    await tt._start_clock(dut)
    cocotb.start_soon(_mag_monitor(dut))


def _set_sample(values):
    tt.g_sample_x, tt.g_sample_y, tt.g_sample_z = values


async def _sample(dut, values):
    _set_sample(values)
    dut.sensor_drdy.value = 1
    await ClockCycles(dut.clk, 5)
    dut.sensor_drdy.value = 0
    await ClockCycles(dut.clk, DRDY_PERIOD - 5)


async def _run(dut, coeffs, threshold, tones, swap=False, blocks=1):
    """Reset, configure, play `blocks` blocks of tones = {axis: (k, amp)}. Returns (flag, mags)."""
    await tt._reset(dut)
    await tt._configure(dut, *coeffs, threshold=threshold)
    g_mags.clear()

    n = 0
    while len(g_mags) < 9 * blocks:
        values = [0, 0, 0]
        for axis, (k, amp) in tones.items():
            values[axis] = tt._inject_tone(n, k / 512.0, amp)
            if swap:
                values[axis] = _swap(values[axis])
        await _sample(dut, values)
        n += 1
        assert n <= 512 * blocks + 64, f"expected {9 * blocks} magnitudes, got {len(g_mags)}"

    await ClockCycles(dut.clk, 5)
    return int(dut.fault_flag_out_OUT.value), list(g_mags)


def _table(mags):
    return {f"{AXES[a]}{b}": v for a, b, v in mags[:9]}


def _save(section, data):
    results = {}
    if os.path.exists(OUT):
        with open(OUT) as f:
            results = json.load(f)
    results[section] = data
    with open(OUT, "w") as f:
        json.dump(results, f, indent=1)


@cocotb.test()
async def test_sample_byte_order(dut):
    """Prerequisite for golden values: a sensor sample must reach the DSP unchanged."""
    await _start(dut)
    await tt._reset(dut)
    await tt._configure(dut, 0, 0, 0, threshold=TH_MAX)

    sent = (0x1122, 0x3344, 0x5566)
    _set_sample(sent)
    dut.sensor_drdy.value = 1
    await ClockCycles(dut.clk, 5)
    dut.sensor_drdy.value = 0
    await RisingEdge(dut.axseq_inst.core_data_ready)
    await ReadOnly()
    got = tuple(int(s.value) & 0xFFFF for s in (dut.axseq_inst.core_x_n,
                                                dut.axseq_inst.core_y_n,
                                                dut.axseq_inst.core_z_n))
    assert got == sent, f"sent {[hex(v) for v in sent]}, DSP got {[hex(v) for v in got]}"


@cocotb.test()
async def test_read_command_all_drdy_phases(dut):
    """DRDY is asynchronous, so every phase against the clk/8 SPI divider must give a read."""
    await _start(dut)
    await tt._reset(dut)
    for phase in range(8):
        before = tt.g_read_cmds
        await ClockCycles(dut.clk, 1000 + phase)
        await _sample(dut, (0, 0, 0))
        assert tt.g_read_cmds == before + 1, f"phase {phase}: command was not a read"


@cocotb.test()
async def test_gate6(dut):
    """Plan Gate 6: measure at the maximum threshold, pick the threshold, confirm the flag."""
    await _start(dut)
    cases = []

    async def case(name, active_bin, tones, threshold, expect, swap=False):
        flag, mags = await _run(dut, _coeffs(active_bin), threshold, tones, swap)
        assert flag == expect, f"{name}: threshold {threshold}, flag {flag}, expected {expect}"
        cases.append({"case": name, "bin": active_bin, "k_cycles_per_block": BIN_K[active_bin]
                      if active_bin is not None else None,
                      "tones": {AXES[a]: {"k": t[0], "amp": t[1]} for a, t in tones.items()},
                      "swapped_bytes": swap, "threshold": threshold, "expected_flag": expect,
                      "magnitudes": _table(mags)})
        return max(v for _, _, v in mags[:9])

    async def peak(active_bin, tones, swap=False):
        _, mags = await _run(dut, _coeffs(active_bin), TH_MAX, tones, swap)
        return max(v for _, _, v in mags[:9])

    await case("6.1", 0, {}, 14, 0)
    for name, axis in (("6.2", 0), ("6.3", 1), ("6.4", 2)):
        await case(name, 0, {axis: (BIN_K[0], 1.0)}, 14, 1)
    await case("6.5", 0, {a: (BIN_K[0], 1.0) for a in range(3)}, 14, 1)
    on_bin = await case("6.6", 0, {0: (BIN_K[0], 1.0)}, TH_MAX, 0)

    for name, b in (("6.7", 1), ("6.8", 2)):
        for axis in range(3):
            tones = {axis: (BIN_K[b], 1.0)}
            await case(f"{name}{AXES[axis]}", b, tones, await peak(b, tones) // 2, 1)

    tones = {0: (BIN_K[1], 1.0)}
    off_bin = await peak(0, tones)
    assert off_bin < on_bin, f"off-bin {off_bin} is not below on-bin {on_bin}"
    await case("6.9", 0, tones, (off_bin + on_bin) // 2, 0)

    # 6.10: threshold between correct and swapped results, so the two give opposite flags
    for axis in range(3):
        tones = {axis: (BIN_K[0], LOW_AMP)}
        correct = await peak(0, tones)
        swapped = await peak(0, tones, swap=True)
        assert correct < swapped, f"{AXES[axis]}: correct {correct}, swapped {swapped}"
        th = (correct + swapped) // 2
        await case(f"6.10{AXES[axis]}", 0, tones, th, 0)
        await case(f"6.10{AXES[axis]}-swapped", 0, tones, th, 1, swap=True)

    _save("gate6", cases)


@cocotb.test()
async def test_gate8(dut):
    """Plan Gate 8: expected binary-search result for 9 pairs at 3 amplitudes."""
    await _start(dut)
    points = []
    for b in range(3):
        for axis in range(3):
            for amp in AMPS:
                tones = {axis: (BIN_K[b], amp)}
                _, mags = await _run(dut, _coeffs(b), TH_MAX, tones)
                table = _table(mags)
                top = max(table.values())
                # Input is shifted right 4 bits: |X| = 256 * amp / 16, mag = |X|^2 in Q15
                ideal = (256.0 * amp / 16.0) ** 2 * 32768
                assert abs(table[f"{AXES[axis]}{b}"] - ideal) < 0.01 * ideal, (
                    f"{AXES[axis]}{b}, amp {amp}: magnitude {table[f'{AXES[axis]}{b}']}, ideal {ideal:.0f}")
                points.append({"axis": AXES[axis], "bin": b, "k": BIN_K[b], "amp": amp,
                               "search_result": top,
                               "tested_pair_is_largest": table[f"{AXES[axis]}{b}"] == top,
                               "magnitudes": table})

    # The search reads the largest magnitude: flag low at that threshold, high one below it
    tones = {0: (BIN_K[0], 0.25)}
    _, mags = await _run(dut, _coeffs(0), TH_MAX, tones, blocks=2)
    assert _table(mags) == _table(mags[9:]), "repeated blocks must give identical magnitudes"
    top = max(_table(mags).values())
    flag_at, _ = await _run(dut, _coeffs(0), top, tones)
    flag_below, _ = await _run(dut, _coeffs(0), top - 1, tones)
    assert (flag_at, flag_below) == (0, 1), f"flag at {top}: {flag_at}, one below: {flag_below}"

    _save("gate8", points)
