# Space-Grade Mechanical Fault Detector — Project Tracker

> **SSCS Chipathon 2026 — Track B (Sensor Circuits) | Team B22 — Team Space Jam**
> Last updated: 2026-08-22

---

## Executive Summary

The project implements an autonomous radiation-hardened ASIC for spacecraft vibration fault detection using the **Interleaved Tri-Axis Goertzel (ITAG)** DSP algorithm, targeting GlobalFoundries GF180MCU via the LibreLane open-source RTL-to-GDS flow. All RTL is implemented, all four testbench suites pass (100/100 checks), and the full-chip integration simulation is verified end-to-end.

Physical implementation is now complete for the `top` macro: synthesis, place-and-route, and signoff
all pass with clean DRC/LVS/XOR/antenna and timing closed (setup + hold met, 0 violations) across all
9 PVT corners. See [`PHYSICAL_IMPLEMENTATION_RESULTS.md`](../architecture/PHYSICAL_IMPLEMENTATION_RESULTS.md)
for full metrics and [`GATE_LEVEL_VERIFICATION_GAPS.md`](../verification/GATE_LEVEL_VERIFICATION_GAPS.md)
for what remains before this is tapeout-ready (gate-level simulation, equivalence checking, and a
few chip-integration-dependent items).

---

## Reviewer Feedback Resolution Matrix

| # | Reviewer Concern | Status | Resolution Document |
|---|---|---|---|
| 1 | Design documentation: circuit schematic or detailed system architecture | ✅ **DONE** | [`docs/specs/SYSTEM_ARCHITECTURE.md`](../specs/SYSTEM_ARCHITECTURE.md) |
| 2 | Verification methodology: explain what each simulation demonstrates | ✅ **DONE** | [`docs/verification/VERIFICATION_METHODOLOGY.md`](../verification/VERIFICATION_METHODOLOGY.md) |
| 3 | System-level integration: simulate the complete integrated system | ✅ **DONE** | `testing/top_test/tb_top.v` — 14/14 checks PASS |
| 4 | Test scenarios: representative SPI input → expected output cases | ✅ **DONE** | [`docs/verification/TEST_SCENARIOS.md`](../verification/TEST_SCENARIOS.md) |
| 5 | I/O definition: SPI format, output type (analog/SPI/digital) | ✅ **DONE** | [`docs/specs/IO_SPECIFICATION.md`](../specs/IO_SPECIFICATION.md) |
| 6 | SPI implementation: origin, references, or team-developed | ✅ **DONE** | [`docs/specs/SPI_IMPLEMENTATION.md`](../specs/SPI_IMPLEMENTATION.md) |
| 7 | Core module explanation: architecture, functionality, simulation evidence | ✅ **DONE** | [`docs/specs/GOERTZEL_CORE_EXPLANATION.md`](../specs/GOERTZEL_CORE_EXPLANATION.md) |
| 8 | Project tracker to evaluate circuit progress | ✅ **DONE** | This document |

---

## Phase-by-Phase Progress

### Phase 1 — Architecture & Specification ✅ COMPLETE

| Task | Status | Notes |
|---|---|---|
| System architecture defined | ✅ DONE | `rtl/top.v`, `docs/specs/SYSTEM_ARCHITECTURE.md` |
| Module partitioning | ✅ DONE | 12 RTL modules across 4 functional zones |
| Fixed-point datapath specification (Q8.15) | ✅ DONE | `docs/specs/SYSTEM_ARCHITECTURE.md` §Fixed-Point |
| RHBD strategy documented | ✅ DONE | TMR on all FSMs + config regs + SRAM-free |
| I/O interface specification | ✅ DONE | `docs/specs/IO_SPECIFICATION.md` |
| SPI protocol documented | ✅ DONE | `docs/specs/SPI_IMPLEMENTATION.md` |
| ITAG architecture analysis | ✅ DONE | `docs/architecture/ITAG_ARCHITECTURE_ANALYSIS.md` |

