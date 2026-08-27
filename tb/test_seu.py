# test_seu.py — SEU (single-event upset) injection tests for the TMR-hardened
#               control FSM in goertzel_core.v
#
# Runs with Icarus Verilog.  Invoke via the Makefile:
#     make test-seu
#
# WHY THIS FILE EXISTS
# --------------------
# The project's headline claim is radiation-hardening-by-design: every control
# FSM keeps three physical copies of its state, combined by a bitwise 2-of-3
# majority voter, with all three copies re-written from the *voted* value every
# cycle (self-scrubbing).  Until now that claim was only verified
# *structurally* — the Stage-1 netlist check proves the three copies survive
# synthesis.  Nothing proved the voter actually CORRECTS an upset.
#
# These tests close that gap by forcing a wrong value into one copy at a time
# and checking three properties:
#
#   1. MASKING     — while one copy is corrupt, the voted state is still
#                    correct (2-of-3 outvotes the bad copy), so downstream
#                    logic never sees the fault.
#   2. SCRUBBING   — one clock after the force is released, all three copies
#                    agree again, because each is re-loaded from the voted
#                    next-state rather than from itself.
#   3. ILLEGAL-STATE RECOVERY
#                  — if an upset drives the FSM into an unreachable encoding,
#                    the `default:` branch returns it to S_IDLE within one
#                    clock instead of hanging.
#
# What these tests do NOT claim: they inject at the RTL level, so they prove the
# *logical* voter behaviour, not the physical cross-section of the layout
# (spacing of the three copies, guard rings, etc.), which is a layout concern.

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

CLK_NS = 62.5           # 16 MHz — the signed-off macro clock
STATE_W = 5             # goertzel_core's FSM state width (vote5)
S_IDLE = 0              # safe/idle encoding the default branch falls back to


def vote5(a: int, b: int, c: int) -> int:
    """Reference model of the RTL's bitwise 2-of-3 majority voter."""
    return (a & b) | (b & c) | (a & c)


async def bring_up(dut):
    """Clock, reset, and a minimal setup so the FSM leaves IDLE."""
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    dut.rst_n.value = 0
    dut.enable.value = 0
    dut.data_ready.value = 0
    dut.block_clear.value = 0
    dut.x_n.value = 0
    dut.y_n.value = 0
    dut.z_n.value = 0
    dut.coeff_c0.value = 0x004000
    dut.coeff_c1.value = 0x004000
    dut.coeff_c2.value = 0x004000
    dut.mult_q.value = 0
    for _ in range(5):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    dut.enable.value = 1
    for _ in range(3):
        await RisingEdge(dut.clk)


async def leave_idle(dut):
    """Strobe data_ready so the FSM advances out of S_IDLE."""
    dut.data_ready.value = 1
    await RisingEdge(dut.clk)
    dut.data_ready.value = 0
    await RisingEdge(dut.clk)


def read_triplet(dut):
    return (int(dut.state_a.value), int(dut.state_b.value), int(dut.state_c.value))


