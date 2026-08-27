# Pin Placement Rationale — `top` macro in a multi-team padring

> **Stated assumption: this macro is placed in the TOP-LEFT of the padring core.**
> Pin placement is only meaningful relative to a padring position. If the assigned slot
> changes, `librelane/pins.cfg` must be revisited and Stages 2–3 re-run (Stage 1 synthesis
> stays valid — the netlist does not depend on pin location).

> ⚠️ **Revised 2026-08-26 against the real `slot_1x1` pad map.** The original edge
> assignment was derived from an abstract "top pad row / left pad row" model, before the
> concrete wafer-space `slot_1x1` pad lists were available. Five of the twelve pins turned
> out to be on the edge *away* from the pad they must reach. §3 and §5 below are rewritten;
> the tie-break reasoning they used to contain has been superseded by a hard constraint
> (pad-type availability, §3). **The signed-off macro GDS/LEF predates this change and must
> be re-hardened — see §7.**

`librelane/pins.cfg` has **no comment syntax** (see §4), so this document is the only place
the reasoning can live. Keep them in sync.

---

## 1. The governing fact: every pin is off-chip I/O

All 12 signal pins of this macro must reach a **pad**. There are no macro-to-macro nets.
The pad instances below are the actual ones assigned in `slot_1x1` (see
[`padring/README.md`](../../padring/README.md) and `padring/src/chip_core.sv`):

| Pin(s) | Direction | Destination | Pad instance | Pad cell | Die side |
|---|---|---|---|---|---|
| `clk` | in | clock | `clk_pad` | `gf180mcu_fd_io__in_s` (Schmitt) | **SOUTH**, SW corner |
| `sys_rst_n` | in | reset | `rst_n_pad` | `gf180mcu_fd_io__in_c` | **SOUTH**, SW corner |
| `c_miso` | in | off-chip IIS3DWB sensor | `inputs[11].pad` | `gf180mcu_fd_io__in_c` | WEST |
| `sensor_drdy` | in | off-chip IIS3DWB INT1 | `inputs[10].pad` | `gf180mcu_fd_io__in_c` | WEST |
| `tmr_forward_en` | in | strap | `inputs[9].pad` | `gf180mcu_fd_io__in_c` | WEST |
| `cmd_sclk` | in | off-chip host / RISC-V | `inputs[8].pad` | `gf180mcu_fd_io__in_c` | WEST |
| `cmd_csn` | in | off-chip host / RISC-V | `inputs[7].pad` | `gf180mcu_fd_io__in_c` | WEST |
| `cmd_mosi` | in | off-chip host / RISC-V | `inputs[6].pad` | `gf180mcu_fd_io__in_c` | WEST |
| `c_csn` | out | off-chip IIS3DWB sensor | `bidir[26].pad` | `gf180mcu_fd_io__bi_24t` | NORTH |
| `c_sclk` | out | off-chip IIS3DWB sensor | `bidir[27].pad` | `gf180mcu_fd_io__bi_24t` | NORTH |
| `c_mosi` | out | off-chip IIS3DWB sensor | `bidir[28].pad` | `gf180mcu_fd_io__bi_24t` | NORTH |
| `fault_flag_out` | out | off-chip alarm | `bidir[29].pad` | `gf180mcu_fd_io__bi_24t` | NORTH |
| `VDD` / `VSS` | — | chip power ring | 8 × `dvdd`, 10 × `dvss` | `gf180mcu_ws_io__*` | E / W / N / S |

Two corrections to earlier revisions of this table, both from reading `src/chip_top.sv`:
`sys_rst_n` and `sensor_drdy` do **not** get Schmitt-trigger pads — only `clk_pad` is
`in_s`; `rst_n_pad` and all twelve `inputs[*]` are plain `in_c`. `sensor_drdy` is an
asynchronous interrupt where a Schmitt input would have been welcome, but it is 2-FF
synchronized inside the macro (`ff_2_sync`), so a CMOS pad is adequate.

Because *nothing* connects sideways to a neighbouring macro, the only thing that matters
is **which edge faces the pad each pin must reach**.

---

## 2. Geometry of a top-left macro

