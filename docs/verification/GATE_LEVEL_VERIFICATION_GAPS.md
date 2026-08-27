# Gate-Level & Physical Verification Gaps

> Purpose: set accurate expectations about what has and has not been verified below the RTL level,
> before cocotb gate-level work begins. Every item here is either a completed check with its result,
> or an explicitly named gap — nothing in this document is inferred or assumed.

The RTL-level functional verification (100/100 checks across four Icarus Verilog testbenches — see
[`VERIFICATION_METHODOLOGY.md`](VERIFICATION_METHODOLOGY.md)) confirms that the *design intent* is
correct. It does **not** confirm that the *synthesized, placed-and-routed netlist* behaves the same
way, or that physical sign-off is complete in every dimension a tapeout requires. This document
tracks that second, separate class of verification.

---

## 1. What has been verified at the gate/physical level

| Check | Tool | Result | Where |
|---|---|---|---|
| RTL lint | Verilator | 0 errors, 0 warnings | `S1_SYNTH/01-verilator-lint` |
| Synthesis mapping | Yosys | 0 unmapped cells, 0 inferred latches | `S1_SYNTH/06-yosys-synthesis` |
| TMR triplication survives synthesis | Manual netlist parse | 8/8 groups, 375 bits intact | `PHYSICAL_IMPLEMENTATION_RESULTS.md` §2 |
| Routing DRC | OpenROAD DRT | 0 violations | `S2_DRT/32-openroad-detailedrouting` |
| Layout DRC | Magic | 0 violations | `S3_SIGNOFF/20-magic-drc` |
| Streamout cross-check | Magic vs. KLayout XOR | 0 differences | `S3_SIGNOFF/18-klayout-xor` |
| LVS (layout vs. schematic) | Netgen | 0 errors | `S3_SIGNOFF/26-netgen-lvs` |
| Antenna rule check | OpenROAD + repair | 0 violating nets/pins | `S2_DRT` + `S3_SIGNOFF` |
| Post-PnR STA, real 62.5 ns spec, 9 PVT corners | OpenROAD | Setup & hold met, 0 violations, 0 TNS, all corners | `S3_SIGNOFF/11-openroad-stapostpnr` |

These are real, tool-verified results — not estimates. Layout DRC, LVS, and timing closure are in a
genuinely good state.

---

## 2. What has not been done, and why it matters

### 2.1 No RTL-to-netlist formal equivalence check

`Yosys.EQY` is present in the LibreLane Classic flow but was gated off (`False`) in both `S1_SYNTH`
and `S3_SIGNOFF` (`Gating variable for step 'Yosys.EQY' set to 'False'`). This step formally proves
the synthesized netlist implements the same function as the RTL. Without it, the TMR-survival check
in this project (parsing bit widths in the netlist) is a **structural** check, not a **functional**
one — it confirms the three copies of each register exist and are the same width, but not that the
voting/scrubbing logic around them synthesized correctly.

**Recommended before tapeout:** enable `Yosys.EQY` for at least the final signoff run.

### 2.2 No gate-level simulation

Nine corner-specific SDF files exist (`build/top/sdf/*.sdf`, one per PVT corner) but have never been
used in a simulation. All functional confidence today comes from RTL-level Icarus Verilog testbenches.
A gate-level simulation (Verilog netlist + SDF back-annotation) is the standard way to catch:
- Synthesis optimizations that change behavior in edge cases the RTL testbench didn't cover
- Timing-dependent races that don't exist in the zero-delay RTL simulation
- X-propagation / uninitialized-state issues masked by RTL simulator defaults

**This is the natural target for the planned cocotb work.** Recommended scope: re-run the existing
four testbench scenarios (`tb_spi_master_full.v`, `tb_spi_apb_interface.v`, `tb_goertzel_core.v`,
`tb_top.v`) against `build/top/nl/top.nl.v` with SDF back-annotation from at least the two extreme
corners (`max_ss_125C_4v50` — slowest, `min_ff_n40C_5v50` — fastest) to bound the timing envelope.

### 2.3 KLayout DRC did not run

The flow log states directly: `KLAYOUT_DRC_RUNSET is unset. KLayout.DRC may not be supported for the
gf180mcuD PDK. This step will be skipped.` DRC sign-off currently rests on **Magic alone**, with a
KLayout XOR pass confirming the two tools' GDS streamouts are geometrically identical (0 differences)
— but XOR is not a rule check, it only proves both streamout paths produced the same shapes.