### Phase 2 — RTL Implementation ✅ COMPLETE

| Module | Status | RHBD Features | Notes |
|---|---|---|---|
| `spi_master.v` | ✅ DONE | Async signal CDC (2-FF sync) | IIS3DWB boot sequence + SPI Mode 3 burst read |
| `ff_2_sync.v` | ✅ DONE | CDC primitive | 2-stage D-FF synchronizer |
| `clk_divider_5.v` | ✅ DONE | — | SPI clock generation (÷5) |
| `spi_apb_interface.v` | ✅ DONE | Edge-qualified req_valid | Option A/B sample delivery |
| `apb.v` | ✅ DONE | — | Minimal APB master FSM |
| `axis_sequencer.v` | ✅ DONE | TMR polling FSM (3-bit vote3) | ITAG: simultaneous X/Y/Z presentation |
| `goertzel_core.v` | ✅ DONE | TMR FSM (5-bit vote5) | 19-state ITAG, 18 v-state regs, Q8.15 |
| `multiplier.v` | ✅ DONE | Operand isolation | Single chip-wide hardware multiplier |
| `magnitude_compute.v` | ✅ DONE | TMR FSM (4-bit vote4) | 9 mag pulses/block, single multiplier |
| `fault_flagger.v` | ✅ DONE | TMR block counter | 512-sample block, sticky fault flag |
| `tmr_reg_bank.v` | ✅ DONE | TMR + 1024-cycle scrub | APB slave, config/status registers |
| `top.v` | ✅ DONE | — | Full integration wiring |

### Phase 3 — Functional Verification ✅ COMPLETE

| Testbench | Coverage | Result | Checks |
|---|---|---|---|
| `tb_spi_master_full.v` | Boot sequence, SPI Mode 3, DRDY, 48-bit burst | ✅ PASS | 71/71 |
| `tb_spi_apb_interface.v` | Option A/B sample delivery, APB forwarding | ✅ PASS | 8/8 |
| `tb_goertzel_core.v` | ITAG tri-axis independence, Q8.15 accuracy, sample_done timing | ✅ PASS | 7/7 |
| `tb_top.v` | Full sensor-to-fault_flag chain, per-axis attribution, simultaneous 3-axis | ✅ PASS | 14/14 |
| **TOTAL** | | **✅ ALL PASS** | **100/100** |

### Phase 4 — Documentation (Addressing Reviewer Feedback) ✅ COMPLETE

| Document | Status | Addresses |
|---|---|---|
| `docs/specs/SYSTEM_ARCHITECTURE.md` | ✅ DONE | Reviewer item #1: detailed architecture |
| `docs/verification/VERIFICATION_METHODOLOGY.md` | ✅ DONE | Reviewer item #2: verification methodology |
| `docs/verification/TEST_SCENARIOS.md` | ✅ DONE | Reviewer item #4: test scenarios with SPI stimulus |
| `docs/specs/IO_SPECIFICATION.md` | ✅ DONE | Reviewer item #5: I/O format definitions |
| `docs/specs/SPI_IMPLEMENTATION.md` | ✅ DONE | Reviewer item #6: SPI origin and references |
| `docs/specs/GOERTZEL_CORE_EXPLANATION.md` | ✅ DONE | Reviewer item #7: core module explanation |
| `docs/project/PROJECT_TRACKER.md` | ✅ DONE | Reviewer item #8: this tracker |

### Phase 5 — Physical Implementation 🔄 IN PROGRESS (macro hardened, chip integration + gate-level sim remain)

The flow is split into three independently re-runnable LibreLane stages
(`S1_SYNTH` → `S2_DRT` → `S3_SIGNOFF`), driven from `librelane/01_fault_detector_macro.ipynb`. Full
results: [`PHYSICAL_IMPLEMENTATION_RESULTS.md`](../architecture/PHYSICAL_IMPLEMENTATION_RESULTS.md).

