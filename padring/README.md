# Chip-top padring integration — `slot_1x1`

Stage 2 of physical implementation: the signed-off **`top`** macro is placed into the
wafer-space `gf180mcu-project-template` **`slot_1x1`** padring and taken through the LibreLane
**Chip** flow to produce a fab-ready `chip_top.gds`.

Stage 1 (hardening the `top` macro standalone) lives in
[`../librelane/01_fault_detector_macro.ipynb`](../librelane/01_fault_detector_macro.ipynb) and is
already complete — DRC/LVS/XOR/antenna clean, timing closed on all 9 PVT corners.

> ⚠️ **Prerequisite: the macro needs one re-harden before the chip-top flow can run.**
> `librelane/pins.cfg` was revised on 2026-08-26 once the real `slot_1x1` pad lists were read —
> five of the twelve pins were on the macro edge *away* from the pad they must reach
> (`clk`, `sys_rst_n`, `c_miso`, `sensor_drdy` were on N; `fault_flag_out` was on W). The signed-off
> GDS/LEF predate that fix, so **Stages 2–3 of the macro notebook must re-run** (Stage 1 stays
> valid — pin placement does not affect synthesis), then Step 1c here re-staged with
> `RUN_STAGE_MACRO = True`. Budget ~30–70 min.
>
> **Step 3.3a of this notebook enforces it** and currently fails by design: it reads pin edges out
> of the staged macro LEF and compares each against the die side of its pad. See
> [`../docs/specs/PIN_PLACEMENT_RATIONALE.md` §7](../docs/specs/PIN_PLACEMENT_RATIONALE.md).

---

## Contents

| File | Role |
|---|---|
| `02_chip_top_padring.ipynb` | The driver. Staging → patching → pre-flight → chip-top flow → signoff gate → diagnostics. |
| `src/chip_core.sv` | The only RTL we own at this level. Maps `top.v`'s 12 pins onto the slot_1x1 pad boundary and ties off every unused pad control. |
| `librelane/chip_overrides.yaml` | Chip-top LibreLane config: `MACROS` (all 9 corners), `PDN_MACRO_CONNECTIONS`, `CLOCK_PERIOD`, `chip_id` + logo. |

Design intent is git-tracked **here**; the notebook only stages it into the container bind mount.
Same philosophy as the macro notebook — no cell duplicates design intent.

---

## Configuration at a glance

| | |
|---|---|
| Slot | `slot_1x1` — die **3932 × 5122 µm** (3880 × 5070 + 26 µm sealring), core 3048 × 4238 µm, **20.1 mm²** |
| Macro | `top`, 800 × 800 µm, **top-left of the core**, origin `[522, 3800]`, orientation `N` |
| Keep-out | 80 µm from the core's west and north edges |
| Chip clock | **62.5 ns / 16 MHz** — the macro's characterised period, overriding the template's 40 ns |
| Pads used | 6 × `in_c` (PAD_WEST) + 4 × `bi_24t` (PAD_NORTH) + `clk_pad` + `rst_n_pad` — out of 52 signal pads available |
| PDK | **wafer-space `gf180mcu` fork @ `1.8.0`** (mandatory — see below) |
| Workspace | `~/eda/designs/space-jam-chip/` — deliberately separate from `space-jam/` |
| Runtime | **2–4 h** for the chip-top flow; Magic DRC dominates |

---

## Pad map

`PAD_*` lists in `slot_1x1.yaml` read **clockwise from the SW corner**, so `PAD_NORTH` is ordered
E→W and `PAD_WEST` is ordered N→S. The pads geometrically nearest the NW corner — where the macro
sits — are therefore the **last** `PAD_NORTH` entries and the **first** `PAD_WEST` entries.

| `top.v` pin | dir | `chip_core` port | pad instance | side |
|---|---|---|---|---|
| `clk` | in | `clk` | `clk_pad` (`in_s`, Schmitt) | S — SW corner, **fixed by the slot** |
| `sys_rst_n` | in | `rst_n` | `rst_n_pad` (`in_c`) | S — SW corner, **fixed by the slot** |
| `c_miso` | in | `input_in[11]` | `inputs[11].pad` | W, topmost input pad |
| `sensor_drdy` | in | `input_in[10]` | `inputs[10].pad` | W |
| `tmr_forward_en` | in | `input_in[9]` | `inputs[9].pad` | W |
| `cmd_sclk` | in | `input_in[8]` | `inputs[8].pad` | W |
| `cmd_csn` | in | `input_in[7]` | `inputs[7].pad` | W |
| `cmd_mosi` | in | `input_in[6]` | `inputs[6].pad` | W |
| `c_csn` | out | `bidir_out[26]` | `bidir[26].pad` | N, nearest NW corner |
| `c_sclk` | out | `bidir_out[27]` | `bidir[27].pad` | N |
| `c_mosi` | out | `bidir_out[28]` | `bidir[28].pad` | N |
| `fault_flag_out` | out | `bidir_out[29]` | `bidir[29].pad` | N |

