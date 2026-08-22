# Physical Implementation Results — `top` Macro (LibreLane / GF180MCU)

> **Status:** Macro physically signed off (DRC/LVS/XOR/antenna clean, timing closed on all 9 corners).
> **Not yet:** chip-audit registration, cell-name collision cleanup, gate-level equivalence/simulation.
> See [`GATE_LEVEL_VERIFICATION_GAPS.md`](../verification/GATE_LEVEL_VERIFICATION_GAPS.md) for what
> remains before this can be called tapeout-ready.

This document records the actual, measured results of the RTL-to-GDSII flow for the `top` macro
(Interleaved Tri-Axis Goertzel vibration-fault detector), run inside the
`hpretl/iic-osic-tools:chipathon26` container against the **gf180mcuD** PDK using **LibreLane v3.0.2**.
Every number below is read from the flow's own metrics/report files, not estimated.

---

## 1. Flow structure: three independently re-runnable stages

The Classic flow is deliberately split into three LibreLane runs chained through `state_out.json`
handoffs, rather than one monolithic run. This means iterating on floorplan/CTS knobs re-runs only
Stage 2, and iterating on signoff settings re-runs only Stage 3 — synthesis is never repeated.

| Stage | Run tag | Step range | Purpose |
|---|---|---|---|
| **1 — Synthesis** | `S1_SYNTH` | `Verilator.Lint` → `OpenROAD.STAPrePNR` | Netlist + pre-placement timing reference + TMR survival gate |
| **2 — Floorplan → DRT** | `S2_DRT` | `OpenROAD.Floorplan` → `OpenROAD.DetailedRouting` | Routing completion gate (DRC/antenna/PDN legality) |
| **3 — Signoff** | `S3_SIGNOFF` | `Odb.RemoveRoutingObstructions` → `Checker.LVS` | GDS streamout, DRC/LVS/XOR, real-spec STA, power/IR |

Driven from `librelane/01_fault_detector_macro.ipynb`. All three stages completed with
`Flow complete.` and an empty `error.log`.

---

## 2. Stage 1 — Synthesis

**Config:** `CLOCK_PORT=clk`, `CLOCK_PERIOD=62.5 ns` (16 MHz), `SYNTH_STRATEGY: "AREA 3"`,
`MAX_FANOUT_CONSTRAINT: 10`. STA at this stage is pre-placement (ideal clock, no wire load) and is a
netlist-quality signal, not a timing sign-off.

| Metric | Value |
|---|---|
| Total cell instances | 16,223 |
| Sequential cells (flip-flops) | 1,767 |
| Inferred latches | 0 |
| Unmapped cells | 0 |
| Lint errors / warnings | 0 / 0 |
| Cell area (synthesis estimate) | 336,313 µm² |

### TMR survival check (the RHBD gate)

Every triplicated register in the RTL is declared `(* keep = "true" *) reg ... x_a, x_b, x_c` across
five files (`tmr_reg_bank.v`, `axis_sequencer.v`, `goertzel_core.v`, `magnitude_compute.v`,
`fault_flagger.v`). Without the attribute, Yosys can prove the three copies equivalent and collapse
them, silently removing the TMR protection. The synthesized netlist (`top.nl.v`) was parsed directly
to confirm all three copies survive with identical bit widths:

| Triplicated register | a | b | c | Status |
|---|---|---|---|---|
| `axseq_inst.ps` (axis-sequencer FSM, vote3) | 3 | 3 | 3 | OK |
| `goertzel_inst.state` (Goertzel FSM, vote5) | 5 | 5 | 5 | OK |
| `mag_inst.ms` (magnitude-compute FSM, vote4) | 4 | 4 | 4 | OK |
| `ff_inst.cnt` (fault-flagger block counter) | 9 | 9 | 9 | OK |
| `tmr_inst.c0` (Goertzel coefficient C0) | 24 | 24 | 24 | OK |
| `tmr_inst.c1` (Goertzel coefficient C1) | 24 | 24 | 24 | OK |
| `tmr_inst.c2` (Goertzel coefficient C2) | 24 | 24 | 24 | OK |
| `tmr_inst.th` (fault threshold) | 32 | 32 | 32 | OK |