| Task | Status | Notes |
|---|---|---|
| LibreLane synthesis (current ITAG RTL) | ✅ DONE | `S1_SYNTH`: 0 lint errors, 0 unmapped cells, 0 inferred latches |
| TMR survival through synthesis | ✅ DONE | 8/8 triplet groups, 375 bits confirmed intact in gate netlist |
| Physical layout (place & route) | ✅ DONE | `S2_DRT`: 800×800 µm die, 60.9% utilization, 0 routing DRC, 0 antenna |
| Timing closure at 16 MHz (62.5 ns) | ✅ DONE | Setup + hold met, 0 violations, 0 TNS on all 9 PVT corners |
| DRC / LVS sign-off | 🔄 PARTIAL | Magic DRC 0, LVS 0, XOR 0 — **KLayout DRC ruleset unavailable for gf180mcuD, step skipped** |
| Final GDS produced | ✅ DONE | `build/top/gds/top.gds` + LEF + 9-corner LIB + netlist + SPEF/SDF/DEF/SPICE |
| Die size vs. original 600×600 µm budget | ⚠️ REVISED | Actual signed-off die is **800×800 µm** — see note below and ITAG analysis addendum |
| DRV cleanup: reset-net max-slew/max-cap violations | ⬜ OPEN | 260 slew + 8 cap violations, root-caused to false-pathed `sys_rst_n` fanout (125–280 flops/branch); needs fix-or-waive decision |
| Formal RTL↔netlist equivalence (Yosys EQY) | ⬜ TODO | Gated off in both synthesis and signoff runs |
| Gate-level / post-synthesis simulation | ⬜ TODO | 9-corner SDF exists (`build/top/sdf/`) but unused — **this is the next planned step (cocotb)** |
| Physical RHBD (guard rings, substrate tapping) | ⬜ TODO | Not yet reflected in LibreLane config; no padring/chip-top yet to apply it against |
| Chip-audit registration (multi-team padring) | ⬜ TODO | Team B22 not yet present in the chipathon's GDS audit sheet; slot size/type unconfirmed |
| Cell-name collision cleanup for chip-level merge | ⬜ TODO | Top cell currently named `top`; OpenROAD-generated via cells are unprefixed — both are collision risks in a merged multi-team GDS |
| IR drop analysis at chip scale | ⬜ BLOCKED | Current 109 µV figure has no real supply-pad locations (`VSRC_LOC_FILES` unset) — must re-run once padring position is known |
| Final GDS submission | ⬜ TODO | Pending audit registration + slot confirmation above |

**Die size note:** the original architecture documentation targeted a ~600×600 µm die budget as a
design-time estimate. The actual macro requires 391,518 µm² of core area at achievable placement
density, and closes timing cleanly at 800×800 µm; a 650×650 µm attempt failed setup timing by
−19.0 ns. Reaching 600×600 µm would require a dedicated area-reduction pass, not a floorplan
adjustment — tracked as an open decision, not a regression.

### Phase 6 — Future Work / Nice-to-Have

| Task | Status | Notes |
|---|---|---|
| Host-facing command/config bus bridge (SPI-to-APB) | ⬜ TODO | Currently exercised via testbench APB direct writes |
| Power characterization (post-synthesis switching activity) | ✅ DONE | Measured at signoff: 46.4 mW total — see [`PHYSICAL_IMPLEMENTATION_RESULTS.md`](../architecture/PHYSICAL_IMPLEMENTATION_RESULTS.md) §4.6 |
| Formal property verification | ⬜ TODO | FSM reachability, SEU recovery properties — see [`GATE_LEVEL_VERIFICATION_GAPS.md`](../verification/GATE_LEVEL_VERIFICATION_GAPS.md) §2.6 |

---

## Key Metrics