# ---------------------------------------------------------------------------
# 1. The voter masks a single upset: voted state stays correct.
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_seu_single_copy_is_masked(dut):
    """Forcing ONE copy wrong must not change the voted state."""
    await bring_up(dut)

    # Deliberately do NOT trigger a sample burst here. With data_ready low the
    # FSM sits in S_IDLE and the triplet is *static*, so a deposit into one copy
    # cannot race the FSM's own nonblocking update on the next clock edge. The
    # property under test -- "the 2-of-3 voter follows the two healthy copies"
    # -- is independent of which state value is held, so a static state is the
    # cleanest place to prove it.
    await Timer(CLK_NS / 2, unit="ns")      # settle mid-period, away from edges

    checks = 0
    for bit in range(STATE_W):
        b_pre, c_pre = int(dut.state_b.value), int(dut.state_c.value)
        assert b_pre == c_pre, (
            f"copies B and C differ before injection "
            f"(b=0x{b_pre:02x} c=0x{c_pre:02x}) -- test setup is unsound"
        )

        corrupt = b_pre ^ (1 << bit)        # single-bit upset in copy A
        dut.state_a.value = corrupt
        await Timer(1, unit="ps")           # settle the combinational voter

        a1, b1, c1 = read_triplet(dut)
        voted = int(dut.state_v.value)

        assert a1 != b1, f"injection did not diverge copy A (a=b=0x{a1:02x})"
        assert b1 == c1, f"B/C diverged during injection (b=0x{b1:02x} c=0x{c1:02x})"
        assert voted == b1, (
            f"SEU on state_a bit {bit} CORRUPTED the voted state: "
            f"a=0x{a1:02x} b=0x{b1:02x} c=0x{c1:02x} -> voted=0x{voted:02x}, "
            f"but the two healthy copies say 0x{b1:02x}. "
            f"The 2-of-3 voter is not masking the upset."
        )
        assert voted == vote5(a1, b1, c1), "voter disagrees with the 2-of-3 reference model"
        checks += 1

        dut.state_a.value = b_pre           # restore before the next bit
        await Timer(1, unit="ps")

    dut._log.info(
        f"voter masked {checks}/{STATE_W} single-bit upsets on copy A "
        f"(voted state always followed the two healthy copies)"
    )


# ---------------------------------------------------------------------------
# 2. Self-scrubbing: the corrupted copy is repaired on the next clock.
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_seu_is_scrubbed_next_clock(dut):
    """After one clock, all three copies must agree again."""
    await bring_up(dut)

    await leave_idle(dut)

    good = int(dut.state_b.value)
    dut.state_a.value = good ^ 0b10101          # multi-bit corruption of one copy
    await Timer(1, unit="ns")

    a, b, c = read_triplet(dut)
    assert a != b, "injection did not actually diverge copy A"

    # one clock: every copy reloads from the voted next-state
    await RisingEdge(dut.clk)
    await Timer(1, unit="ns")

    a, b, c = read_triplet(dut)
    assert a == b == c, (
        f"self-scrubbing FAILED: one clock after the upset the copies still "
        f"disagree (a=0x{a:02x} b=0x{b:02x} c=0x{c:02x}). Each copy must be "
        f"re-written from the voted value, not from itself."
    )
    dut._log.info(f"triplet re-converged to 0x{a:02x} one clock after the upset")


# ---------------------------------------------------------------------------
# 3. Illegal-state recovery via the FSM's default branch.
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_seu_illegal_state_recovers_to_idle(dut):
    """An unreachable encoding in ALL copies must fall back to S_IDLE."""
    await bring_up(dut)

    legal = set()
    dut.data_ready.value = 1
    await RisingEdge(dut.clk)
    dut.data_ready.value = 0
    for _ in range(40):                     # sweep a full sample to collect encodings
        await RisingEdge(dut.clk)
        legal.add(int(dut.state_v.value))

    illegal = next((s for s in range(1 << STATE_W) if s not in legal), None)
    if illegal is None:
        dut._log.warning("FSM uses every encoding; no illegal state to test")
        return

    # corrupt all three copies -> the voter cannot help, only `default:` can
    dut.state_a.value = illegal
    dut.state_b.value = illegal
    dut.state_c.value = illegal
    await Timer(1, unit="ns")
    assert int(dut.state_v.value) == illegal, "failed to force the illegal state"

    await RisingEdge(dut.clk)
    await Timer(1, unit="ns")

    recovered = int(dut.state_v.value)
    assert recovered == S_IDLE, (
        f"illegal state 0x{illegal:02x} did NOT recover to S_IDLE: went to "
        f"0x{recovered:02x}. The FSM's default branch must trap unreachable "
        f"encodings or an upset can hang the core."
    )
    dut._log.info(
        f"illegal encoding 0x{illegal:02x} recovered to S_IDLE in one clock"
    )