```
        ┌──────────────── top pad row ─────────────────┐
        │  ┌──────────────┐                            │
   left │  │  OUR MACRO   │      other teams' macros   │  right
   pad  │  │  (top-left)  │                            │  pad
   row  │  └──────────────┘                            │  row
        │            other teams' macros               │
        └─────────────── bottom pad row ───────────────┘
```

| Macro edge | Faces | Route length to a pad |
|---|---|---|
| **N (north)** | top pad row | **short** ✅ |
| **W (west)** | left pad row | **short** ✅ |
| E (east) | chip interior / neighbouring macros | long ❌ |
| S (south) | chip interior / neighbouring macros | long ❌ |

**Rule applied: put all 12 pins on N and W; leave E and S empty.**

Leaving E/S empty is a positive, not a waste — it means zero pins face the neighbouring
teams' macros, so our pin escape routing cannot fight theirs for tracks.

---

## 3. Which signal gets which edge — forced, not chosen

Earlier revisions treated this as a timing tie-break between two equally-short edges, and
put the sensor SPI bus (including `c_miso`) on N because `c_miso` is the most
delay-sensitive pin in the design. That reasoning is **superseded**: once the real
`slot_1x1` pad lists are read, the assignment is not a choice at all.

**The constraint: pad types are not distributed evenly around the die.**

| Die side | Signal pads available in `slot_1x1` |
|---|---|
| WEST | **all 12** `in_c` input pads (`inputs[11:0]`) — and *nothing else* |
| NORTH | 14 `bi_24t` bidir pads + 2 analog — **no input pads** |
| SOUTH | `clk_pad`, `rst_n_pad`, 14 `bi_24t` bidir |
| EAST | 12 `bi_24t` bidir |

Therefore:

- **Every input signal must land on a WEST pad.** There is no input pad anywhere on the
  north edge, so an input pin placed on the macro's N edge has to route across or around
  the macro to reach the west pad row — the exact opposite of what N was chosen for.
- **Every output signal must land on a `bi_24t` bidir pad**, and the nearest ones to a
  top-left macro are `bidir[26:29]` at the west end of the NORTH row.
- `clk` / `sys_rst_n` are hard-wired to `clk_pad` / `rst_n_pad` at the **SW corner** and
  cannot be moved. E and S remain off-limits (they face other teams' macros, §2), so the
  closest legal edge is the **south end of the W edge**.

This collapses to a rule that is easier to state and harder to get wrong than the old
tie-break:

> **All 4 outputs on N. All 8 inputs on W.**

`c_miso` still gets the treatment its timing budget deserves — `rtl/clk_divider.v` documents
why the SPI bit clock is `clk/8` rather than `clk/4`, buying ~2 clk of margin for the MISO
sample path — but the way to protect it here is to put it on the edge facing its actual pad
(`inputs[11]`, WEST), not on the edge that was assumed to be shortest.

### What this cost the previous placement

Five of twelve pins were on the wrong edge:

| Pin | Pad side | Old macro edge | New macro edge |
|---|---|---|---|
| `clk` | SOUTH (SW corner) | N | **W** (south end) |
| `sys_rst_n` | SOUTH (SW corner) | N | **W** (south end) |
| `c_miso` | WEST | N | **W** |
| `sensor_drdy` | WEST | N | **W** |
| `fault_flag_out` | NORTH | W | **N** |

`clk` and `sys_rst_n` were the worst cases — sitting on the N edge put them at die
y ≈ 4600 while their pads are at y ≈ 0, the maximum possible separation on this die.
Moving them to the south end of the W edge shortens each Manhattan run by **~20 %**
(`clk` 4904 → 3932 µm, `sys_rst_n` 4992 → 4032 µm).

### Note on reset recovery/removal

The old §3 justified keeping `clk` and `sys_rst_n` adjacent so their chip-level delays
would match, as cheap insurance for the recovery/removal check that is not run (they are
false-pathed — see
[`GATE_LEVEL_VERIFICATION_GAPS.md`](../verification/GATE_LEVEL_VERIFICATION_GAPS.md) §2.5).
That argument survives the change and is preserved: the two pins are still adjacent, now as
the bottom two slots of the W edge, and both now sit closer to their pads than before.

---

## 4. `pins.cfg` grammar (and why there are no comments in it)

Parser: `librelane/scripts/odbpy/ioplace_parser/parse.py`.

| Token | Meaning |
|---|---|
| `#N` `#E` `#W` `#S` | side marker. A trailing `R` (e.g. `#NR`) **reverses** the order on that side |
| `$<n>` | `n` **virtual pins** — reserve spacing but place no real pin |
| `@min_distance=<x>` | minimum pin pitch (global before any side, per-side after) |
| `@bus_major` / `@bit_major` | multi-bit bus sort order |
| any other token | a pin name (actually a regex) |

**There is no comment syntax.** A stray `# note` would be parsed as a *side* named `n`,
and a bare word would be parsed as a *pin regex*. Hence this file.

Ordering convention, confirmed empirically from the generated DEF:
- **N / S edges:** listed order runs **left → right** (increasing X)
- **E / W edges:** listed order runs **bottom → top** (increasing Y)

---

## 5. The resulting placement

```
#N
$1
c_csn
c_sclk
c_mosi
fault_flag_out
$3

#W
clk
sys_rst_n
cmd_mosi
cmd_csn
cmd_sclk
tmr_forward_en
sensor_drdy
c_miso
```

Three deliberate choices beyond edge assignment:

**a) `clk` and `sys_rst_n` occupy the two southernmost W slots.** Their pads are at the die's
SW corner, so the bottom of the W edge is the closest legal point (E and S are off-limits per
§2). They stay adjacent to each other, preserving the recovery/removal argument in §3.

