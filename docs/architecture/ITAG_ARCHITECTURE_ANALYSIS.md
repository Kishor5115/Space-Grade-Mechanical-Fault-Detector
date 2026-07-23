# ITAG Architecture Analysis (Phase 1)

**Document:** Comparative analysis of the proposed *Interleaved Tri-Axis Goertzel* (ITAG)
microarchitecture vs. the current axis-sequential design.
**Status:** Research / pre-implementation. **No RTL has been changed by this document.**
**Scope:** `goertzel_core.v`, `axis_sequencer.v`, `magnitude_compute.v`, `top.v`;
`fault_flagger.v` / `tmr_reg_bank.v` / SPI front-end reviewed for backward compatibility.

> This analysis is derived from a full read of the checked-in RTL as of this commit.
> Where initial design estimates differ from what the RTL implies, the RTL-derived
> number is used and the discrepancy is called out explicitly (see §7).

---

## 0. Baseline established from the current RTL

| Fact | Source in RTL | Value |
|---|---|---|
| System clock | Project specification | 10 MHz (100 ns) |
| Sample rate | IIS3DWB boot config | 26.667 kHz |
| Cycles per sample | 10 MHz / 26.667 kHz | **375** |
| goertzel_core FSM | `goertzel_core.v` | 7 states, 3-bit TMR (`state_a/b/c`, `vote3`) |
| goertzel active cycles/sample (current) | `S_IDLE→B0_MUL…B2_UPD` | **6** |
| goertzel state regs (current) | `v1_0…v2_2` | 6 × 24-bit |
| magnitude FSM | `magnitude_compute.v` | 8 states, 3-bit TMR (`ms_a/b/c`, `vote3`) |
| magnitude cycles per (axis,bin) pair | `M_SQV1…M_CV1_W` | **6** (+1 `M_ARM` per session) |
| magnitude snapshot regs (current) | `sv1[0:2]`,`sv2[0:2]`,`sc[0:2]` | 9 × 24-bit |
| axis rotation | `axis_sequencer.v` | `axis_a/b/c` (vote2) + 1024-cycle scrub |
| **Integrated block size** | **`top.v` overrides `fault_flagger` `BLOCK_SIZE(512)`** | **512** |

> ⚠️ **Block-size discrepancy (pre-existing, not introduced by ITAG).**
> `fault_flagger.v`'s *default* parameter is `BLOCK_SIZE = 171`, but `top.v`
> instantiates it as `fault_flagger #(.BLOCK_SIZE(512))`. The **effective** block
> size in the integrated chip is therefore **512**, matching the target specification,
> while `README.md` still describes 171. This should be reconciled in
> Phase 4 docs. ITAG keeps the effective block size at 512 (§6).

---

## 1. Timing budget verification

### 1.1 goertzel_core active window (ITAG)

ITAG replaces the 7-state FSM with a 19-state FSM (`S_IDLE` + 3 axes × 6 states):

```
Cycle 1  : XB0_MUL     Cycle 7  : YB0_MUL     Cycle 13 : ZB0_MUL
Cycle 2  : XB0_UPD     Cycle 8  : YB0_UPD     Cycle 14 : ZB0_UPD
Cycle 3  : XB1_MUL     Cycle 9  : YB1_MUL     Cycle 15 : ZB1_MUL
Cycle 4  : XB1_UPD     Cycle 10 : YB1_UPD     Cycle 16 : ZB1_UPD
Cycle 5  : XB2_MUL     Cycle 11 : YB2_MUL     Cycle 17 : ZB2_MUL
Cycle 6  : XB2_UPD     Cycle 12 : YB2_UPD     Cycle 18 : ZB2_UPD  → sample_done
```

**goertzel active = 18 cycles/sample** (3 × the current 6). `sample_done` pulses at
`ZB2_UPD` (cycle 18), preserving the exactly-once-per-sample contract (Invariant 6).

### 1.2 magnitude_compute window (ITAG)

The current mag FSM costs **6 cycles per (axis,bin) pair** (`M_SQV1`, `M_SQV1_W`,
`M_SQV2`, `M_SQV2_W`, `M_CV1`, `M_CV1_W`) plus a single `M_ARM` when a session starts.
ITAG raises the pair count from 3 bins to **9 (axis,bin) pairs**:

```
mag session = 1 (M_ARM) + 9 pairs × 6 cycles = 1 + 54 = 55 cycles
```

> 📝 **Clarification on initial design notes.** Some early design notes estimated "27 multiplies … 54
> cycles". The multiply *count* is right (9 pairs × 3 multiplies), but the FSM
> spends 6 cycles per pair (a WAIT state follows each of the 3 multiplies), so the
> session is **55 cycles including `M_ARM`**, or 54 excluding it. The margin below
> is dominated by the ~300-cycle idle tail, so this 1-cycle difference is immaterial
> — but the doc should be precise.

### 1.3 Sequencing — is there multiplier contention?

The shared multiplier is arbitrated in `magnitude_compute.v` with **core priority**:
`mult_req_w = core_mult_req | mag_mult_req`, operands `= core_mult_req ? core : mag`.
The relevant question is whether goertzel and magnitude ever assert `mult_req`
simultaneously.

Trace the block-boundary sample (worst case, the only sample where mag runs):

| Cycle | goertzel state | `core_mult_req` | fault_flagger | mag FSM |
|---|---|---|---|---|
| 1–18 | XB0_MUL … ZB2_UPD | high in MUL states | — | `M_IDLE` |
| 18 | ZB2_UPD | 0 | `sample_done`=1 | `M_IDLE` |
| 19 | S_IDLE | 0 | `block_clear`=1 (registered from `block_boundary`) | `M_IDLE`→arms |
| 20 | S_IDLE | 0 | — | `M_ARM` |
| 21–74 | S_IDLE (idle) | **0** | — | `M_SQV1 … M_CV1_W` ×9 |
| 75 | S_IDLE | 0 | — | `M_IDLE` |
| … | S_IDLE | 0 | — | `M_IDLE` |
| 375 | S_IDLE→XB0_MUL (next sample) | high | — | `M_IDLE` |

Key points confirmed from RTL:

1. `block_clear` is registered in `fault_flagger` (`block_clear <= block_boundary`),
   so it asserts at **cycle 19**, one cycle *after* `sample_done`. goertzel is already
   back in `S_IDLE` and holds `core_mult_req = 0` for the entire mag session.
2. `magnitude_compute` snapshots `v1*/v2*` on `block_clear_in` (cycle 19) — the same
   edge goertzel zeroes its v-registers. Because the snapshot reads the *pre-clear*
   values (non-blocking assignment on both sides), the completed block's state is
   captured correctly. **This ordering is unchanged by ITAG** and remains valid with
   18 v-registers instead of 6.
3. The mag session (cycles ~20–74) runs entirely inside the idle window while
   `core_mult_req = 0`. **No contention.**

### 1.4 Idle margin

```
Non-boundary sample : 375 − 18            = 357 idle cycles (95.2% idle)
Boundary sample     : 375 − 18 − 55       = 302 idle cycles (80.5% idle)
```

The next sample's goertzel run (cycle 375) begins **~300 cycles after** the mag session
finishes (~cycle 75). **The budget closes with very large margin.** ITAG is timing-safe.

| Metric | Current | ITAG |
|---|---|---|
| goertzel active | 6 | 18 |
| mag session (boundary sample only) | 1 + 3×6 = 19 | 1 + 9×6 = 55 |
| worst-case active (boundary sample) | 25 | 73 |
| idle on boundary sample | 350 | 302 |
| idle % (boundary) | 93.3% | 80.5% |

---

## 2. Area impact

Counting **flip-flops** (the dominant area term after the shared multiplier). GF180
DFF ≈ 2.5 µm² is used only for order-of-magnitude context.

### 2.1 goertzel_core

| Item | Current | ITAG | Δ DFF |
|---|---|---|---|
| v-state regs (`v1*/v2*`) | 6 × 24 = 144 | 18 × 24 = 432 | **+288** |
| FSM state (TMR ×3) | 3 bits × 3 = 9 | 5 bits × 3 = 15 | **+6** |
| Input sample reg | `x_q15_r` 24 | `x/y/z_q15_r` 72 | **+48** |
| Multiplier / adder / sat logic | shared, 1× | shared, 1× | 0 |