**Result: 8/8 triplet groups intact, 375 triplicated state bits (125 logical bits × 3), 21.2% of all
flip-flops in the design.** TMR is confirmed present in the gate-level netlist that fed the signed-off
GDS — not just claimed at the RTL level.

---

## 3. Stage 2 — Floorplan through Detailed Routing

Resumed from Stage 1's `state_out.json` (netlist not re-synthesized). Timing during this stage is
driven by `pnr_constraints.sdc`, which is **deliberately over-constrained at 55 ns** (vs. the real
62.5 ns spec) so the resizer/CTS optimize with extra margin.

| Metric | Value | Gate |
|---|---|---|
| Detailed-route DRC violations | 0 | ✅ |
| Antenna violations (post-repair) | 0 | ✅ |
| Power-grid violations | 0 | ✅ |
| DRT convergence (violations per iteration) | 4509 → 1620 → 1409 → 54 → 0 | converged |
| Core utilization | 60.9% | comfortable vs. 65% target |

Floorplan config: `FP_SIZING: absolute`, `DIE_AREA: [0, 0, 800, 800]`, `PL_TARGET_DENSITY_PCT: 65`,
`RT_MAX_LAYER: Metal4` (Metal5 reserved for chip-level integration routing over this macro).

---

## 4. Stage 3 — Signoff

Resumed from the routed database. Real-spec STA (`signoff_constraints.sdc`, 62.5 ns) runs here for
the first time; everything before this stage was either ideal-clock or over-constrained.

### 4.1 Area & utilization

| Metric | Value |
|---|---|
| Die area | 800 × 800 µm (640,000 µm²) |
| Core area | 391,518 µm² |
| Core utilization | 60.9% |
| Total instances (post fill/tap/CTS) | 54,299 |
| Sequential cells | 1,767 |

### 4.2 Timing — all 9 PVT corners, signoff SDC (62.5 ns / 16 MHz)

| Corner | Setup WS (ns) | Setup vio | Hold WS (ns) | Hold vio |
|---|---|---|---|---|
| max_ff_n40C_5v50 | +40.89 | 0 | +0.135 | 0 |
| max_ss_125C_4v50 | **+11.84** (worst) | 0 | +0.946 | 0 |
| max_tt_025C_5v00 | +34.40 | 0 | +0.379 | 0 |
| min_ff_n40C_5v50 | +41.03 | 0 | **+0.127** (worst) | 0 |
| min_ss_125C_4v50 | +16.83 | 0 | +0.930 | 0 |
| min_tt_025C_5v00 | +37.21 | 0 | +0.369 | 0 |
| nom_ff_n40C_5v50 | +40.97 | 0 | +0.131 | 0 |
| nom_ss_125C_4v50 | +14.56 | 0 | +0.937 | 0 |
| nom_tt_025C_5v00 | +35.94 | 0 | +0.373 | 0 |

**Setup and hold both met on every corner, 0 violations, 0 TNS.** This is a substantial improvement
over the previous run against this design (`RUN_2_SIGNOFF`, 650×650 die), which failed setup at
−19.0 ns on `ss` corners with 49 violating endpoints — the larger 800×800 die and `AREA 3` synthesis
strategy resolved that closure problem.

### 4.3 DRV (design rule violations) — max-slew / max-cap

| Metric | Value | Root cause |
|---|---|---|
| Max-fanout violations | 0 | — |
| Max-cap violations | 8 (worst corner) | see below |
| Max-slew violations | 260 (worst corner: `max_ff_n40C_5v50`) | see below |