**b) The six W-edge inputs ascend in the same order their pads descend.** `PAD_WEST` is read
N→S as `inputs[11] … inputs[6]`, and a `#W` list is read S→N, so listing `cmd_mosi`
(`inputs[6]`) first and `c_miso` (`inputs[11]`) last makes the six escape routes monotonic
and non-crossing. This is a free ordering win, not an attempt at exact pad-by-pad alignment —
the actual pad y-positions depend on how `OpenROAD.Padring` distributes filler cells, which
is not known until the chip-top flow runs.

**c) The N-edge spacers bias the four outputs toward the west end.** `bidir[26:29]` sit at the
west end of the north pad row, nearest the NW corner. `$1` leading and `$3` trailing pull the
four output pins into the western half of the macro's N edge rather than spreading them across
its full width.

Predicted pin coordinates (slots are evenly spaced across each 800 µm edge; pitch = 800 / slot
count, pin at slot centre — confirmed empirically against the previous run, where 9 N slots
gave an 88.5 µm pitch):

| Side | Pin | macro x | macro y | die x | die y |
|---|---|---|---|---|---|
| N | `c_csn` | 150.0 | 800.0 | 672.0 | 4600.0 |
| N | `c_sclk` | 250.0 | 800.0 | 772.0 | 4600.0 |
| N | `c_mosi` | 350.0 | 800.0 | 872.0 | 4600.0 |
| N | `fault_flag_out` | 450.0 | 800.0 | 972.0 | 4600.0 |
| W | `clk` | 0.0 | 50.0 | 522.0 | 3850.0 |
| W | `sys_rst_n` | 0.0 | 150.0 | 522.0 | 3950.0 |
| W | `cmd_mosi` | 0.0 | 250.0 | 522.0 | 4050.0 |
| W | `cmd_csn` | 0.0 | 350.0 | 522.0 | 4150.0 |
| W | `cmd_sclk` | 0.0 | 450.0 | 522.0 | 4250.0 |
| W | `tmr_forward_en` | 0.0 | 550.0 | 522.0 | 4350.0 |
| W | `sensor_drdy` | 0.0 | 650.0 | 522.0 | 4450.0 |
| W | `c_miso` | 0.0 | 750.0 | 522.0 | 4550.0 |
| E / S | *(none)* | — | — | — | — |

Uniform 100 µm pitch on both edges — more via-landing room than the previous 88 µm on N.
Die coordinates assume the macro origin `[522, 3800]` from
`padring/librelane/chip_overrides.yaml`.

> These are **predicted** values. The previous revision of this table listed coordinates
> verified against a real `Odb.CustomIOPlacement` DEF; those belong to the superseded
> placement. Re-verify after the re-harden in §7.

---

## 6. Notes for the chip-level integrator

