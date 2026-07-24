# Space-Grade Mechanical Fault Detector

> **SSCS Chipathon 2026 — Track B (Sensor Circuits)**
> Radiation-hardened-by-design (RHBD) ASIC for autonomous spacecraft vibration and mechanical fault detection, built around a 3-bin **Interleaved Tri-Axis Goertzel (ITAG)** DSP core targeting the GlobalFoundries GF180MCU node via the open-source LibreLane RTL-to-GDS flow.

---

## Table of Contents

- [Reviewer Documentation](#reviewer-documentation)
- [Overview](#overview)
- [System Architecture](#system-architecture)
- [Signal Chain Walkthrough](#signal-chain-walkthrough)
- [Module Reference](#module-reference)
- [Fixed-Point Datapath](#fixed-point-datapath)
- [Radiation Hardening Strategy (RHBD)](#radiation-hardening-strategy-rhbd)
- [Area/Latency Design Tradeoff](#arealatency-design-tradeoff)
- [Verification Status](#verification-status)
- [Target Technology Configuration](#target-technology-configuration)
- [Repository Structure](#repository-structure)
- [Building and Running the Testbenches](#building-and-running-the-testbenches)
- [Team](#team)
- [Project Status](#project-status)

---

## Reviewer Documentation

The following documents directly address each point of reviewer feedback. Start here for a structured evaluation of the project.

| Reviewer Concern | Document |
|---|---|
| 📋 **Project Tracker** — progress evaluation for the circuit | [`docs/project/PROJECT_TRACKER.md`](docs/project/PROJECT_TRACKER.md) |
| 🏗️ **System Architecture** — detailed block diagram, signal chain, module hierarchy | [`docs/specs/SYSTEM_ARCHITECTURE.md`](docs/specs/SYSTEM_ARCHITECTURE.md) |
| ✅ **Verification Methodology** — what each simulation tests, expected behavior, how results confirm correctness | [`docs/verification/VERIFICATION_METHODOLOGY.md`](docs/verification/VERIFICATION_METHODOLOGY.md) |
| 🧪 **Test Scenarios** — SPI input format, per-case stimulus/output tables, all 100 check assertions | [`docs/verification/TEST_SCENARIOS.md`](docs/verification/TEST_SCENARIOS.md) |
| 🔌 **I/O Specification** — every pin, SPI protocol, output format, register map | [`docs/specs/IO_SPECIFICATION.md`](docs/specs/IO_SPECIFICATION.md) |
| 📡 **SPI Implementation** — team-developed origin, IIS3DWB compliance, references | [`docs/specs/SPI_IMPLEMENTATION.md`](docs/specs/SPI_IMPLEMENTATION.md) |
| ⚙️ **Goertzel Core Explanation** — ITAG architecture, FSM, fixed-point math, radiation hardening, simulation evidence | [`docs/specs/GOERTZEL_CORE_EXPLANATION.md`](docs/specs/GOERTZEL_CORE_EXPLANATION.md) |
| 🔬 **ITAG Architecture Analysis** — pre-implementation timing, area, power, RHBD, tradeoff analysis | [`docs/architecture/ITAG_ARCHITECTURE_ANALYSIS.md`](docs/architecture/ITAG_ARCHITECTURE_ANALYSIS.md) |

**Current verification result: 100/100 self-checking simulation assertions PASS** across all four testbench suites.

---

## Overview

Modern spacecraft and satellite systems exhibit distinct high-frequency mechanical vibration signatures prior to catastrophic mechanical failure — reaction wheel bearing degradation, cryogenic pump wear, deployment gear micro-cracks. Detecting these signatures early, at the structural edge, is critical for autonomous fault isolation and telemetry reduction.

This project implements a compact, radiation-tolerant edge-processing ASIC that performs real-time spectral vibration analysis using a custom **3-bin Interleaved Tri-Axis Goertzel (ITAG) DSP core**, targeting the GlobalFoundries 180 nm (GF180MCU) node. A single shared hardware multiplier is time-multiplexed across all three frequency bins of all three axes, plus the magnitude engine — processing X, Y and Z within every sample period rather than rotating one axis per block.

The ASIC interfaces directly with an off-chip **STMicroelectronics IIS3DWB** digital MEMS vibration sensor over SPI, computes per-axis frequency-domain energy at three programmable fault frequencies, and asserts a sticky hardware fault flag when any bin/axis combination exceeds a configurable threshold. The design is entirely flip-flop based — no SRAM macros — to keep it robust against heavy-ion-induced single event upsets (SEUs) on a commercial bulk CMOS process with no inherent radiation tolerance.

---

## System Architecture

```
                 ┌──────────────────────────────────────────────────────────────────┐
                 │                          rtl/top.v                               │
                 │                                                                  │
 IIS3DWB  ─SPI──▶│  spi_apb_interface           axis_sequencer                      │
 (sensor)        │  ├─ spi_master (FSM: boot     ├─ polls spi_apb_interface's       │
 sensor_drdy ───▶│  │  config-write + burst read) │  local STATUS/SAMPLE0/1 regs    │
                 │  └─ apb (master, Option B      ├─ demuxes the 48-bit XYZ burst   │
                 │     sample forwarding only)    │  into per-axis 16-bit samples   │
                 │                                 └─ presents X, Y, Z together    │
                 │                                        │  (no axis rotation)     │
                 │                                        ▼                         │
                 │                                 goertzel_core                    │
                 │                                 (ITAG: 3 bins x 3 axes,          │
                 │                                  shared-multiplier IIR)          │
                 │                                        │  v1/v2 state (x18)      │
                 │                                        ▼                         │
                 │                                 magnitude_compute                │
                 │                                 (owns the single multiplier.v;   │
                 │                                  computes |X(f_k)|^2 for all      │
                 │                                  9 axis/bin pairs per block)     │
                 │                                        │  mag_out + bin/axis tag │
                 │                                        ▼                         │
                 │                                 fault_flagger                    │
                 │                                 (512-sample block counter,       │
                 │                                  threshold compare, sticky flag) │
                 │                                        │                         │
                 │              ┌─────────────────────────┘                         │
                 │              ▼                                                   │
                 │        tmr_reg_bank ◀── internal APB bus ── spi_apb_interface    │
                 │        (triplicated, scrubbed config/status registers)           │
                 └──────────────────────────────────────────────────────────────────┘
                                                        │
                                                        ▼
                                              fault_flag_out (to host/RISC core)
```

`top.v` is the chip-level integration module. Its **only external pins** are the sensor SPI bus (`c_miso`/`c_csn`/`c_sclk`/`c_mosi`), the sensor's `sensor_drdy` interrupt, a `tmr_forward_en` mode-select input, and the single `fault_flag_out` alarm line — there is no separate command-SPI or host-programming bus inside the current core boundary. Runtime coefficients (`cfg_c0/c1/c2`, `cfg_threshold`) and control (`cfg_start/cfg_stop/cfg_fault_clear`) live in `tmr_reg_bank`, driven over the *internal* APB bus. In the current architecture that internal bus is exercised from testbenches via direct APB transactions; a host-facing SPI-to-APB (or other bus) bridge sitting outside `top.v`'s boundary is the natural next integration step and is called out explicitly below as future work rather than claimed as already implemented.

> 📐 For a fully detailed signal-level block diagram with per-module port descriptions, see [`docs/specs/SYSTEM_ARCHITECTURE.md`](docs/specs/SYSTEM_ARCHITECTURE.md).

![Top-level module diagram](docs/images/top_modules.svg)

---

## Signal Chain Walkthrough

1. **`spi_master`** (inside `spi_apb_interface`) runs the IIS3DWB bring-up sequence on reset — writing `CTRL1_XL` (26.667 kHz ODR), `FIFO_CTRL4` (bypass, no on-sensor FIFO), `CTRL3_C` (auto-increment burst reads), and `INT1_CTRL` (route `DRDY` to `INT1`) — then waits for `sensor_drdy`, asserts chip-select, and shifts in a 48-bit burst covering all three axes (`OUTX`, `OUTY`, `OUTZ`) in SPI Mode 3.
2. **`spi_apb_interface`** latches the 48-bit sample into local registers exposed at three byte addresses (`STATUS`, `SAMPLE0`, `SAMPLE1`), readable through a simple request/done handshake. An optional second mode (`tmr_forward_en=1`) additionally forwards each raw sample into `tmr_reg_bank` over the internal APB bus for host visibility; the default mode (`tmr_forward_en=0`) keeps the sample local only.
3. **`axis_sequencer`** polls those local registers, reconstructs the 48-bit burst, and presents all three 16-bit Q1.15 axis slices (X, Y, Z) to the core *simultaneously* — there is no longer any per-block axis rotation or `current_axis` tracking.
4. **`goertzel_core`** runs the classic second-order IIR recursion `v[n] = x[n] + C·v[n-1] − v[n-2]` for three independent frequency bins on all three axes (9 resonators total) in Q8.15 fixed-point, all sharing a single hardware multiplier via time multiplexing (18 active clock cycles per incoming sample — 6 per axis; the multiplier is otherwise held frozen for zero switching power). This is the **Interleaved Tri-Axis Goertzel (ITAG)** microarchitecture.
5. **`magnitude_compute`** owns the design's single `multiplier.v` instance, snapshots each axis/bin's `v1`/`v2` state and coefficient at the block boundary, and reuses that same shared multiplier during otherwise-idle cycles to compute `|X(f_k)|² = v1² + v2² − C·v1·v2` for all **9 axis/bin pairs**, tagging each result with both its frequency bin index and the physical axis (X/Y/Z) that produced it. The `C·v1·v2` cross term also rides the shared multiplier, so exactly one multiplier exists in the whole datapath.
6. **`fault_flagger`** owns the 512-sample block counter, compares every tagged magnitude against `cfg_threshold`, and latches a sticky `fault_flag` (plus the offending bin and axis) on the first magnitude that exceeds threshold. The flag stays asserted until explicitly cleared via `cfg_fault_clear`.
7. **`tmr_reg_bank`** is the single APB slave in the design: it holds the triplicated, periodically-scrubbed coefficient/threshold/control registers and exposes fault status for read-back.

---

## Module Reference

| Module | Source File | Description |
|---|---|---|
| `top` | `rtl/top.v` | Chip-level integration: wires the sensor SPI front end, axis sequencer, Goertzel core, magnitude engine, fault flagger, and register bank together; the only hierarchy level with external pins |
| `spi_apb_interface` | `rtl/spi_apb_interface.v` | Owns `spi_master`; exposes a local poll-based register interface for the current sensor sample, plus an optional forwarding path that mirrors each sample into `tmr_reg_bank` over the internal APB bus |
| `spi_master` | `rtl/spi_master.v` | SPI Mode 3 master implementing the IIS3DWB power-on boot config sequence and the 48-bit XYZ burst-read protocol, synchronized to the async `sensor_drdy` interrupt |
| `apb` | `rtl/apb.v` | Minimal request-driven APB master: converts a simple `req_valid`/`req_write`/`req_addr`/`req_wdata` handshake into a compliant SETUP/ACCESS APB transfer |
| `axis_sequencer` | `rtl/axis_sequencer.v` | Polls `spi_apb_interface` for each new burst and presents all three X/Y/Z slices to the core simultaneously (no axis rotation under ITAG); polling FSM is TMR-protected |
| `goertzel_core` | `rtl/goertzel_core.v` | Interleaved Tri-Axis (ITAG) 3-bin Goertzel IIR engine in Q8.15 fixed-point: 9 resonators (3 bins × 3 axes) processed every sample via a 19-state FSM sharing one multiplier; control FSM is triplicated (5-bit `vote5`) with a self-scrubbing majority voter |
| `multiplier` | `rtl/multiplier.v` | The single, chip-wide hardware multiplier — the only `*` operator in the synthesizable datapath, instanced exactly once inside `magnitude_compute`; combinational signed product, operand-isolated by its caller |
| `magnitude_compute` | `rtl/magnitude_compute.v` | Owns the shared `multiplier` instance; snapshots the 18 Goertzel state values at each block boundary and computes the per-bin, per-axis magnitude (including the `C·v1·v2` cross term) for all 9 axis/bin pairs on that one multiplier; FSM is triplicated (4-bit `vote4`) |
| `fault_flagger` | `rtl/fault_flagger.v` | Owns the 512-sample block counter, compares magnitudes against a programmable threshold, and latches a sticky fault flag with bin/axis attribution |
| `tmr_reg_bank` | `rtl/tmr_reg_bank.v` | APB slave holding the triplicated, scrubbed configuration registers (`CTRL`, `CFG_C0/C1/C2`, `CFG_THRESHOLD`) and read-only status (`STATUS`, `FAULT_MAG`, `FAULT_BIN`) |
| `ff_2_sync` | `rtl/ff_2_sync.v` | Generic two-stage D-flip-flop synchronizer used to bring the async `sensor_drdy` and `s_miso` lines into the core clock domain |
| `clk_divider` | `rtl/clk_divider.v` | Parameterized power-of-2 clock divider (÷8 default) generating the 2 MHz SPI bit clock from the 16 MHz system clock; MSB-tap, glitch-free, 50 % duty |

---

## Fixed-Point Datapath

| Signal | Width | Format |
|---|---|---|
| Sensor sample `x_n` | 16-bit | Q1.15 signed fixed-point (as delivered by `axis_sequencer`) |
| Goertzel coefficients `C0/C1/C2` | 24-bit | Q8.15 signed fixed-point, one per frequency bin, stored in `tmr_reg_bank` |
| State registers `v1_k`, `v2_k` (k = 0..2, per axis X/Y/Z) | 24-bit | Q8.15 signed fixed-point, saturating add/sub — 18 registers total (3 bins × 3 axes) |
| Shared multiplier product | 48-bit internal → 24-bit | Full product right-shifted by 15 (`>>> 15`), then saturated back to Q8.15 |
| Magnitude `\|X(f_k)\|²` | 32-bit | Unsigned integer, clamped to zero on underflow |
| Threshold `cfg_threshold` | 32-bit | Unsigned integer, host/testbench configurable |
| Block size | 512 samples | Fixed parameter in `top.v`'s `fault_flagger` instance (`BLOCK_SIZE`) |

**Recursion:** `v[n] = x[n] + C·v[n-1] - v[n-2]`, computed as a single fused three-input saturating add per active bin (no separate accumulator register — the multiplier product and the `x - v2` term are summed directly), so each axis/bin costs exactly two active clock cycles per sample (one multiplier request, one fused update) — 18 active cycles per sample for all 3 bins × 3 axes.

**Terminal magnitude:** `|X(f_k)|² = v1_k² + v2_k² - C_k·v1_k·v2_k`, computed by `magnitude_compute` for all **9 axis/bin pairs** using the single shared multiplier (four multiplies per pair, including the `C·v1·v2` cross term), scheduled entirely into the idle window after the 18-cycle Goertzel burst.

---

## Radiation Hardening Strategy (RHBD)

GlobalFoundries 180 nm bulk CMOS has no inherent radiation tolerance, so hardening is applied at the RTL and microarchitecture level:

**Triple Modular Redundancy (TMR) with self-scrubbing.** Every control FSM (`goertzel_core` with a 5-bit `vote5`, `magnitude_compute` with a 4-bit `vote4`, `axis_sequencer`'s polling FSM with a 3-bit `vote3`) and the configuration register bank (`tmr_reg_bank`) keeps three physical copies of its state, continuously combined by a bitwise 2-of-3 majority voter. Critically, all three copies are re-written from the *voted* value every cycle rather than only from each other — so a single-bit upset in one copy is corrected on the very next clock edge instead of being allowed to persist or diverge. Under ITAG the `axis_sequencer` no longer carries a triplicated axis index (there is no axis rotation), which removes that state entirely as an SEU target.

**Periodic background scrubbing.** `tmr_reg_bank`'s configuration fields are rewritten from their voted value on a fixed period (every 1024 cycles) even with no incoming write, bounding the maximum time a latent bit-flip can survive between accesses.

**SEU-safe default states.** Every triplicated FSM's next-state logic defaults to a safe idle/reset state (`S_IDLE`) for any unreachable/illegal state encoding, so an upset that produces an invalid code recovers automatically within one clock rather than hanging.

**SRAM-free register matrix.** The entire design is flip-flop only — no SRAM macros anywhere in the datapath or configuration storage — avoiding the higher single-event and multi-bit-upset sensitivity of dense memory macros on this process.

**Sticky fault latch with explicit clear.** `fault_flagger`'s fault output is a level-sensitive latch that only clears on an explicit `cfg_fault_clear` write, so a transient magnitude spike is not silently lost even if it occurs between host polls.

> Physical-level RHBD techniques (substrate tapping pitch, guard rings, spatially interleaved bus routing, relaxed placement density for antenna-diode insertion) are planned for the LibreLane physical implementation stage but are not yet reflected in a checked-in `librelane` configuration file — see [Project Status](#project-status).

---

## Area/Latency Design Tradeoff

**Constraint:** the IIS3DWB delivers X, Y, and Z samples simultaneously every 37.5 µs, but the competition's 600×600 µm die budget does not allow three parallel Goertzel pipelines.

| Option | Approach | Area Impact | Inter-axis Detection Latency | Selected |
|--------|----------|--------------|------------------------------|----------|
| 1 | Three parallel Goertzel cores (one per axis) | Exceeds die budget | 0 (all axes in parallel) | ❌ |
| 2 | Buffer all three axes, process sequentially from a sample buffer | +thousands of flip-flops, violates the SRAM-free RHBD strategy | up to 19.2 ms | ❌ |
| 3 | Single shared-multiplier core, **sequential axis rotation**, reduced block size (legacy design) | +0 flip-flops | up to 38.4 ms | ❌ |
| **4** | **Single shared-multiplier core, Interleaved Tri-Axis (ITAG) — all 3 axes every sample** | **≈ +645 flip-flops** | **0 (all axes every block)** | ✅ |

The design uses the **Interleaved Tri-Axis Goertzel (ITAG)** core (Option 4). The single hardware multiplier is time-multiplexed across all 9 (axis × bin) resonators plus the magnitude engine, so the sensor's simultaneously-delivered X/Y/Z burst is *fully* analyzed within every 375-cycle sample period (18 active cycles, ~95% idle) instead of discarding two axes per block.

This supersedes the earlier axis-sequential design (Option 3), which processed one axis per 512-sample block and rotated X→Y→Z across blocks. That approach used zero extra flip-flops but had two documented drawbacks ITAG eliminates:

- **Sequential axis processing / inter-axis latency.** Under axis rotation, only one axis accumulated Goertzel state at a time, so a given axis was observed once every three blocks — up to ~38.4 ms worst-case inter-axis latency, and a simultaneous multi-axis fault could be smeared across blocks and missed. ITAG evaluates all three axes against the threshold **every** block: **zero inter-axis latency** and cycle-accurate per-axis attribution.
- **Frequency resolution.** The legacy design shortened the block (512→171 samples) to keep the 3-axis cycle time bounded, coarsening each bin from ~52 Hz to ~157 Hz. ITAG keeps the full **512-sample** block (and its ~52 Hz resolution) because it no longer needs a shorter block to bound rotation time.

The cost is ≈ 645 additional flip-flops (18 Goertzel state registers instead of 6, the 18-value magnitude snapshot, three sample-input registers, and slightly wider FSM state), roughly 1600 µm² at 180 nm — negligible against the single shared multiplier that dominates datapath area, and far below the sample-buffering alternative (Option 2). Full analysis is in [`docs/architecture/ITAG_ARCHITECTURE_ANALYSIS.md`](docs/architecture/ITAG_ARCHITECTURE_ANALYSIS.md).

---

## Verification Status

Four testbench suites pass in simulation (Icarus Verilog), covering 100/100 self-checking assertions:

| Testbench | Target | Checks |
|---|---|---|
| `testing/spi_master_test/tb_spi_master_full.v` | `spi_master` — boot sequence, DRDY sync, SPI Mode 3 protocol, 48-bit burst read | **71/71** ✅ |
| `testing/apb_test/tb_spi_apb_interface.v` | `spi_apb_interface` + `apb` — Option A/B sample delivery and forwarding | **8/8** ✅ |
| `testing/goertzel_core/tb_goertzel_core.v` | `goertzel_core` — ITAG tri-axis independence/routing, Q8.15 arithmetic, `sample_done` timing | **7/7** ✅ |
| `testing/top_test/tb_top.v` | `top` — full sensor-to-`fault_flag_out` chain with `iis3dwb_model.v` bus-functional model | **14/14** ✅ |
| **TOTAL** | | **100/100** ✅ |

The top-level testbench exercises axis attribution end-to-end and verifies the ITAG structural invariants: exactly **9 magnitude pulses per block** (3 axes × 3 bins) with correct tag ordering, a **no-magnitude-compute-during-Goertzel-active** assertion (proving the single shared multiplier is never double-requested), and a `sample_done : block_clear` = **512 : 1** cadence check. It includes per-axis fault injection on X, Y and Z **and a simultaneous 3-axis excitation** (Case 5) — the realistic spacecraft scenario the legacy axis-sequential architecture could not resolve within a single block.

> 📖 For detailed descriptions of each test case, stimulus format, and how results confirm correct operation, see [`docs/verification/VERIFICATION_METHODOLOGY.md`](docs/verification/VERIFICATION_METHODOLOGY.md) and [`docs/verification/TEST_SCENARIOS.md`](docs/verification/TEST_SCENARIOS.md).

---

## Target Technology Configuration

| Parameter | Value |
|---|---|
| Foundry Node | GlobalFoundries GF180MCU |
| RTL-to-GDS Flow | LibreLane open-source digital flow |
| Standard Cell Library | `gf180mcu_fd_sc_mcl` |
| Source Language | Verilog HDL (IEEE 1364) |
| Core Supply Voltage | 1.8 V |
| Target Core Clock | 16 MHz (single clock domain) |
| Sensor ODR | 26.667 kHz (IIS3DWB, fixed by boot configuration) |
| Block Size | 512 samples (all three axes per block) |
| Inter-axis Detection Latency | 0 (X/Y/Z evaluated every block) |
| Per-block Latency | ~19.2 ms (512 samples @ 26.667 kHz) |

---

## Repository Structure

```
.
├── docs/
│   ├── architecture/          # Design analysis and module-level documentation
│   │   ├── ITAG_ARCHITECTURE_ANALYSIS.md   # Timing, area, power, RHBD tradeoff analysis
│   │   ├── proposal_outline.md              # Original proposal outline
│   │   └── top.md                           # Auto-generated top module port docs
│   ├── images/                # All diagrams and visual assets
│   │   ├── arch.png                         # High-level system block diagram
│   │   ├── system_architecture.png          # Detailed architecture diagram
│   │   ├── top_modules.png                  # Module hierarchy diagram (PNG)
│   │   ├── top_modules.svg                  # Module hierarchy diagram (SVG)
│   │   └── top.svg                          # Top module schematic
│   ├── project/               # Project management and proposal documents
│   │   ├── PROJECT_TRACKER.md               # ← Start here: reviewer progress tracker
│   │   ├── Project_Proposal.pdf             # Original contest proposal
│   │   ├── presentation_deck.pptx           # Presentation slides
│   │   └── vibration_sensor.pdf             # IIS3DWB sensor reference datasheet
│   ├── specs/                 # Technical specifications (reviewer focus area)
│   │   ├── SYSTEM_ARCHITECTURE.md           # Full block diagram + signal chain
│   │   ├── IO_SPECIFICATION.md              # All pins, SPI format, register map
│   │   ├── SPI_IMPLEMENTATION.md            # SPI origin, design decisions, references
│   │   └── GOERTZEL_CORE_EXPLANATION.md     # ITAG core: math, FSM, RHBD, simulation proof
│   └── verification/          # Verification plans and test documentation
│       ├── VERIFICATION_METHODOLOGY.md      # What each simulation tests and how
│       └── TEST_SCENARIOS.md                # SPI stimulus → expected output tables
│
├── rtl/                       # Synthesizable Verilog HDL source
│   ├── top.v                  # Chip-level integration (external pins)
│   ├── spi_apb_interface.v    # SPI front-end wrapper + Option A/B sample delivery
│   ├── spi_master.v           # IIS3DWB SPI Mode 3 master (boot + burst read)
│   ├── apb.v                  # Minimal APB master FSM
│   ├── axis_sequencer.v       # SPI sample demux → tri-axis simultaneous presentation
│   ├── goertzel_core.v        # ITAG 3-bin × 3-axis Goertzel IIR engine (TMR FSM)
│   ├── multiplier.v           # Single chip-wide hardware multiplier
│   ├── magnitude_compute.v    # Magnitude engine (owns multiplier, 9 pulses/block)
│   ├── fault_flagger.v        # 512-sample block counter + threshold comparator
│   ├── tmr_reg_bank.v         # APB slave: triplicated + scrubbed config/status regs
│   ├── ff_2_sync.v            # 2-stage D-FF synchronizer (CDC)
│   └── clk_divider.v          # Parameterized ÷8 SPI clock generator (2 MHz @ 16 MHz)
│
├── testing/                   # Self-checking Icarus Verilog testbenches
│   ├── spi_master_test/       # tb_spi_master_full.v (71/71 checks), iis3dwb_model.v
│   ├── apb_test/              # tb_spi_apb_interface.v (8/8 checks)
│   ├── goertzel_core/         # tb_goertzel_core.v (7/7 checks)
│   └── top_test/              # tb_top.v (14/14 checks) — full chip integration
│
├── tb/                        # (reserved for additional bus-functional models)
├── sim/                       # (reserved for simulation configs)
├── verification/              # (reserved for golden fixed-point reference models)
├── librelane/runs/            # Prior LibreLane synthesis/PnR run logs
├── Makefile                   # sim_spi / sim_apb / sim_goertzel / sim_top / sim_all
└── CHANGELOG.md               # Detailed bug-fix and verification history
```

---

## Building and Running the Testbenches

All testbenches use [Icarus Verilog](http://iverilog.icarus.com/) (`iverilog`/`vvp`). From the repository root:

```bash
make sim_spi        # spi_master standalone (IIS3DWB boot + burst read)       71/71
make sim_apb        # spi_apb_interface + apb (Option A/B sample delivery)      8/8
make sim_goertzel   # goertzel_core standalone (ITAG 3-bin x 3-axis + Q8.15)   7/7
make sim_top        # full chain: sensor SPI in -> fault_flag_out + attribution 14/14
make sim_all        # run all four suites                                      100/100
make clean          # remove generated sim binaries and VCD dumps
```

Each target produces a VCD waveform dump in its corresponding `testing/<block>/` directory, viewable with GTKWave or any other VCD viewer.

---

## Team

**B22 — Team Space Jam**
SSCS Chipathon 2026, Track B (Sensor Circuits)

---

## Project Status

- [x] System architecture implemented in RTL (`top.v` integration complete)
- [x] IIS3DWB SPI boot sequence and burst-read protocol implemented and verified
- [x] Interleaved Tri-Axis (ITAG) 3-bin Goertzel core with a single shared multiplier implemented and verified
- [x] Simultaneous tri-axis processing (all X/Y/Z evaluated every block, zero inter-axis latency)
- [x] Axis sequencing, magnitude computation, and fault flagging implemented and verified
- [x] TMR + scrubbing applied to control FSMs and configuration registers
- [x] Full-chain functional simulation passing — **100/100 checks across 4 testbench suites**
- [x] Simultaneous multi-axis fault injection testing (`tb_top.v` Case 5)
- [x] Reviewer documentation complete (system architecture, verification methodology, test scenarios, I/O spec, SPI origin, Goertzel core explanation, project tracker)
- [ ] Gate-level / post-synthesis simulation
- [ ] LibreLane synthesis and timing closure for the current RTL (`librelane/runs/` contains logs from earlier architecture iterations only)
- [ ] Physical layout, DRC/LVS sign-off, and physical-level RHBD (guard rings, substrate tapping, routing density constraints)
- [ ] Host-facing command/configuration bus bridge outside the `top.v` boundary
- [ ] Final GDS submission

---

*Built with LibreLane · GF180MCU · gf180mcu_fd_sc_mcl*