**Root cause, traced to source:** `signoff_constraints.sdc` and `pnr_constraints.sdc` both apply
`set_false_path -from [get_ports sys_rst_n]`. Because the reset is excluded from timing analysis, it
is *also* excluded from fanout-driven buffering/DRV repair. The netlist shows the reset distributed
through branches with **125–280 flip-flops each** on the `/RN` pin — far above
`MAX_FANOUT_CONSTRAINT: 10` (which reports 0 violations because the false-pathed net is never
checked). The resulting transitions measure 2.97–3.55 ns against the library's 2.6 ns max-slew limit.
All 260 slew violations and all 8 cap violations are on this one net's fanout tree — confirmed by
inspecting `checks.rpt` in `S3_SIGNOFF/11-openroad-stapostpnr/`.

This is benign at 62.5 ns (worst overshoot is ~5% of the clock period and reset is asynchronous by
design), but two things follow from it and are **not yet addressed**:
1. It should be fixed (buffer the reset tree) or explicitly waived in writing with this root-cause
   note, rather than left as an unexplained non-zero metric.
2. Because reset is false-pathed, **recovery/removal timing between the three TMR copies is never
   analyzed.** A wide, slow reset tree means the three copies of a triplicated register could
   theoretically exit reset on different clock edges. The self-scrubbing voter (all three copies
   rewritten from the majority vote every cycle) recovers this within one cycle, so it is not a
   correctness risk — but it should be stated explicitly in the RHBD documentation rather than
   left implicit.

### 4.4 The "5 unconstrained endpoints" warning

`STAPostPNR`'s `checks.rpt` reports 5 unconstrained endpoints. Traced directly in the netlist: these
are the first-stage synchronizer flops fed through `dlyb_1` delay buffers from `c_miso`, `cmd_csn`,
`cmd_mosi`, `cmd_sclk`, and `sensor_drdy` — exactly the five async, false-pathed input ports. This is
expected by construction (a false-pathed input has no launch-clock relationship for STA to analyze)
and requires no action.

### 4.5 Physical verification

| Check | Tool | Result |
|---|---|---|
| Routing DRC | OpenROAD DRT | 0 |
| Layout DRC | Magic | 0 |
| Layout DRC | KLayout | **not run** — `KLAYOUT_DRC_RUNSET` unset for gf180mcuD, step skipped |
| Streamout cross-check | Magic vs. KLayout XOR | 0 differences |
| LVS | Netgen | 0 errors (0 unmatched devices/nets/pins) |
| Antenna violations | — | 0 nets, 0 pins |
| Antenna diodes inserted | — | 1 |
| Critical disconnected pins | — | 0 |
| Illegal overlaps | Magic | 0 |

Two DRC engines ran (Magic full DRC, KLayout XOR-only); KLayout's independent DRC ruleset is not
available for this PDK in this flow, so DRC sign-off currently rests on Magic alone with a geometric
cross-check against KLayout's streamout. See the gaps document for what this means for confidence.

### 4.6 Power & IR drop

| Metric | Value |
|---|---|
| Total power | 46.4 mW |
| Internal power | 35.0 mW |
| Switching power | 11.4 mW |
| Leakage power | 5.2 µW |
| Worst IR drop (reported) | 109 µV |
| Average IR drop (reported) | 12.8 µV |

**Caveat on IR drop:** the flow log explicitly warns `'VSRC_LOC_FILES' was not given a value, which
may make the results of IR drop analysis inaccurate.` No real supply-pad locations were supplied
because this macro has not yet been placed in a chip-level padring. The 109 µV figure reflects
LibreLane's default assumption (power delivered uniformly at the block boundary) and **must be
re-run at chip level once real pad locations are known** — it is not representative of in-chip IR
drop today.

### 4.7 Layer usage

Routing used **Metal1 through Metal4 only** (`RT_MAX_LAYER: Metal4`), confirmed by inspecting the
GDS layer set directly (layers 34/36/42/46; no layer 81 = Metal5 present). **Metal5 is free for
chip-level integration routing over this macro** — a deliberate choice so a chip-top or padring
integration is not blocked by routing conflicts with this macro's internal wiring.