**Impact:** if Magic's DRC deck has any gaps or bugs specific to gf180mcuD, there is no independent
rule-check tool catching it. This is a PDK/tooling limitation, not a project oversight, but it should
be stated explicitly rather than silently treated as "DRC clean" without qualification.

### 2.4 IR drop analysis is not chip-representative

The flow log warns: `'VSRC_LOC_FILES' was not given a value, which may make the results of IR drop
analysis inaccurate.` No real voltage-source/pad locations were supplied. The reported worst IR drop
(**131 µV** at macro level, post-re-harden) assumes power delivered uniformly at the macro's
boundary — it reflects LibreLane's default, not any actual pad geometry.

**This has since been made worse, not better, by the padring integration.** The macro is now placed
in a chip-level padring (`slot_1x1`, top-left, signed off clean — see
[`padring/README.md`](../../padring/README.md)), but `VSRC_LOC_FILES` was never set at chip level
either. The chip-top run reports `ir__drop__worst = 0.5 µV` and `power__total = 0.255 mW` — the
latter is *below* the macro's own 47 mW, because the macro is a `.lib` black box at chip level with
no activity annotation, so chip-level power/IR analysis cannot see inside it. **Neither figure
(macro's 131 µV nor chip's 0.5 µV) should be treated as a sign-off result.** Closing this properly
requires setting `VSRC_LOC_FILES` to the real pad coordinates at chip level, with the macro's actual
power profile annotated.

### 2.5 Reset-path DRV violations: retracted — and the one thing that remains open

**The DRV half of this gap is closed.** Earlier revisions claimed 260 max-slew and 8 max-cap
violations traceable to `sys_rst_n`'s fanout tree. That was wrong on three counts, all verified:

- The counts are measured against the project's own SDC limits (`set_max_transition 3.0`,
  `set_max_capacitance 0.2`), which are tighter than the library's own (7 ns uniform, and per-pin
  0.058–4.9 pF). A liberty-limits-only OpenSTA re-check of the signed-off netlist plus extracted
  `max` SPEF reports **0 slew, 0 cap, 0 fanout violators**.
- The violators are not on the reset net at all — `grep rst` over
  `S3_SIGNOFF/11-openroad-stapostpnr/max_ss_125C_4v50/checks.rpt` returns **0 hits**. They are
  spread across the Goertzel datapath and the flow's own CTS/repair cells.
- The counts quoted (260 / 8) were from a superseded run; the current signoff reports 2864 / 196
  against the SDC limits, and 0 / 0 against the library's.

See [`PHYSICAL_IMPLEMENTATION_RESULTS.md` §4.3](../architecture/PHYSICAL_IMPLEMENTATION_RESULTS.md)
for the full experiment and the waiver rationale. `MAX_FANOUT_CONSTRAINT: 20` reports 0 violations
on every corner, so the reset distribution is within its declared bound.

**What remains genuinely open** is the analysis gap, which is independent of the DRV question:
reset recovery/removal timing between the three TMR copies has never been checked, because
`set_false_path -from [get_ports sys_rst_n]` removes the net from timing analysis by definition. The
self-scrubbing voter
   architecture makes a skew-induced correctness bug unlikely, but this should be stated as an
   explicit, reasoned RHBD claim rather than left unaddressed.

### 2.6 No formal property verification

Listed in the project tracker as future work and still open: FSM reachability, illegal-state
recovery, and SEU-injection properties for the TMR voters are documented as RTL claims (backed by the
`S_IDLE` default-case argument in the RHBD write-ups) but have not been formally verified or
fault-injection tested at either the RTL or gate level.

---

## 3. Priority order for closing these gaps

Given the stated plan to add cocotb support next, the highest-leverage sequence is:

1. **Gate-level simulation via cocotb** (§2.2) — directly answers "does the actual synthesized,
   routed netlist behave like the RTL," which is the question every other gap is a proxy for.
2. **Enable `Yosys.EQY`** (§2.1) — cheap to turn on, gives a formal equivalence proof to back the
   structural TMR check that already exists.
3. **Decide and act on the reset DRV violations** (§2.5) — either fix or write the waiver; this is
   the only open item that is a genuine (if small) design decision rather than pure verification.
4. **Chip-level IR drop re-run** (§2.4) and **KLayout DRC** (§2.3) are both blocked on external
   inputs (padring placement; a working gf180mcuD KLayout ruleset) and cannot be closed unilaterally
   — track them, don't block on them.

