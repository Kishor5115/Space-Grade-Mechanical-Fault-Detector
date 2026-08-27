# Physical Implementation Results — `top` Macro (LibreLane / GF180MCU)

> **Status:** Macro physically signed off (DRC/LVS/XOR/antenna clean, timing closed on all 9 corners,
> post pin-placement re-harden). Chip-top padring integration (`slot_1x1`, top-left) also signed off
> clean. Gate-level cocotb simulation run (6/8 pass, 2 testbench-only). SEU/TMR fault-injection
> tested (3/3 pass). **Not yet:** chip-audit registration, cell-name collision cleanup, formal
> gate-level equivalence (Yosys EQY launched, not complete), chip-scale IR drop.
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
| DRT convergence (violations per iteration) | 117 → 14 → 11 → 0 → 4 → 4 → 0 | converged |
| Core utilization | 62.2% | comfortable vs. 65% target |

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
| Core area | 632,332 µm² |
| Core utilization | 62.2% |
| Total instances (post fill/tap/CTS) | 54,822 |
| Sequential cells | 1,767 |

### 4.2 Timing — all 9 PVT corners, signoff SDC (62.5 ns / 16 MHz)

> **Post pin-placement re-harden (2026-08-27).** `librelane/pins.cfg` was corrected against the real
> `slot_1x1` pad map (all 4 outputs on macro edge N, all 8 inputs on edge W, `clk`/`sys_rst_n` at
> the south end of W — see [`PIN_PLACEMENT_RATIONALE.md`](../specs/PIN_PLACEMENT_RATIONALE.md) §7).
> Stages 2–3 were re-run; the table below is the **current** signoff. Margins improved slightly
> (shorter clock/reset routes) versus the pre-re-harden run.

| Corner | Setup WS (ns) | Setup vio | Hold WS (ns) | Hold vio |
|---|---|---|---|---|
| max_ff_n40C_5v50 | +40.94 | 0 | **+0.103** (tied worst) | 0 |
| max_ss_125C_4v50 | **+10.04** (worst) | 0 | +0.871 | 0 |
| max_tt_025C_5v00 | +33.32 | 0 | +0.334 | 0 |
| min_ff_n40C_5v50 | +41.08 | 0 | **+0.103** (tied worst) | 0 |
| min_ss_125C_4v50 | +14.73 | 0 | +0.870 | 0 |
| min_tt_025C_5v00 | +35.98 | 0 | +0.333 | 0 |
| nom_ff_n40C_5v50 | +41.01 | 0 | +0.103 | 0 |
| nom_ss_125C_4v50 | +12.61 | 0 | +0.871 | 0 |
| nom_tt_025C_5v00 | +34.77 | 0 | +0.333 | 0 |

**Setup and hold both met on every corner, 0 violations, 0 TNS.** This is a substantial improvement
over the previous run against this design (`RUN_2_SIGNOFF`, 650×650 die), which failed setup at
−19.0 ns on `ss` corners with 49 violating endpoints — the larger 800×800 die and `AREA 3` synthesis
strategy resolved that closure problem.

### 4.3 DRV (design rule violations) — max-slew / max-cap

**Status: resolved. These are self-imposed SDC violations, not foundry-rule violations. The design
is clean against every limit the `gf180mcu_fd_sc_mcu7t5v0` library actually declares.**

| Metric | Worst corner | Count |
|---|---|---|
| Max-fanout violations | all corners | **0** |
| Max-cap violations | `max_ss_125C_4v50` | 196 |
| Max-slew violations | `max_ss_125C_4v50` | 2864 |

Corner distribution is the first clue that these are limit-relative rather than structural:

| corner group | max-slew count |
|---|---|
| `*_ff_n40C_5v50` (all three) | **0** |
| `*_tt_025C_5v00` | 0 – 77 |
| `*_ss_125C_4v50` | 1729 – 2864 |

#### The limits being violated are ours, not the foundry's

| Limit | Project SDC (`MAX_*_CONSTRAINT`) | `gf180mcu_fd_sc_mcu7t5v0` liberty |
|---|---|---|
| max transition | **3.0 ns** | **7 ns**, uniform across all 836 timing pins |
| max capacitance | **0.2 pF** | per-output-pin, **0.058 … 4.9 pF** |
| max fanout | 20 | not declared |

The liberty declares no `default_max_transition` or `default_max_capacitance`; every limit is
per-pin. OpenSTA always reports against `min(SDC limit, liberty pin limit)`, so with a 3 ns SDC
ceiling every pin in the design is judged against a bound **2.3× tighter than the process allows**.

#### Verification: the same database, checked twice

OpenSTA was re-run standalone on the signed-off artifacts — the post-fill netlist
(`S3_SIGNOFF/08-openroad-fillinsertion/top.nl.v`) plus the extracted `max` SPEF
(`S3_SIGNOFF/10-openroad-rcx/max/top.max.spef`) against
`gf180mcu_fd_sc_mcu7t5v0__ss_125C_4v50.lib`, with `report_check_types -max_slew -max_cap
-max_fanout -violators`:

| Run | `set_max_transition` / `set_max_capacitance` applied | Violators reported |
|---|---|---|
| **A** | none — liberty pin limits only | **0 slew, 0 cap, 0 fanout** |
| **B** | `3.0` / `0.2`, i.e. the project SDC | reproduces the signoff list exactly (worst slew 6.64 ns, worst cap 0.336 pF) |

#### Accuracy cross-check

Reported delays are only trustworthy if the operating point sits inside the liberty's
characterisation range. The cell timing tables use `index_1 = 0.02 … 7 ns` input slew, and
`max_transition = 7` is exactly the top of that axis. Worst observed slew, 6.64 ns, is therefore at
**94.9 % of the characterised range — interpolated, not extrapolated.** Capacitance likewise: run A
passing means every output load sits inside its own pin's `max_capacitance`, which is the top of
that pin's `index_2` load axis.

#### Disposition: waive, with this evidence. Do not loosen the SDC.

The 3 ns / 0.2 pF limits are doing useful work — they are what drove `RUN_POST_GRT_DESIGN_REPAIR`
and the fanout-20 reset distribution, and they are why setup closes with +8.16 ns of margin at the
worst corner. Driving 6.64 ns down to 3 ns at `ss_125C_4v50` would mean a large buffer-insertion
campaign for no foundry-rule benefit. The non-zero count is best read as a **quality-margin
indicator**, not a failure.

#### Correction to earlier revisions of this document

Earlier revisions attributed these violations to the false-pathed `sys_rst_n` fanout tree and quoted
260 slew + 8 cap against "the library's 2.6 ns max-slew limit". All three claims were wrong:

- **Not the reset net.** `grep rst` over
  `S3_SIGNOFF/11-openroad-stapostpnr/max_ss_125C_4v50/checks.rpt` returns **0 hits**. The violators
  are distributed across the Goertzel datapath and the CTS/repair cells inserted by the flow itself
  (`clkbuf_*`, `fanout*`, `load_slew*`, `max_cap*`, `wire*`).
- **Not 2.6 ns.** The library limit is 7 ns; 3 ns is the project's own SDC value.
- **Counts were from a superseded run.** The current signoff reports 2864 / 196.

`MAX_FANOUT_CONSTRAINT: 20` reports 0 violations on every corner, so the reset distribution is
within its declared bound.

#### One genuinely open item, unrelated to the above

Because `sys_rst_n` is false-pathed in all three SDC views, **recovery/removal timing between the
three TMR copies of each register is never analysed.** A wide reset tree means the three copies of a
triplicated register could in principle exit reset on different clock edges. The self-scrubbing
voter (all three copies rewritten from the majority vote every cycle) recovers this within one
clock, so it is not a correctness risk — but it should be stated explicitly in the RHBD
documentation rather than left implicit.

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
| Total power | 47.0 mW |
| Internal power | 35.6 mW |
| Switching power | 11.4 mW |
| Leakage power | 5.3 µW |
| Worst IR drop (reported) | 131 µV |
| Average IR drop (reported) | 13.1 µV |

**Caveat on IR drop — still unresolved, now at both levels.** The flow log explicitly warns
`'VSRC_LOC_FILES' was not given a value, which may make the results of IR drop analysis
inaccurate.` This macro **has since been placed in a chip-level padring** (`slot_1x1`, top-left,
signed off clean — see [`padring/README.md`](../../padring/README.md)), but `VSRC_LOC_FILES` was
never set at chip level either. The chip-top run reports `ir__drop__worst = 0.5 µV` and
`power__total = 0.255 mW` — both invalid: the power figure is *below* this macro's own 47 mW
because the macro is a `.lib` black box at chip level with no activity annotation, so chip-level
power/IR analysis cannot see inside it. **Neither the macro's 131 µV nor the chip's 0.5 µV should be
treated as verified-good.** Properly closing this requires `VSRC_LOC_FILES` set to the real pad
coordinates at chip level, re-run with the macro's actual power profile annotated.

### 4.7 Layer usage

Routing used **Metal1 through Metal4 only** (`RT_MAX_LAYER: Metal4`), confirmed by inspecting the
GDS layer set directly (layers 34/36/42/46; no layer 81 = Metal5 present). **Metal5 is free for
chip-level integration routing over this macro** — a deliberate choice so a chip-top or padring
integration is not blocked by routing conflicts with this macro's internal wiring.

---

## 5. Pin placement (as delivered to the padring integrator)

> **Superseded 2026-08-27.** The pin assignment originally documented here (sensor SPI on E,
> command SPI on W, `clk`/`sys_rst_n` on N, `tmr_forward_en`/`fault_flag_out` on S) was chosen
> before the macro's actual `slot_1x1` padring position and pad map were known. Once they were,
> 5 of 12 pins turned out to be on the edge *facing away from* their pad. `librelane/pins.cfg` was
> corrected and the macro re-hardened — see
> [`PIN_PLACEMENT_RATIONALE.md`](../specs/PIN_PLACEMENT_RATIONALE.md) for the full derivation. The
> table below reflects the **current, re-hardened** layout.