| Metric | Value |
|---|---|
| RTL modules implemented | 12 |
| Total testbench check assertions | 100/100 PASS |
| Estimated flip-flop count (RTL) | ~645 DFF above baseline (ITAG delta) |
| Shared hardware multipliers | 1 (structural, grep-auditable) |
| Goertzel bins per axis | 3 (programmable frequencies) |
| Axes processed per sample period | 3 (X, Y, Z — zero inter-axis latency) |
| Active cycles per sample period | 18 / 375 (~4.8%) |
| Block size | 512 samples = 19.2 ms |
| Detection latency (any axis) | ≤ 19.2 ms |
| RHBD: TMR FSMs | 3 (goertzel_core, magnitude_compute, axis_sequencer) |
| RHBD: TMR config registers | Yes (tmr_reg_bank, 1024-cycle scrub) |
| RHBD: SRAM macros | 0 (fully flip-flop based) |
| **Post-synthesis flip-flop count (gate netlist)** | **1,767** |
| **TMR triplicated state bits (gate netlist)** | **375 bits, 8/8 groups intact** |
| **Signed-off die size** | **800 × 800 µm (640,000 µm²)** |
| **Core utilization** | **60.9%** |
| **Setup slack, worst corner** | **+11.84 ns @ max_ss_125C_4v50** |
| **Hold slack, worst corner** | **+0.127 ns @ min_ff_n40C_5v50** |
| **Timing violations (9 corners)** | **0 setup, 0 hold, 0 TNS** |
| **DRC / LVS / XOR / antenna** | **0 / 0 / 0 / 0** |
| **Total power (signoff)** | **46.4 mW** (35.0 internal + 11.4 switching + 5.2 µW leakage) |

---

## Known Open Issues

| Issue | Severity | Mitigation |
|---|---|---|
| Gate-level simulation not yet run | Medium | 9-corner SDF exists in `build/top/sdf/`; RTL simulation passes; **this is the next planned step (cocotb)** |
| No formal RTL↔netlist equivalence check (Yosys EQY) | Medium | TMR survival confirmed structurally (bit-width parse of netlist); EQY would make this a formal proof |
| Reset-net max-slew/max-cap DRV violations (260 slew + 8 cap, worst corner) | Medium | Root-caused to false-pathed `sys_rst_n` fanout tree (125–280 flops/branch on `/RN`); benign at current clock margin but needs a fix-or-waive decision — see [`GATE_LEVEL_VERIFICATION_GAPS.md`](../verification/GATE_LEVEL_VERIFICATION_GAPS.md) |
| KLayout DRC did not run (ruleset unavailable for gf180mcuD) | Low–Medium | Magic DRC (0 errors) + KLayout XOR cross-check (0 differences) are the current DRC evidence; independent rule-check coverage is incomplete |
| IR drop analysis not chip-representative | Low (for now) | `VSRC_LOC_FILES` unset — no real pad locations yet; current 109 µV figure must be re-run once padring position is known |
| Die size grew from ~600×600 µm target to signed-off 800×800 µm | Medium | 650×650 µm failed setup by −19 ns; 800×800 closes cleanly. Reaching 600×600 needs a dedicated area-reduction pass, tracked separately |
| Team B22 not yet registered in the chipathon's multi-team GDS audit sheet | High (process) | Slot type/size unconfirmed; blocks chip-level integration planning |
| Cell-name collision risk for chip-level GDS merge | Medium | Top cell named `top`; unprefixed OpenROAD via cells (`VIA_Via1_HV`, etc.) — both are generic names likely to collide with other teams' submissions |
| Host-facing command bus not inside `top.v` boundary | Low | Documented as future work; testbench exercises via direct APB |
| `proposal_outline.md` module table references stale module names | Low | Main `README.md` is accurate and up-to-date |

---

*Updated after completing the 3-stage LibreLane physical implementation flow
(`S1_SYNTH` → `S2_DRT` → `S3_SIGNOFF`) with clean signoff metrics — 2026-08-22.*