The indices live as `localparam`s in `chip_core.sv` and as a `PAD_MAP` table in the notebook.
**Step 3.3 cross-checks the two against `rtl/top.v`'s actual port list** and fails if any of the
three disagree — that mismatch is otherwise silent all the way to a mis-bonded die.

**Step 3.3a then checks the physical half of the same question**: it reads each pin's edge out of
the staged macro LEF and asserts it matches the die side of the pad it is wired to.

| Pad's die side | Required macro edge | Pins |
|---|---|---|
| WEST (`inputs[11:6]`) | **W** | `c_miso`, `sensor_drdy`, `tmr_forward_en`, `cmd_sclk`, `cmd_csn`, `cmd_mosi` |
| NORTH (`bidir[26:29]`) | **N** | `c_csn`, `c_sclk`, `c_mosi`, `fault_flag_out` |
| SOUTH (`clk_pad`, `rst_n_pad`, SW corner) | **W**, southern half | `clk`, `sys_rst_n` |

The rule reduces to **all 4 outputs on N, all 8 inputs on W**, and it is forced rather than chosen:
`slot_1x1` puts all twelve `in_c` input pads on PAD_WEST and none on the north, while the only pads
that can drive an output near a top-left macro are the west-end `bi_24t` cells on PAD_NORTH.
`clk`/`sys_rst_n` are pinned to the SW corner and cannot move, so the south end of W is their
closest legal edge — worth ~20 % off their Manhattan run versus the previous N-edge placement.

### Unused pad policy

| pads | treatment |
|---|---|
| 36 unused `bidir` | `oe=0` (driver high-Z), **`ie=0`** (receiver disabled, nothing floats into the core), `pu=pd=cs=sl=0`, `out=0` |
| 4 used `bidir` | `oe=1`, `ie=0` (pure outputs), `cs=0` (CMOS), `sl=0` (fast slew), `pu=pd=0` |
| 6 unused `input_in` | folded into an `_unused` reduction so neither Verilator nor Yosys flags them |
| all `input` pads | `pu=0`, `pd=0` |
| `analog[1:0]` | left unconnected at the core boundary — pure pass-through to the `asig_5p0` cells. This design has no analog IP. |

---

## How to drive it

Run **Step 0 → Step 3.6** every session. That is the entire pre-flight and it is cheap (seconds,
except the one-time PDK clone). Then flip one `RUN_*` gate at a time.

```
RUN_STAGE_TEMPLATE  # 1a  copy the vendored padring into the bind mount   (~200 KB)
RUN_CLONE_PDK       # 1b  clone wafer-space gf180mcu @ 1.8.0             (~500 MB, ~2 min)
RUN_STAGE_MACRO     # 1c  copy build/top macro views into the workspace
RUN_WRITE_SOURCES   # 2   stage chip_core.sv + overrides, apply 2 patches
RUN_CONFIG_DRYRUN   # 3.6 let LibreLane resolve + validate the merged config (seconds)
RUN_CHIP_SIM        # 4   optional cocotb elaboration check of the padring
RUN_CHIP_TOP        # 5   THE BIG ONE -- 2-4 h
```

`RUN_CHIP_TOP` defaults to `False`. Everything before it is designed to make the expensive run
succeed on the first attempt.

### Why the wafer-space PDK fork is mandatory

The padring instantiates `gf180mcu_ws_io__dvdd` and `gf180mcu_ws_io__dvss` for its 8 + 10 power
pads. Those cells do **not** exist in the PDK built into the container —
`/foss/pdks/gf180mcuD/libs.ref/` ships only `gf180mcu_fd_io`, `gf180mcu_fd_ip_sram`,
`gf180mcu_fd_pr`, and the two standard-cell libraries. Without the fork,
`OpenROAD.Padring` dies on a cell-not-found error ~20 minutes into the flow. Step 3.1 asserts the
cells resolve before you get there.