Read directly from the final LEF (`build/top/lef/top.lef`) of the re-hardened macro and cross-checked
against `librelane/pins.cfg`. All 12 signal pins placed on the sides `pins.cfg` requests:

| Side | Pins | Layer |
|---|---|---|
| N | `c_csn`, `c_sclk`, `c_mosi`, `fault_flag_out` (all 4 outputs) | Metal2 |
| W | `clk`, `sys_rst_n`, `cmd_mosi`, `cmd_csn`, `cmd_sclk`, `tmr_forward_en`, `sensor_drdy`, `c_miso` (all 8 inputs) | Metal3 |
| E | *(none)* | — |
| S | *(none)* | — |

The rule is now simple and forced by pad-type availability rather than chosen: `slot_1x1` puts all
12 `in_c` input pads on `PAD_WEST` and none on the north, while the bidir pads nearest a top-left
macro are at the west end of `PAD_NORTH`. So every input lands on W and every output lands on N by
construction. `clk`/`sys_rst_n` sit at the south end of W, closest to their SW-corner pads
(`clk_pad`/`rst_n_pad`), cutting their route length by ~20% versus the superseded N-edge placement.

`VDD`/`VSS` are exposed in the LEF as 11 full-height, 5 µm-wide Metal4 straps on 75 µm pitch, spanning
the entire macro height — a standard block-level power delivery interface for chip-top PDN hookup.
The LEF `OBS` (obstruction) statement blocks Metal1–Metal4 plus Nwell across the macro footprint,
which is what forces the chip integrator onto Metal5 rather than accidentally routing through this
macro's internal layers.

**This pin assignment has now been validated against the real padring, not just guessed at.** The
chip-top integration (`padring/`, `slot_1x1`, macro top-left) has been run to a clean signoff with
this pin map — Magic DRC 0, LVS 0, XOR 0, antenna 0 — see
[`padring/README.md`](../../padring/README.md). E and S are empty by design: they face neighbouring
teams' macros in a top-left placement, so keeping them pin-free means this macro's escape routing
never contends with theirs.

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
| Delays | `build/top/sdf/` | 9 corner-specific SDF files — gate-level cocotb sim (`make test-top-gl`) uses `-DUNIT_DELAY=#1`, not SDF back-annotation; true SDF-timed simulation remains open |
| Placement | `build/top/def/top.def` | final DEF |
| Extracted netlist | `build/top/spice/` | Magic SPICE extraction (LVS source) |

---

## 7. Known deviations from earlier documentation

- **Die size:** `docs/specs/SYSTEM_ARCHITECTURE.md` and `docs/architecture/ITAG_ARCHITECTURE_ANALYSIS.md`
  state a "~600×600 µm die budget" as a *pre-implementation* target. The actual signed-off macro is
  **800×800 µm (640,000 µm²)**. A 650×650 µm attempt (`RUN_2_SIGNOFF`, an earlier run) failed setup
  timing by −19 ns; 800×800 at `AREA 3` is the smallest die that has been shown to close cleanly.
  Reaching 600×600 would require an area-reduction pass (~43% area cut from the current
  632,332 µm² core), not just a floorplan change — see the ITAG analysis addendum for options.
- **Pin placement:** §5 above documents that the originally-published pin assignment (sensor SPI
  east, command SPI west) has been superseded by the corrected `slot_1x1`-derived assignment (all
  outputs N, all inputs W). The macro was re-hardened; §4.1/§4.2 above reflect the current signoff.
- **Read-back accessibility:** `STATUS`/`FAULT_MAG`/`FAULT_BIN` in `tmr_reg_bank` are not readable
  off-chip (both APB masters are hard-wired write-only; no `cmd_miso` pin exists). See
  [`IO_SPECIFICATION.md` §Read-back accessibility](../specs/IO_SPECIFICATION.md#read-back-accessibility-in-silicon).
  This is a design limitation discovered during review, not a physical-implementation deviation, but
  is noted here because it affects what the fault-attribution registers described elsewhere in this
  document are actually useful for on real silicon.
- Module structure and RHBD strategy are unaffected by physical implementation and remain accurate,
  now with empirical (not just structural) SEU evidence — see
  [`GOERTZEL_CORE_EXPLANATION.md` §5.1](../specs/GOERTZEL_CORE_EXPLANATION.md#51-triplicated-fsm-rule-a-protect-control-state).

---

*Generated from `S1_SYNTH`, `S2_DRT`, `S3_SIGNOFF` run artifacts under
`~/eda/designs/space-jam/librelane/runs/`. Flow driven by
`librelane/01_fault_detector_macro.ipynb`. Last verified: 2026-08-22.*