---

*Companion to [`PHYSICAL_IMPLEMENTATION_RESULTS.md`](../architecture/PHYSICAL_IMPLEMENTATION_RESULTS.md).
Last verified: 2026-08-22.*

---

## 5. Status update (2026-08-27) — gate-level sim run, SEU coverage added

### 5.1 Gate-level simulation: 6 / 8 pass, and the 2 failures are testbench-only

`make test-top-gl` was run to completion against the signed-off netlist
(`build/top/nl/top.nl.v`) with the real `gf180mcu_fd_sc_mcu7t5v0` cell models
(`-DFUNCTIONAL -DUNIT_DELAY=#1`). Result: **TESTS=8 PASS=6 FAIL=2**, 17.5 min wall time.

| Test | Gate-level | Note |
|---|---|---|
| `test_case1_no_fault_baseline` | **PASS** | |
| `test_case2_fault_on_x` | **PASS** | |
| `test_case3_fault_on_y` | **PASS** | |
| `test_case4_fault_on_z` | **PASS** | |
| `test_case5_simultaneous_3axis_fault` | **PASS** | |
| `test_case6_fault_clear` | **PASS** | |
| `test_itag_9_mag_pulses_per_block` | FAIL | probes `dut.mag_inst.mag_mult_req` |
| `test_itag_no_multiplier_contention` | FAIL | probes `dut.goertzel_inst.mult_req` |

**Root cause of both failures: testbench portability, not a silicon defect.** Those two tests are
structural invariants that probe *internal combinational wires*. Synthesis eliminates them —
`grep` for `mult_req` and `mag_mult_req` in `top.nl.v` returns **0 occurrences each**. cocotb
therefore cannot resolve the handle. The six *functional* tests probe only top-level pins
(`fault_flag_out`, `c_csn`, `sensor_drdy`, `clk`), all of which survive synthesis, and all six pass.

**Disposition:** mark tests 7-8 **RTL-only**. They are valid RTL assertions about the shared-
multiplier schedule and should keep running in the pre-synthesis suite; they are not portable to a
flattened netlist and should not be counted as gate-level failures.

### 5.2 Why more gate-level simulation is the wrong investment

GL sim took **17.5 minutes for 6 tests** versus ~148 s for the same tests at RTL — roughly 7x
slower here, and far worse on larger designs. Industry PD practice is *not* to re-run the
functional regression at gate level. The equivalence guarantee comes from **formal logic
equivalence checking** (Conformal / Formality commercially; **Yosys EQY** in the open-source flow),
which proves RTL == netlist for all input sequences rather than for the vectors you happened to
write. GL sim is then reserved for what LEC structurally cannot see: power-up and X-propagation,
reset sequencing, and SDF-back-annotated timing on a handful of critical vectors.

An EQY setup now exists at [`verification/top.eqy`](../../verification/top.eqy). Note that the
`hpretl/iic-osic-tools:chipathon26` image ships EQY with its Yosys plugins in
`/foss/tools/yosys/share/yosys/plugins/` while the `eqy` driver looks for them in
`/foss/tools/bin/` — symlinking them there is required before EQY will get past its `combine`
step. **EQY has been launched but has not yet completed on this design; no equivalence result is
claimed.**

### 5.3 SEU / TMR coverage — gap closed

§2 previously noted that the RHBD claim was only verified *structurally* (the Stage-1 netlist check
proves the three copies survive synthesis). [`tb/test_seu.py`](../../tb/test_seu.py) now closes
that gap with **3/3 passing** fault-injection tests against `goertzel_core` (`make test-seu`):

| Property | Test | Result |
|---|---|---|
| Voter **masks** a single upset | `test_seu_single_copy_is_masked` | **PASS** — all 5/5 single-bit upsets in copy A absorbed; the voted state always followed the two healthy copies |
| **Self-scrubbing** repairs the copy | `test_seu_is_scrubbed_next_clock` | **PASS** — triplet re-converged one clock after a multi-bit corruption |
| **Illegal state** recovers | `test_seu_illegal_state_recovers_to_idle` | **PASS** — unreachable encoding `0x13` returned to `S_IDLE` in one clock |

What these tests do **not** prove: they inject at RTL, so they establish the *logical* correctness
of the voter and the self-scrubbing write-back — not the physical SEU cross-section of the layout
(spatial separation of the three copies, guard rings, substrate tapping), which remains a
chip-level physical-RHBD item.
