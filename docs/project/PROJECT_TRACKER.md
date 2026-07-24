# Space-Grade Mechanical Fault Detector — Project Tracker

> **SSCS Chipathon 2026 — Track B (Sensor Circuits) | Team B22 — Team Space Jam**
> Last updated: 2026-07-22

---

## Executive Summary

The project implements an autonomous radiation-hardened ASIC for spacecraft vibration fault detection using the **Interleaved Tri-Axis Goertzel (ITAG)** DSP algorithm, targeting GlobalFoundries GF180MCU via the LibreLane open-source RTL-to-GDS flow. All RTL is implemented, all five testbench suites pass (108/108 checks), and the full-chip integration simulation — including external coefficient reception over the command-SPI bus — is verified end-to-end.

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
| `clk_divider.v` | ✅ DONE | — | SPI clock generation (÷8) |
| `spi_apb_interface.v` | ✅ DONE | Edge-qualified req_valid | Option A/B sample delivery |
| `apb.v` | ✅ DONE | — | Minimal APB master FSM |
| `cmd_spi_slave.v` | ✅ DONE | 2-FF sync (cmd_sclk/csn/mosi) | External command-SPI config receiver (RISC-V coefficient/threshold/control) |
| `apb_arb2.v` | ✅ DONE | — | 2:1 APB arbiter (command config + sample forwarder) |
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
| `tb_cmd_spi.v` | External coefficient/threshold/control reception via `top`'s command-SPI pins | ✅ PASS | 8/8 |
| **TOTAL** | | **✅ ALL PASS** | **108/108** |

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

### Phase 5 — Physical Implementation 🔄 IN PROGRESS

| Task | Status | Notes |
|---|---|---|
| LibreLane synthesis (current RTL) | ⬜ TODO | Prior runs in `librelane/runs/` from older arch iteration |
| Timing closure at 16 MHz | ⬜ TODO | Target: all paths < 62.5 ns |
| Physical layout (place & route) | ⬜ TODO | 600×600 µm die target |
| DRC / LVS sign-off | ⬜ TODO | GF180MCU design rules |
| Physical RHBD (guard rings, substrate tapping, routing constraints) | ⬜ TODO | Planned for LibreLane config |
| Gate-level / post-synthesis simulation | ⬜ TODO | Back-annotated netlist verification |
| Final GDS submission | ⬜ TODO | Contest deadline target |

### Phase 6 — Future Work / Nice-to-Have

| Task | Status | Notes |
|---|---|---|
| Host-facing command/config bus bridge (SPI-to-APB) | ⬜ TODO | Currently exercised via testbench APB direct writes |
| Power characterization (post-synthesis switching activity) | ⬜ TODO | RTL estimates in `docs/architecture/ITAG_ARCHITECTURE_ANALYSIS.md` |
| Clock/power gating evaluation | ✅ DONE (no RTL change) | Evaluated and rejected — see §3.1 of `ITAG_ARCHITECTURE_ANALYSIS.md`. Existing operand isolation (multiplier) + synchronous enable-gating (all conditionally-loaded registers) already capture the zero-area-cost win; standalone ICG insertion is not area-neutral and risks masking TMR scrub self-correction. |
| Formal property verification | ⬜ TODO | FSM reachability, SEU recovery properties |

---

## Key Metrics

| Metric | Value |
|---|---|
| RTL modules implemented | 12 |
| Total testbench check assertions | 108/108 PASS |
| Estimated flip-flop count (RTL) | ~645 DFF above baseline (ITAG delta) |
| Shared hardware multipliers | 1 (structural, grep-auditable) |
| Goertzel bins per axis | 3 (programmable frequencies) |
| Axes processed per sample period | 3 (X, Y, Z — zero inter-axis latency) |
| Active cycles per sample period | 18 / 600 (~3.0%) |
| Block size | 512 samples = 19.2 ms |
| Detection latency (any axis) | ≤ 19.2 ms |
| RHBD: TMR FSMs | 3 (goertzel_core, magnitude_compute, axis_sequencer) |
| RHBD: TMR config registers | Yes (tmr_reg_bank, 1024-cycle scrub) |
| RHBD: SRAM macros | 0 (fully flip-flop based) |

---

## Known Open Issues

| Issue | Severity | Mitigation |
|---|---|---|
| Gate-level simulation not yet run | Medium | RTL simulation passes; gate-level to be added post-synthesis |
| LibreLane synthesis with current ITAG RTL not yet executed | Medium | Prior run logs exist for older architecture; re-run planned |
| Host-facing command bus not inside `top.v` boundary | Low | Documented as future work; testbench exercises via direct APB |
| `proposal_outline.md` module table references stale module names | Low | Main `README.md` is accurate and up-to-date |

---

*Updated after full simulation run confirming 108/108 checks passing (adds external command-SPI coefficient reception) — 2026-07-24*