> 📝 **Clarification on initial area estimates.** Initial design projections reported "+294 DFFs"
> counting only the 12 v-registers (+288) and the state widening (+6). They **omitted**
> (a) the two new input-sample registers `y_q15_r`, `z_q15_r` (+48 DFF), and,
> more significantly, (b) the `magnitude_compute` snapshot expansion below.

### 2.2 magnitude_compute

| Item | Current | ITAG | Δ DFF |
|---|---|---|---|
| `sv1`, `sv2` snapshots | 6 × 24 = 144 | 18 × 24 = 432 | **+288** |
| `sc` coefficient snapshot | 3 × 24 = 72 | **keep 3 × 24 = 72** (coeffs shared across axes) | **0** |
| `active_axis` counter | — | 2 bits | +2 |
| FSM state (TMR ×3) | 3 bits × 3 = 9 | 3 bits × 3 = 9 | 0 |

**Recommendation:** keep `sc` as a 3-entry array (one coefficient set, shared by all
three axes) rather than the `sc[0:2][0:2]` shown in the fixed-point skill. The skill
itself notes "coefficients same per axis, index for clarity" — indexing for clarity
would cost an unnecessary +144 DFF. We will index a single `sc[bin]` by `active_bin`.

### 2.3 axis_sequencer (net *reduction*)

| Item removed | Δ DFF |
|---|---|
| `axis_a/b/c` (vote2 triplicated index) | −6 |
| `scrub_cnt` (10-bit) + `scrub_strobe` | −11 |
| `current_axis` output reg | −2 |
| `core_y_n`, `core_z_n` added output regs | +32 |
| **Net** | **+13** |

(The two extra 16-bit output registers slightly outweigh the removed axis-tracking
flops; the *logic* simplification — removed mux + scrub + advance FSM — is the real win.)

### 2.4 Net area delta

```
goertzel_core       : +288 (v) +6 (state) +48 (xyz input) = +342
magnitude_compute   : +288 (snapshots) +2 (axis cnt)      = +290
axis_sequencer      :                                        +13
--------------------------------------------------------------------
TOTAL                                                     ≈ +645 DFF
```

> 📝 **Bottom line on area:** the honest number is **≈ +645 DFF**, roughly **2.2×**
> the initial estimate of "+294". The difference is almost entirely the `magnitude_compute`
> snapshot expansion (+288), which the initial estimate did not account for.
> At ~2.5 µm²/DFF this is ≈ 1600 µm² — still **negligible** against the shared 24×24
> multiplier and the 600×600 µm die budget, and still far below Option 2 (sample
> buffering) from the README tradeoff table. The conclusion ("area cost is negligible")
> holds; only the magnitude of the delta is corrected.

---

## 3. Power impact

| Metric | Current | ITAG |
|---|---|---|
| goertzel active duty | 6/375 = 1.6% | 18/375 = 4.8% |
| goertzel datapath switching | 1× | **≈3×** (three axes updated per sample) |
| Multiplier idle fraction (non-boundary) | 98.4% | 95.2% |
| mag sessions per **block** | 1 (of 3 bins) | 1 (of 9 pairs) |
| mag multiplies per **block** | 9 | 27 |
| mag active as fraction of block | 19 / (512×375) ≈ 0.01% | 55 / (512×375) ≈ 0.03% |

**Discussion.**
- The dominant dynamic-power term is the shared multiplier, which stays **operand-isolated
  (frozen at 0) ≥95% of cycles** under ITAG (Invariant 10 preserved). Its per-request
  switching is unchanged; only the number of requests rises 3× on goertzel and 3× on
  the (rare) mag session.
- goertzel datapath switching scales ~3× because three axes are now updated every sample
  instead of one. In absolute terms this is small: 12 extra active cycles per 375-cycle
  sample, all in the same narrow datapath.
- Leakage rises in proportion to the +645 DFF (§2), i.e. ≈0.5–1% of a design whose cell
  count is dominated by the multiplier and register bank. Immaterial at 180 nm / 1.8 V.
- **Net:** a modest (~3×) increase in an already-tiny dynamic term, no change to the
  isolation strategy that keeps the multiplier dark. Power remains dominated by leakage,
  which grows <1%. A precise figure requires a post-synthesis `.lib`-based power run
  (LibreLane), out of scope for RTL Phase 1.

