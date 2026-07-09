# Integration & Testing Challenges — RTL Review Meeting Notes

**Project:** Space-Grade Mechanical Fault Detector (SSCS Chipathon 2026, Track B)
**Scope:** Full-chip integration verification of `top.v` (3-axis time-multiplexed Goertzel fault detector) and the standalone module testbenches feeding into it.
**Purpose of this document:** Capture the specific technical dead-ends, false leads, and root causes encountered during this verification pass, so the team can discuss process changes before the next RTL freeze — not just the final fixes (those are in `CHANGELOG.md`).

---

## Table of Contents

1. [Summary Table](#summary-table)
2. [Challenge 1: Undetected full-fault-path failure (magnitude_compute.v)](#challenge-1)
3. [Challenge 2: Hand-tracing a shift register produced a confidently wrong answer](#challenge-2)
4. [Challenge 3: Missing sensor boot sequence — a stub nobody flagged](#challenge-3)
5. [Challenge 4: Stale test harness caused a hard build failure, not a soft one](#challenge-4)
6. [Challenge 5: `force`/`release` races when whitebox-driving an internal bus](#challenge-5)
7. [Challenge 6: Picking a fault threshold without a reference model](#challenge-6)
8. [Challenge 7: Axis-boundary sample bleed-through in the testbench itself](#challenge-7)
9. [Challenge 8: Architecture documentation drift](#challenge-8)
10. [Cross-cutting observations for the review](#cross-cutting-observations)
11. [Recommended process changes](#recommended-process-changes)

---

## Summary Table

| # | Challenge | Class | Where it was hiding | How it was found | Cost to fix |
|---|---|---|---|---|---|
| 1 | `mag_out` always 0 — no fault ever possible | **Silent functional bug** | `magnitude_compute.v` multiplier pipeline | Only visible via full-chain sim | 1 line, net **–1** flop |
| 2 | Axis mux "fix" based on hand-traced shift register was itself wrong | **Analysis error, self-inflicted** | `axis_sequencer.v` | Live sim comparison caught the reviewer (me), not the RTL | 0 (reverted) |
| 3 | IIS3DWB boot config sequence never implemented | **Missing feature, stubbed with a comment** | `spi_master.v` | Existing testbench already expected it; was failing silently | ~40 lines, 8 new flops |
| 4 | `apb_test` didn't compile at all | **Stale test harness** | `testing/apb_test/` | Ran it — 4 elaboration errors | New stub file |
| 5 | Whitebox APB drive via `force` raced against the real APB master | **Verification methodology gap** | `tb_top.v` (new) | `force`-then-`release` on separate signals silently never overlapped | Concatenated single `force` |
| 6 | No golden reference for "is this magnitude a fault or not" | **Missing verification collateral** | Threshold selection for `tb_top.v` | Hand math off by ~10,000x from real saturated behavior | Empirical calibration |
| 7 | Fault briefly attributed to the wrong axis right after amplitude change | **Testbench timing bug** | `tb_top.v` stimulus sequencing | Cross-referenced `fault_axis_latched` against expected | Added a drain-wait task |
| 8 | `docs/top.md` didn't match `top.v` | **Documentation drift** | `docs/` | Manual diff against RTL | Rewrite |

---

## Challenge 1: Undetected full-fault-path failure in `magnitude_compute.v` <a name="challenge-1"></a>

### What we found
`mag_out` was **always 0**, for every bin, every axis, every block — regardless of how large the real `v1`/`v2` Goertzel state was. This means the entire fault detector could never trip on real silicon. Not a corner case: 100% of blocks, 100% of the time.

### Why nothing caught it earlier
- `goertzel_core.v` has its own dedicated testbench (`tb_goertzel_core.v`) and passes cleanly — but that testbench only checks `v1`/`v2` state, never `mag_out`, because `magnitude_compute` is a separate module downstream.
- `magnitude_compute.v` has **no standalone testbench of its own**.
- `top.v` elaborates with zero warnings under `iverilog` — elaboration checks port connectivity and width matching, not functional correctness. A module that is wired up perfectly correctly but produces a constant wrong answer elaborates just as cleanly as a correct one.
- The only place this bug could possibly be observed was a full end-to-end simulation feeding real sensor data all the way through to `fault_flag_out` — which is exactly the testbench (`tb_top.v`) that didn't exist before this pass.

### Root cause (the actual bug)
```verilog
reg mult_req_d;
always @(posedge clk or negedge rst_n) begin
    ...
    mult_req_d <= mult_req_w;
    if (mult_req_d) core_mult_q <= mult_sat;
end
```
This design assumes the requester's multiply operands stay stable for **two** cycles, so that `mult_sat` (computed combinationally from the *current* operands) is still correct when `mult_req_d` — a *delayed* copy of the request — finally gates the capture one cycle later.

`goertzel_core.v`'s own multiply operands roughly satisfy this. `magnitude_compute.v`'s own operands (`mag_mult_a`/`mag_mult_b`) do **not** — they are driven combinationally only during the single request state and snap back to `0` the very next cycle. By the time `mult_req_d` triggered the capture, the operands (and therefore `mult_sat`) had already reverted to `0`. Every multiply silently became `0 × 0 = 0`.

### How it was actually diagnosed
This was not spotted by code review — it required **live signal tracing inside a running simulation**:
1. `tb_top.v` reported `mag_out=0` at every block despite the axis's `v1_0`/`v2_0` clearly being large nonzero values (visible via hierarchical `$display` probes).
2. Manually computed the expected magnitude by hand from those `v1`/`v2` values — got a large nonzero number, confirming the RTL result was wrong, not just small.
3. Added cycle-by-cycle `$display` tracing of `mag_mult_a`, `mag_mult_b`, `mult_full`, `mult_shifted`, `mult_sat`, and `core_mult_q` together.
4. Watched `mult_sat` compute a correct nonzero value on the request cycle, then watched `core_mult_q` latch `0` one cycle later anyway — because by then `mag_mult_a/b` (and therefore the *recomputed* `mult_sat`) had already fallen back to zero.

### Fix
Capture on the *same* cycle as the request, not one cycle later — removing the `mult_req_d` register entirely. This matches `goertzel_core`'s own request/consume contract exactly (request in state N, consume in state N+1), and reduces flop count instead of increasing it.

### Discussion point for the review
**This class of bug — a shared-resource arbiter written against an implicit timing assumption that only one of its two clients actually satisfies — is easy to introduce and hard to catch by inspection.** Any other shared-resource interfaces in the design (the shared multiplier is not the only one) should get an explicit written timing contract, and ideally a self-checking assertion (`assert` that operands don't change between request and expected-valid cycle) rather than relying on both sides "happening" to agree.

---

## Challenge 2: Hand-tracing a shift register produced a confidently wrong answer <a name="challenge-2"></a>

### What happened
While preparing `tb_top.v`, I needed to know which 16-bit slice of `spi_master.v`'s 48-bit `s_data_out` register corresponds to which sensor axis, to correctly map `axis_sequencer.v`'s `xn_comb` mux. I hand-simulated the shift register's bit positions in a Python script and concluded the *existing* RTL had X and Z swapped. I "fixed" it.

### What was actually true
The original RTL was correct. My Python trace had the shift direction backwards. I only caught this because `tb_top.v`, once running, showed the *wrong* axis (per my "fix") receiving the injected tone's energy — and rather than assuming the testbench was wrong, I went back to first principles: **compared the DUT's actual `s_data_out` value, live, against the sensor model's `model_outx/y/z` inputs, byte for byte, in simulation** — not in a side script. That immediately showed the original mapping was right and my fix was wrong. Reverted.

### Why this matters for the review
- This was a **self-inflicted near-miss**, not an RTL bug — but it's worth discussing because it almost went into the codebase as a "verified fix" on the strength of a hand-derived analysis that felt rigorous (a written bit-position trace) but wasn't actually checked against ground truth until later.
- The lesson generalizes: **for anything involving bit/byte ordering across a serial shift path, a live simulation cross-check against the bus-functional model is mandatory before treating a hand trace as ground truth.** A "the math says X" argument should always be followed by "and the waveform says X too" before it's committed.

---

## Challenge 3: Missing sensor boot sequence — a stub with a comment, not a real gap flag <a name="challenge-3"></a>

### What we found
`spi_master.v`'s `CFG_INIT` state did nothing but pick the read-burst command byte and immediately fall through to `IDLE`. The actual sensor bring-up writes (`CTRL1_XL`, `FIFO_CTRL4`, `CTRL3_C`, `INT1_CTRL`) were represented only by a comment:
```verilog
// NOTE: accelerometer init (CTRL1_XL enable, FS select,
// ODR/FIFO config) must happen here over a separate
// write sequence before relying on DRDY. Left as a
// TODO hook; this fix focuses on the read-burst FSM.
```
On real silicon, this means the IIS3DWB is left in power-down mode indefinitely — `DRDY` would never assert, and the entire downstream pipeline would simply never receive a sample.

### Why this is notable for the review
This gap was **not silent** — `tb_spi_master_full.v` (an existing, already-written testbench) explicitly checked for these four writes and was failing on exactly one check ("all 4 config writes observed") before this pass started. The test suite *had already caught this*; it had just not been acted on. This raises a process question rather than a technical one: **a pre-existing, already-failing check should block sign-off, not sit at "58/59 passing, close enough."**

### Fix approach
Implemented as a shared write datapath (one 16-bit shift counter, one address/data lookup) driven by a 2-bit index into 4-entry lookup arrays, rather than 4 separate hand-written states — 8 flops total added. First implementation attempt had the write-frame bit order backwards (`{data,addr,rw}` instead of `{rw,addr,data}}`), caught immediately by the same pre-existing testbench once actually run.

---

## Challenge 4: Stale test harness caused a hard build failure <a name="challenge-4"></a>

### What we found
`testing/apb_test/tb_spi_apb_interface.v` instantiated a module it called `tmr_stub`, typed as the real `tmr_reg_bank`, but wired to ports (`last_wr_addr`, `last_wr_data`, `wr_event`) that `tmr_reg_bank.v` does not have. Running `make` in that directory produced 4 elaboration errors and **zero test results** — not a failing test, a non-compiling one.

### Why this matters for the review
Unlike Challenge 3 (a failing-but-visible test), this test suite produced **no signal at all** — no pass count, no fail count, just a build error. If this directory wasn't run as part of a full-suite sweep, its complete absence of coverage could go unnoticed indefinitely. **A CI/regression target that silently skips a non-compiling suite is worse than one that reports failures**, because "0 tests ran" and "all tests passed" can look identical in a quick glance at a green checkmark, depending on how the runner is scripted.

### Fix
Built a purpose-scoped `tmr_slave_stub.v` (zero-wait-state APB slave, monitor ports only, no TMR/scrubbing logic — deliberately not a copy of the real register bank) and repointed the testbench and its Makefile at it.

---

## Challenge 5: `force`/`release` races when whitebox-driving an internal bus <a name="challenge-5"></a>

### What we found
`top.v` has no external command-SPI/APB port — coefficients, threshold, and `run_enable` are only reachable via `spi_apb_interface.v`'s internal APB master bus, which in real silicon would be driven by a command-SPI-to-APB bridge that sits *outside* `top.v`'s current boundary (per the module's own comments — this is an architectural boundary, not an oversight).

To load configuration in `tb_top.v`, the only option was a hierarchical, whitebox `force` onto the internal `apb_psel`/`apb_penable`/`apb_pwrite`/`apb_p_addr`/`apb_pwdata` wires. The first implementation forced each signal individually across separate statements:
```verilog
force dut.apb_psel    = 1'b1;
force dut.apb_penable = 1'b0;
...
force dut.apb_penable = 1'b1;   // one cycle later
```
`run_enable` never became `1`. Tracing showed `apb_psel` toggling correctly, but `apb_penable` never once coincided with `apb_psel=1` — the two forced signals never overlapped as intended, most likely due to event-ordering between the testbench's own `always`/`initial` processes and iverilog's per-delta-cycle scheduling of multiple independent `force` statements touching wires that are *also* driven by `spi_apb_interface.v`'s own internal `apb` master instance.

### Fix
Forced all five signals as a **single concatenated target** in one statement:
```verilog
force {dut.apb_psel, dut.apb_penable, dut.apb_pwrite, dut.apb_p_addr, dut.apb_pwdata}
      = {1'b1, 1'b1, 1'b1, {24'd0, addr}, data};
```
This eliminated the race entirely — `psel`/`penable` now reliably coexist for exactly the cycle intended.

### Discussion point for the review
This is a real gap in the design, not just a testbench quirk: **`top.v` currently has no verification-friendly way to load configuration from outside without a whitebox hack.** Two options worth discussing:
1. Accept this as intentional (the command-SPI bridge genuinely belongs outside `top.v`, per the README's own system architecture diagram) and standardize on the concatenated-force pattern for any future top-level testbenches — document it once, reuse it.
2. Consider whether a minimal test-only APB-loopback port (compiled out for synthesis via a parameter) is worth adding, if whitebox `force` patterns become a recurring pain point as more top-level tests are written.

---

## Challenge 6: Picking a fault threshold without a reference model <a name="challenge-6"></a>

### What we found
To write a meaningful "fault vs. no-fault" test in `tb_top.v`, a `cfg_threshold` value was needed that sits between "normal" and "faulted" magnitude. A hand-derived estimate (free-running Goertzel resonator, linear energy accumulation over 512 samples at amplitude 0.8) predicted a magnitude on the order of **10^9–10^13**.

Actual observed magnitude, measured live in simulation for the exact same stimulus: **on the order of 100–1500.**

That is not a rounding error — the hand estimate was roughly 6–10 orders of magnitude too high.

### Why the estimate was so far off
The hand estimate assumed unbounded linear energy growth, which is what an *undamped* resonator does in the real-number domain. But `goertzel_core.v`'s Q8.15 state (`v1`/`v2`) **saturates at ±2²³** by design (a documented, intentional RHBD/overflow-safety feature — see the saturating adder in `goertzel_core.v`). Once the free-running resonator's state saturates, it stops growing and starts oscillating with the tone's phase relative to the 512-sample block boundary — so block-to-block magnitude is **not monotonic**, and does not resemble the small-signal linear approximation at all once several thousand samples have accumulated.

### How the right value was actually found
Not derivable by formula alone for this saturating case — required instrumenting `tb_top.v` with live `mag_out` tracing, running the stimulus, and reading off the actual peak-to-peak range block by block, then picking a threshold comfortably inside that empirically-observed range.

### Discussion point for the review
**There is currently no golden/reference software model (Python or otherwise) for the saturating, free-running, 512-sample-block Goertzel magnitude behavior.** `verification/` in the repo structure is reserved for exactly this ("Golden fixed-point reference software packages (Python)") but is currently empty. Building one — even a simple bit-accurate Python model matching the Q8.15 saturation and the exact `magnitude_compute.v` formula — would have turned this multi-hour empirical-calibration exercise into a five-minute table lookup, and would give future threshold-selection decisions (including real flight configuration) a reproducible basis instead of "we tried some numbers in simulation."

---

## Challenge 7: Axis-boundary sample bleed-through in the testbench itself <a name="challenge-7"></a>

### What we found
After a fault was cleared and the stimulus amplitude moved to a new axis (e.g., `amp_x: 0.8→0.0`, `amp_y: 0.0→0.8`), the very next fault sometimes reported the **previous** axis, not the new one — a `fault_axis_latched=0` (X) trip appearing milliseconds after a Y-only tone was supposedly the only thing active.

### Root cause
This was a **test-harness pipelining issue**, not an RTL bug. A handful of samples generated under the *old* amplitude were already in flight through the multi-stage pipeline (`iis3dwb_model` → `spi_master` → `spi_apb_interface` → `axis_sequencer`) at the moment the testbench changed `amp_x`/`amp_y`. Those stale-amplitude samples landed in the axis block that was still open when the amplitude change happened, tripping a small residual fault on the *outgoing* axis right after `clear_fault()`.

### Fix
Added a `wait_for_axis_block()` task that waits for one additional `block_clear` pulse on the axis being vacated *before* trusting the next observed fault as belonging to the newly-active axis.

### Discussion point for the review
This is worth flagging even though it's testbench-only: **it demonstrates that "change a stimulus signal and immediately check the result" is not a safe pattern when the DUT has multi-stage pipelining with in-flight state**, and the same class of bug could just as easily hide a real axis-attribution latency issue in the RTL if the testbench weren't structured to rule that out explicitly. Any future test author changing per-axis stimulus mid-simulation should budget for pipeline drain time before checking axis-specific outputs.

---

## Challenge 8: Architecture documentation drift <a name="challenge-8"></a>

### What we found
`docs/top.md` (an auto-generated-looking module reference doc) listed the wrong port names (`rst_n`, `fault_flag` instead of the real `sys_rst_n`, `fault_flag_out`), was missing `sensor_drdy` and `tmr_forward_en` entirely, and listed `spi_master` as a direct child instantiation of `top` — it is actually owned internally by `spi_apb_interface` — while omitting `axis_sequencer` and `magnitude_compute` from the instantiation list altogether.

### Why this matters for the review
No tool in this environment could regenerate this doc automatically (checked — no `verilog2markdown`-style generator was available), meaning it had drifted out of sync with `top.v` through ordinary RTL evolution and nobody had a mechanism to catch the drift. This is a low-severity but recurring class of issue: **documentation that looks authoritative (a generated-looking module reference table) but isn't regenerated as part of the RTL change process will silently rot.**

---

## Cross-cutting observations for the review

1. **Every functionally-significant bug found in this pass (Challenges 1, 3) was only reachable through full-chain simulation, not module-level testing.** Both `goertzel_core.v` and `spi_master.v`'s own standalone testbenches were passing (or nearly passing) in isolation while the integrated system was fundamentally broken (no fault ever possible; sensor never configured). This is the strongest argument for treating `tb_top.v` as a permanent, first-class regression target going forward, not a one-off verification exercise.

2. **A pre-existing, already-failing test (Challenge 3) had not blocked progress.** Worth a process discussion: should any RTL change be allowed to land while an existing testbench in the suite is failing, even if that testbench isn't the one directly related to the change?

3. **Two of eight challenges (2, 6) came from a lack of an independent reference model** — one for bit/byte ordering (should have been checked against the bus-functional model immediately, not derived by hand), one for expected magnitude values (should have had a golden Python model). Both point at the same gap: `verification/` is empty, and its intended purpose (golden reference models) would have shortened this debugging pass considerably.

4. **The one design-level (not bug) gap surfaced by this pass is `top.v`'s lack of an external config-loading path for verification purposes** (Challenge 5) — worth a deliberate decision (accept whitebox testing, or add a test-only port) rather than continuing to solve it ad hoc per testbench.

5. **All fixes in this pass were area-neutral or area-negative.** The magnitude_compute.v fix removed a flip-flop; the boot-sequence and axis-tagging additions used shared datapaths/lookup tables and existing unused register bits specifically to avoid growing the TMR-protected footprint. This should be treated as the standard bar for any fix proposed in the upcoming review, not just a nice-to-have.

## Recommended process changes

- [ ] Add `verification/goertzel_reference.py` (or similar): bit-accurate Q8.15 model of `goertzel_core.v` + `magnitude_compute.v`'s exact saturation and formula, to replace empirical threshold-calibration with a computed one.
- [ ] Treat any pre-existing failing testbench as a blocking issue for the next RTL change to touch that module, not a known-acceptable baseline.
- [ ] Make `make sim_all` (or equivalent) a required, visibly-reported step before any RTL merge — specifically to catch "0 tests ran due to build failure" cases like Challenge 4, which are easy to miss in a quick glance.
- [ ] Decide and document the policy for `top.v`'s external config-loading boundary (Challenge 5) so future top-level testbenches don't each reinvent a whitebox `force` pattern independently.
- [ ] Regenerate or manually re-audit `docs/top.md` (and any other generated-looking doc) as a standard step whenever a module's port list or instantiation hierarchy changes.
- [ ] Add a standalone `magnitude_compute.v` unit testbench (it currently has none) so shared-resource timing bugs like Challenge 1 can be caught at the module level in the future, not only via full-chain simulation.