If the clone is slow, do it by hand:

```bash
git clone --depth 1 --branch 1.8.0 https://github.com/wafer-space/gf180mcu.git \
  ~/eda/designs/space-jam-chip/template/gf180mcu
```

---

## The two patches applied to the vendored template

Everything else arrives via `chip_overrides.yaml` as a third positional config file, so the
template stays as close to pristine as possible. Both patches are idempotent.

1. **`src/chip_top.sv` — re-enable `chip_id` and the wafer.space logo.** The vendored copy has them
   commented out ("disabled for the multimacro example"), while its own comment says *"Chip ID — do
   not remove, necessary for tapeout"*. The patch only un-comments what upstream ships enabled.
2. **`librelane/config.yaml` — substitute out KLayout DRC** (`KLayout.DRC: null` +
   `Checker.KLayoutDRC: null`). gf180mcuD ships no curated KLayout DRC runset; the open-source
   rules take 1 h+ on a chip-top and disagree with foundry intent. **Magic DRC is authoritative on
   this PDK.** KLayout **XOR** and **antenna** stay enabled.

`librelane/pdn_cfg.tcl` is **not** patched. Reference notebook 02 had to hand-edit a per-macro PDN
grid, but the vendored `pdn_cfg.tcl` already declares a generic
`define_pdn_grid -macro -default -name macro` with
`add_pdn_connect -layers "$PDN_VERTICAL_LAYER $PDN_HORIZONTAL_LAYER"`. On gf180 those resolve to
**Metal4 / Metal5**; the macro exposes `VDD`/`VSS` on **Metal4** and its routing obstruction stops
at Metal4, so the chip's Metal5 straps land on the macro's power pins and Metal5 stays free for
routing over the macro.

---

## Read this before you trust the LVS result

Reference notebook `02_rtl2gds_chip_top_custom.ipynb` documents a **known chip-top LVS defect on
this exact slot**: Magic streams the top cell with `VSS` but **without `VDD`** in its top-level port
list, so Netgen reports a one-port mismatch even though IR-drop confirms `VDD` is present across the
die. Notebook 04 reaches fully-clean signoff only because it targets the *workshop* slot instead.

Step 6 therefore judges LVS **separately** from the rest of the gate. If it fails, the notebook
prints `lvs.report` so the failure can be classified, and requires you to set
`LVS_KNOWN_TEMPLATE_QUIRK = True` by hand before it records a waiver. **LVS is never
auto-disabled.**

---

## Known cost of the top-left placement

`clk_pad` and `rst_n_pad` are pinned to the **SW corner** by `slot_1x1.yaml` and cannot be moved.
`librelane/pins.cfg` puts the macro's `clk` / `sys_rst_n` pins on its **N** edge (see
[`../docs/specs/PIN_PLACEMENT_RATIONALE.md`](../docs/specs/PIN_PLACEMENT_RATIONALE.md)). With the
macro at top-left those two nets run most of the core height:

| placement | `clk_pad` → macro `clk`, Manhattan |
|---|---|
| **top-left (chosen)** | **5.08 mm** |
| bottom-left | 0.56 mm |

At 62.5 ns this is not a timing risk — chip-top CTS treats the macro `clk` pin as a leaf and buffers
the run — but expect extra `clkbuf` stages, measurable insertion delay, and `repair_design` buffers
on `sys_rst_n`. **Appendix A.4 measures what actually happened** so the tradeoff is data-backed.

Changing your mind is cheap in the notebook (`MACRO_POSITION` / `MACRO_ORIGIN` are one variable)
but not free overall: a bottom-left macro wants its pins on the **S** edge, which means editing
`librelane/pins.cfg` and re-running the macro flow (~1 h, not a redesign).

---

## Signoff gate

Step 6 gates on: routing DRC, Magic DRC, XOR, antenna, critical disconnected pins, power-grid
violations, and setup **and** hold across all 9 corners — plus LVS, judged separately as above.

### Achieved result (run `C1_CHIP` + `C2_SIGNOFF`, 2026-08-26)

**Clean signoff. All gates zero.**

| Check | Result |
|---|---|
| Magic DRC | **0** |
| Netgen LVS | **0** (unmatched pins / nets / devices all 0 — the `slot_1x1` `VDD`-port quirk did **not** occur) |
| KLayout XOR | **0** |
| Antenna | **0** |
| Routing DRC | **0** |
| Critical disconnected pins | **0** |
| Setup / hold violations | **0 / 0** (worst setup +31.99 ns @ `max_ss`, hold +17.14 ns @ `min_ff`) |
| Die area | 20.14 mm² (3932 × 5122 µm) |
| Instances | 245,704 (3 macros: `top` + `chip_id` + logo) |