---

## 4. Latency improvement (the actual motivation)

The current design rotates axes **per block**, so a given axis is only observed once
every 3 blocks:

```
Current (block = 512 samples @ 26.667 kHz = 19.2 ms/block):
  Block N   : X magnitudes produced
  Block N+1 : Y magnitudes produced   (+19.2 ms after X)
  Block N+2 : Z magnitudes produced   (+38.4 ms after X)
  → worst-case inter-axis latency: 38.4 ms; full 3-axis coverage every 57.6 ms.
  → a simultaneous 3-axis fault is smeared across 3 different blocks and may be
    missed within the window it occurs (README "known limitation").
```

```
ITAG:
  Every block N : X, Y, Z magnitudes all produced together.
  → inter-axis latency: 0. All three axes evaluated against threshold in the
    same block, from the same 512 samples.
  → detection latency per axis improves from up to 57.6 ms (worst axis) to a
    single 19.2 ms block for ALL axes.
```

Axis attribution also becomes **structural rather than inferred**: `mag_axis_idx` is
driven by the mag FSM's `active_axis` counter, not by a snapshot of a separately-advancing
`current_axis` in `axis_sequencer` (which today requires the `saxis` snapshot precisely
because the sequencer may have already advanced). This removes an entire class of
attribution-timing bugs (of the same family as the `mag_out`-always-zero bug documented
in CHANGELOG.md).

**This is the core justification for ITAG:** it closes the simultaneous-multi-axis
detection gap that the README explicitly lists as an unresolved limitation.

---

## 5. Radiation-hardening impact

| Aspect | Current | ITAG | Assessment |
|---|---|---|---|
| goertzel FSM TMR | 3-bit `vote3` ×3 | **5-bit `vote5` ×3** | Voter widened, same bitwise-majority pattern. Single-bit SEU in one copy still corrected next edge. |
| goertzel illegal-state recovery | `default → S_IDLE` (7 of 8 codes legal) | `default → S_IDLE` (**19 of 32 codes legal → 13 illegal codes**) | Larger illegal-code space, but *all* map to `S_IDLE` in one clock (Invariant 4). Recovery guarantee unchanged. |
| Datapath TMR | v-regs not triplicated (Rule C) | 18 v-regs not triplicated (Rule C) | Consistent. Tripling the datapath count does raise the *raw* SEU cross-section of unprotected state ~3×, but this is a **deliberate, documented** area/power tradeoff. See note below. |
| axis_sequencer TMR | `axis_a/b/c` (vote2) + 1024-cycle scrub | **removed** | Net **reduction** in attack surface: the triplicated axis index + scrub machinery is deleted. Polling FSM `ps_a/b/c` TMR is **retained**. |
| magnitude FSM TMR | 3-bit `vote3` ×3 | 3-bit `vote3` ×3 (unchanged; still 8 states) | No change. `active_axis`/`active_bin` counters are datapath (Rule C), same as today's `active_bin`. |

**Note on the 3× datapath cross-section.** ITAG triples the number of *unprotected*
Goertzel state bits (144 → 432). Per the project's Rule C, v1/v2 are intentionally not
triplicated. The practical mitigation is unchanged: an SEU in a v-register corrupts at
most one bin/axis magnitude for **one 512-sample block**, after which `block_clear` zeroes
all state and the resonator re-converges. Because the fault flag is *sticky*, a spurious
over-threshold from a single upset could latch `fault_flag` — but this is already true of
the current design for the one active axis, and is the intended fail-safe (false-positive-
biased) behavior for a safety monitor. **Recommendation:** if the widened cross-section is
a concern, Phase 2+ could add an optional periodic scrub (`block_clear`-driven zeroing is
already effectively a 512-sample scrub) or revisit triplicating v-state — but this is a
*policy* decision outside the primary architectural scope and is flagged, not assumed.

**Overall:** ITAG is radiation-neutral-to-slightly-positive on control logic (removes the
axis-index TMR/scrub), and consistent with the existing Rule C philosophy on datapath. The
one honest caveat is the 3× larger unprotected v-state cross-section, mitigated by the
per-block clear.

---

## 6. Backward compatibility