1. **Signal pins are on Metal2 (N) and Metal3 (W)**, set by `IO_PIN_V_LAYER` /
   `IO_PIN_H_LAYER`. The macro's LEF `OBS` blocks Metal1–Metal4 across the full footprint,
   so chip-level routing over this macro must use **Metal5**, then via down at the pin.
   Metal5 is intentionally left unused inside the macro (`RT_MAX_LAYER: Metal4`).
2. **Power is on Metal4**: `VDD`/`VSS` are exposed as 11 full-height 5 µm straps each on a
   75 µm pitch, spanning y = 0 … 800. They can be tapped from the top *or* bottom, so the
   chip PDN can connect from either direction. Vertical macro straps on M4 × horizontal
   chip straps on M5 gives orthogonal crossings.
3. **Outputs need bidirectional pads** with output-enable tied active — the pad library has
   no plain digital output cell (see the chip audit's pad-type columns). This applies to
   `c_csn`, `c_sclk`, `c_mosi`, `fault_flag_out`.
4. **`tmr_forward_en` needs a defined level.** It is a static strap and must not float:
   tie it low for Option A (sample stays local, the default) or high for Option B (samples
   also forwarded into `tmr_reg_bank`). A pull-down is the safe default.
5. **If the assigned slot is not top-left**, update `MACRO_PADRING_POSITION` in
   `librelane/01_fault_detector_macro.ipynb` (Step 2.2), rewrite `pins.cfg` per §2/§3, and
   re-run Stages 2–3 only.

---

## 7. Consequence: the macro must be re-hardened

Pin locations are baked into the macro's physical views. The currently signed-off
`build/top/{gds,lef,def,...}` were produced with the **superseded** `pins.cfg`, so they do
not match §5.

**What is still valid:** the gate-level netlist. Pin placement does not affect synthesis, so
Stage 1 (`S1_SYNTH`) does not need to re-run — `pins.cfg` is consumed by
`Odb.CustomIOPlacement` inside Stage 2.

**What must re-run:** Stages 2 and 3 of
[`librelane/01_fault_detector_macro.ipynb`](../../librelane/01_fault_detector_macro.ipynb),
resuming from Stage 1's existing `state_out.json`:

| Stage | Run tag | Why | Cost |
|---|---|---|---|
| 1 — synthesis | `S1_SYNTH` | **skip** — netlist unaffected | — |
| 2 — floorplan → DRT | `S2_DRT` | new pin locations change I/O placement, routing and CTS | ~15–40 min |
| 3 — signoff | `S3_SIGNOFF` | new GDS/LEF/lib deliverables, re-run DRC/LVS/STA | ~15–30 min |

Then re-stage the refreshed views into the padring workspace by re-running **Step 1c** of
[`padring/02_chip_top_padring.ipynb`](../../padring/02_chip_top_padring.ipynb)
(`RUN_STAGE_MACRO = True`), which copies `build/top/` into
`~/eda/designs/space-jam-chip/macro/top/`. The padring notebook's Step 3.1 asserts the macro
LEF is still `CLASS BLOCK`, 800 × 800 µm, with `VDD`/`VSS` on Metal4 and no Metal5 usage, and
its **Step 3.3a** now additionally asserts that every pin's LEF edge matches the die side of
the pad it is wired to — that check is what would have caught this problem.

Expected deltas after the re-harden, worth checking rather than assuming:

- Setup/hold slack will move (different routing and CTS). The previous run closed with
  +8.16 ns setup at `max_ss_125C_4v50`, so there is margin to absorb it.
- `design__max_slew_violation__count` will change. Read it against §4.3 of
  [`PHYSICAL_IMPLEMENTATION_RESULTS.md`](../architecture/PHYSICAL_IMPLEMENTATION_RESULTS.md):
  the SDC limits are tighter than the library's, so re-run the liberty-limits-only check
  before treating any count as a real violation.
- The 5 unconstrained endpoints (§4.4 there) should stay at 5 — they are the async
  false-pathed inputs and are unrelated to pin location.

---

*`pins.cfg` revised 2026-08-26 against the real `slot_1x1` pad lists; coordinates in §5 are
predicted and pending re-verification against a new `Odb.CustomIOPlacement` DEF. The
superseded placement was verified against run tag `PINCHECK` (2026-08-23).*