---

## 5. Pin placement (as delivered to the padring integrator)

Read directly from the final DEF (`S3_SIGNOFF/final/def/top.def`) and cross-checked against
`librelane/pins.cfg`. All 14 pins placed on the sides `pins.cfg` requested, in the requested order:

| Side | Pins | Layer |
|---|---|---|
| N | `clk`, `sys_rst_n`, `VDD`, `VSS` | Metal2 (signal), Metal4 (power) |
| E | `c_miso`, `c_mosi`, `c_sclk`, `c_csn`, `sensor_drdy` (sensor SPI bus) | Metal3 |
| W | `cmd_sclk`, `cmd_csn`, `cmd_mosi` (command SPI bus) | Metal3 |
| S | `tmr_forward_en`, `fault_flag_out` | Metal2 |

`VDD`/`VSS` are exposed in the LEF as 11 full-height, 5 µm-wide Metal4 straps on 75 µm pitch, spanning
the entire macro height — a standard block-level power delivery interface for chip-top PDN hookup.
The LEF `OBS` (obstruction) statement blocks Metal1–Metal4 plus Nwell across the macro footprint,
which is what forces the chip integrator onto Metal5 rather than accidentally routing through this
macro's internal layers.

**Padring-position note:** this pin assignment (sensor SPI east, command SPI west) was chosen without
knowledge of the macro's eventual position in the multi-team chip padring. If the macro's assigned
slot places it away from the die center, the side facing the nearest pad row should carry the
higher-pin-count bus (sensor SPI, 5 pins) to minimize chip-level routing length — `pins.cfg` should
be revisited once the slot assignment is known, and only Stage 2/3 need to be re-run to reflect it.

---

## 6. Deliverables

Produced by `--save-views-to build/top` in Stage 3:

| View | File | Notes |
|---|---|---|
| Layout | `build/top/gds/top.gds` | ~15 MB, streamed out via KLayout |
| Abstract | `build/top/lef/top.lef` | `CLASS BLOCK`, `SIZE 800.000 BY 800.000` |
| Timing (9 corners) | `build/top/lib/<corner>/top__<corner>.lib` | one per PVT corner |
| Gate netlist | `build/top/nl/top.nl.v` | post-signoff netlist |
| Parasitics | `build/top/spef/` | RC-extracted (RCX) |
| Delays | `build/top/sdf/` | 9 corner-specific SDF files — **not yet used in any gate-level simulation** |
| Placement | `build/top/def/top.def` | final DEF |
| Extracted netlist | `build/top/spice/` | Magic SPICE extraction (LVS source) |

---

## 7. Known deviations from earlier documentation

- **Die size:** `docs/specs/SYSTEM_ARCHITECTURE.md` and `docs/architecture/ITAG_ARCHITECTURE_ANALYSIS.md`
  state a "~600×600 µm die budget" as a *pre-implementation* target. The actual signed-off macro is
  **800×800 µm (640,000 µm²)**. A 650×650 µm attempt (`RUN_2_SIGNOFF`, an earlier run) failed setup
  timing by −19 ns; 800×800 at `AREA 3` is the smallest die that has been shown to close cleanly.
  Reaching 600×600 would require an area-reduction pass (~44% area cut from the current
  391,518 µm² core), not just a floorplan change — see the ITAG analysis addendum for options.
- Everything else in prior documentation (module structure, RHBD strategy, functional verification
  results) is unaffected by physical implementation and remains accurate.

---

*Generated from `S1_SYNTH`, `S2_DRT`, `S3_SIGNOFF` run artifacts under
`~/eda/designs/space-jam/librelane/runs/`. Flow driven by
`librelane/01_fault_detector_macro.ipynb`. Last verified: 2026-08-22.*