| Module / interface | Change under ITAG | Impact |
|---|---|---|
| `fault_flagger.v` | **None** (RTL unchanged). Still consumes `mag_in`, `mag_bin_idx`, `mag_axis_idx`, `mag_in_valid`, `sample_done`, drives `block_clear`. | Now receives **9** `mag_out_valid` pulses/block instead of 3; sticky-fault comparator handles any count. `sample_done` still once/sample. Block counter contract intact. |
| Effective block size | Stays **512** (`top.v` override retained). | No counter re-parameterization. |
| `tmr_reg_bank.v` | None. | Same APB map, same `cfg_c0/c1/c2`, `cfg_threshold`. All 3 axes reuse the same 3 coefficients. |
| `spi_apb_interface.v`, `spi_master.v`, `apb.v` | None. | Burst still delivers X/Y/Z; ITAG simply stops discarding Y/Z. |
| `axis_sequencer` ↔ `goertzel_core` | `core_x_n` → `core_x_n` + `core_y_n` + `core_z_n`; `goertzel_core` gains `y_n`, `z_n` ports; `current_axis` port **removed**. | Port-list change; `top.v` rewiring. |
| `goertzel_core` ↔ `magnitude_compute` | v-output/input set grows 6 → 18; `axis_in` port **removed** from `magnitude_compute`. | Port-list change; `top.v` rewiring. |
| `top.v` | Remove `current_axis` wire, add `core_y_n/core_z_n`, connect 18 v-wires. | Integration-only edits. |
| Testbenches (`tb/tb_top.v`, per-module) | Port-name updates; add 9-pulse mag assertion (Phase 3). | Compile-time updates only. |

No change to the APB register map, no change to external chip pins, no change to the
SPI/sensor contract. **Backward compatibility is limited to internal port renaming and
`top.v` rewiring**, exactly as anticipated.

---

## 7. Summary of corrections to initial design estimates

The proposal is sound and the timing/latency conclusions hold. Three numeric points in
the initial projections should be corrected for accuracy (all in the "less optimistic" direction, none
changes the go/no-go):

1. **Area delta is ≈ +645 DFF, not +294.** The initial estimate counted goertzel's +12 v-regs (+288)
   and +6 state bits but omitted the `magnitude_compute` snapshot expansion (+288) and the
   two extra input-sample registers (+48). Still negligible vs. the shared multiplier.
2. **Mag session is 55 cycles (1 `M_ARM` + 9×6), not 54.** The multiply *count* (27) is
   correct; each multiply is followed by a WAIT state. Immaterial to the ~300-cycle margin.
3. **Effective block size is 512 via `top.v` override**, while `fault_flagger.v`'s default
   is 171 and `README.md` says 171. Pre-existing inconsistency to reconcile in Phase 4.

Additionally recommended (area, not correctness): keep `sc` as a 3-entry coefficient
snapshot indexed by bin (coefficients are shared across axes), avoiding an unnecessary
+144 DFF from a full `sc[axis][bin]` array.

---

## 8. Go / No-Go recommendation

**GO.** ITAG:
- fits the 375-cycle budget with ~300 idle cycles of margin (§1),
- costs ≈ +645 DFF ≈ 1600 µm², negligible against the die and multiplier (§2),
- raises dynamic power by a small, isolation-bounded amount (§3),
- eliminates the 38.4 ms worst-case inter-axis latency and closes the simultaneous-
  multi-axis detection gap the README lists as unresolved (§4),
- is radiation-neutral-to-positive on control logic, with one honest caveat about the
  3× larger unprotected v-state cross-section, mitigated by per-block clear (§5),
- requires **zero** changes to `fault_flagger`, `tmr_reg_bank`, or the SPI front-end (§6).

All ten Design Invariants remain satisfiable by the Phase-2 plan:
Q8.15 only, single shared multiplier, TMR on all three FSMs (goertzel widened to 5-bit),
SEU-safe defaults, `block_clear` priority, once-per-sample `sample_done`,
`default_nettype none`, explicit sign-extension, saturating 3-input sums, operand isolation.

**Recommended Phase-2 implementation order (unchanged from early projections):**
`goertzel_core.v` → `axis_sequencer.v` → `magnitude_compute.v` → `top.v`, then testbench,
then docs. Pausing here for review before touching RTL, as requested.