GDS at `~/eda/designs/space-jam-chip/final/gds/chip_top.gds`.

> ⚠️ **Chip-level IR drop and power are NOT valid — do not quote them.**
> `final/metrics.json` reports `ir__drop__worst = 5.06e-07 V` (0.5 µV) and
> `power__total = 0.255 mW`. Both are meaningless:
> - `VSRC_LOC_FILES` was never set, so OpenROAD's PSM had no supply injection points to compute a
>   drop against. The flow log warns about this explicitly.
> - The 0.255 mW figure is **less than the macro's own 47 mW**, which the chip contains — off by
>   ~184x. Chip-level power analysis cannot see inside the `top` macro (it is a `.lib` black box)
>   and no switching activity (VCD/SAIF) was annotated.
>
> The correct statement is that **chip-level IR drop is unverified, not verified-good.** Physics
> strongly suggests it is fine — roughly 9.4 mA total draw (47 mW / 5 V) spread across 8 DVDD +
> 10 DVSS pads each rated 60 mA DC, with a 25 µm core ring — but that is an argument, not a
> measurement. To close it properly, set `VSRC_LOC_FILES` to the real pad coordinates and re-run
> `OpenROAD.IRDropReport`.

> ⚠️ **Chip-level STA is boundary-only.** The reported setup slack of +31.99 ns covers
> macro-pin-to-pad paths only: STA's startpoint is `i_chip_core.u_fault_detector` as a `.lib` black
> box, so the macro's internal paths are **not** re-analysed at chip level. **The design's real
> timing margin is the macro's own +10.04 ns.** CTS was also skipped at chip level (`clk_PAD2CORE`
> has 1 sink), so the chip clock is ideal in STA. Both are correct hierarchical practice, but
> +31.99 ns must not be quoted as the design margin.

> **KLayout density check disabled.** On the first attempt (`C1_CHIP`) the flow ran cleanly through
> routing, Magic-stream, render, XOR and antenna, then the KLayout **density** step was SIGKILL'd by
> the OS out-of-memory killer: it loads ~9.5M via3 + ~1M dummy-fill polygons single-threaded on this
> 20.1 mm² die and exceeded the machine's 15 GB RAM. The density check is a fill-quality advisory,
> not a signoff gate, so it is substituted out (`KLayout.Density: null` /
> `Checker.KLayoutDensity: null`, patched by the notebook's Step 2 alongside the KLayout-DRC
> disable). `C2_SIGNOFF` resumed from the routed state past that step and completed Magic DRC + LVS
> clean. Magic DRC is memory-efficient (it streams rather than loading all polygons) so it ran
> without trouble on the same machine.

### On chip-top max-slew / max-cap counts

A nonzero `design__max_slew_violation__count` is **not** automatically a foundry problem. The
`gf180mcu_fd_sc_mcu7t5v0` liberty declares `max_transition = 7 ns` (uniform, and exactly the top of
its characterisation range) and a per-output-pin `max_capacitance` of 0.058–4.9 pF, while the SDC
applies the project's tighter `MAX_TRANSITION_CONSTRAINT` / `MAX_CAPACITANCE_CONSTRAINT`. STA
reports against `min(SDC, liberty)`.

This was resolved for the macro by re-running OpenSTA with **no SDC DRV limits**: 2864 slew + 196
cap became **0 and 0**, with worst slew 6.64 ns sitting inside the 7 ns characterised range
(interpolated, not extrapolated). **Appendix A.3 runs the same check at chip top.** The conclusion
for the macro was *waive with evidence, do not loosen the SDC* — those tight limits are what drove
the post-GRT design-repair passes that produced the current margins.

---

## Outputs

```
~/eda/designs/space-jam-chip/final/gds/chip_top.gds      <- the submission artifact
~/eda/designs/space-jam-chip/final/render/chip_top.png
~/eda/designs/space-jam-chip/template/librelane/runs/C1_CHIP/   <- full run dir
~/eda/designs/space-jam-chip/logs/                       <- streamed container logs per stage
```

Inspect on the host with `klayout ~/eda/designs/space-jam-chip/final/gds/chip_top.gds`.

The `runs/` directory is large; once signoff is green, `final/` is the only thing worth keeping.
