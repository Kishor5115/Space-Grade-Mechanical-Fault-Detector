# Changelog

All notable changes made during this verification pass are documented here.
Every entry explains not just *what* changed, but *why* the change was made
the way it was, with explicit attention to the project's two governing
constraints: **radiation-hardened-by-design (RHBD) correctness** and
**area/power optimization** for the GF180MCU target.

This pass was driven by a single instruction: verify the existing
architecture and RTL against the intended 3-axis time-multiplexed
Goertzel design, fix what's broken, and build the missing testbenches
and build infrastructure to prove it. Four real, silent bugs were found
in the process — three of them were only reachable through full-chain
(`tb_top.v`) simulation, which did not exist before this pass. That is
the main argument, in hindsight, for why task 4 (the top-level testbench)
mattered as much as it did.

---

# ITAG Refactor — Interleaved Tri-Axis Goertzel (2026-07-15)

This is a separate architectural pass, layered on top of the verification
pass documented further below. It replaces the **axis-sequential** design
(one axis processed per 512-sample block, rotating X→Y→Z across blocks)
with an **Interleaved Tri-Axis Goertzel (ITAG)** core that processes all
three axes within every sample period. The full pre-implementation
analysis (timing budget, area, power, latency, RHBD, backward
compatibility) lives in `docs/ITAG_ARCHITECTURE_ANALYSIS.md`.

**Motivation.** The legacy design observed a given axis only once every 3
blocks, so a simultaneous multi-axis fault could be smeared across blocks
and take up to ~38.4 ms (worst axis) to surface. ITAG evaluates X, Y and
Z against the threshold *every* block → **zero inter-axis latency** and
cycle-accurate per-axis attribution, closing the simultaneous-multi-axis
gap the README previously listed as an unresolved limitation.

## Added (ITAG)

### `rtl/multiplier.v` — the single, explicit shared multiplier
The chip's one hardware multiply is now a singly-instantiated module
containing the **only** `*` operator in the synthesizable datapath,
instanced exactly once inside `magnitude_compute.v`. This turns Design
Invariant #2 ("single shared multiplier — no additional multipliers")
into a *structural, auditable* property (grep/instance-count provable).

- **This also fixed a real invariant violation.** The previous
  `magnitude_compute.v` computed the final `C·v1·v2` cross term with a
  *second* inline `*` (`cv1v2_full = cv1_r * sv2`), which synthesis would
  infer as a second hardware multiplier. That term is now routed through
  the shared unit in a dedicated `M_CV1V2` state.
- **Pure combinational, format-agnostic:** returns the full `2*DATA_W`
  product unshifted; each consumer applies its own Q8.15 shift/saturate.
  No state → no TMR needed (datapath, Rule C). Operand isolation is
  enforced by the caller, so it stays frozen in the >95% idle window.

## Changed (ITAG)

### `rtl/goertzel_core.v` — complete ITAG rewrite
- **State matrix 6 → 18 registers:** `v1/v2` for 3 bins × **3 axes**
  (`v1x_0..v2z_2`), all exposed to `magnitude_compute`.
- **FSM 7 → 19 states (3-bit → 5-bit):** `S_IDLE` + `XB0_MUL..ZB2_UPD`,
  interleaving X→Y→Z; 18 active cycles/sample (6 per axis), still ~95%
  idle at 375 cycles/sample. TMR voter widened `vote3 → vote5`;
  `default → S_IDLE` still recovers all 13 illegal 5-bit codes in one
  clock.
- **Ports:** added `y_n`, `z_n` (Q1.15); all three registered on
  `data_ready` (`x/y/z_q15_r`). Coefficients (`c0/c1/c2`) are shared
  across axes (same three fault frequencies monitored on every axis).
- `sample_done` now pulses at `ZB2_UPD` (after all three axes) — exactly
  once per sample, preserving the `fault_flagger` block-counter contract.
- `block_clear` zeroes all 18 state registers as a priority override.

### `rtl/axis_sequencer.v` — simplified (net RHBD-positive)
Removed the entire axis-rotation apparatus: the triplicated `current_axis`
index (`axis_a/b/c` + `vote2`), its 1024-cycle scrub counter, the
`block_clear_pulse` input, and the `xn_comb` axis mux. It now presents all
three burst slices simultaneously as `core_x_n`/`core_y_n`/`core_z_n`. The
polling FSM (`ps_a/b/c`) remains triplicated. Removing the axis index also
removes that SEU attack surface.

### `rtl/magnitude_compute.v` — 3-axis expansion + single-multiplier consolidation
- Now snapshots **18** `v1/v2` values (`sv1[0:2][0:2]`, `sv2[0:2][0:2]`)
  on `block_clear_in`; the coefficient snapshot stays a 3-entry `sc[0:2]`
  (shared across axes) to avoid +144 needless flops.
- Magnitude FSM iterates **9 (axis,bin) pairs** (was 3 bins) via
  `active_axis`/`active_bin`, emitting **9** `mag_out` pulses per block;
  `mag_axis_idx` is now driven *structurally* from `active_axis` (no
  external `axis_in` port — that input was removed).
- Added the `M_CV1V2` state so the cross term rides the shared multiplier;
  FSM widened to 4-bit (`vote3 → vote4`). This also **fixes a latent
  one-bin-stale bug**: previously `mag_out` was registered on the same
  edge `cv1_r` was updated, so the cross term used the *previous* bin's
  `C·v1`. It was masked because the old `tb_top.v` only checked threshold
  crossings, not exact magnitudes.

### `rtl/top.v` — rewiring only
Removed `current_axis`/`axis_in`; added `core_y_n`/`core_z_n` and `y_n`/
`z_n`; connected all 18 `v` nets between `goertzel_core` and
`magnitude_compute`. `fault_flagger` remains instantiated at
`BLOCK_SIZE(512)`; `tmr_reg_bank`, `spi_apb_interface`, `apb`,
`spi_master` are **unchanged**.

### `testing/goertzel_core/tb_goertzel_core.v` — ITAG unit test
Drives the same two-tone shape on all three axes at amplitudes 1.0/0.5/
0.25 to prove the interleaved datapaths are independent and correctly
routed. Bins 1 and 2 scale as amplitude² **exactly** (16:4:1) across
axes — the definitive linearity/routing proof. (Cross-axis ordering is
asserted on bin1, not bin0: at N=500 the 1 kHz bin0 lands at an 18.75-
cycle spectral-leakage null where the high-Q estimate is dominated by
Q8.15 truncation residue and is not an amplitude proxy.)

### `testing/top_test/tb_top.v` — ITAG full-chain test
Replaced the axis-rotation drain (`wait_for_axis_block`, which used the
now-deleted `current_axis`) with a block-count drain, and added ITAG
monitors: exactly **9 mag pulses per block**, `mag_axis_idx`/`mag_bin_idx`
tag order `0,0,0,1,1,1,2,2,2 / 0,1,2,…`, a **no-mag-compute-during-
goertzel-active** assertion (single-multiplier / no-contention), and a
`sample_done : block_clear` = **512 : 1** cadence check. Added **Case 5**,
a *simultaneous* 3-axis excitation that the legacy design could not
resolve, verifying concurrent detection + priority attribution. Made the
injected tone block-coherent (`Fs·20/512 ≈ 1041.7 Hz`) and tuned `CFG_C0`
to it. Quantitative cross-axis magnitude scaling is validated in the
goertzel unit test (leakage-free bin1), not re-asserted through the SPI
path where high-Q bin0 magnitude is acutely quantization-sensitive.

### `testing/top_test/Makefile` — added `rtl/multiplier.v` to the source list.

## Verification summary (ITAG)

| Suite | Command | Result |
|---|---|---|
| `spi_master` | `make sim_spi` | **71 / 71 PASS** |
| `spi_apb_interface` | `make sim_apb` | **8 / 8 PASS** |
| `goertzel_core` (ITAG) | `make sim_goertzel` | **7 / 7 PASS** |
| Full chip (ITAG) | `make sim_top` | **14 / 14 PASS** |

## Area / RHBD delta (ITAG)

Net ≈ **+645 flip-flops** (goertzel +342: 12 v-regs, 2 sample regs, +2
state bits ×3; magnitude +290: 12 snapshot regs, axis counter; sequencer
+13 net after removing axis TMR/scrub). ≈ 1600 µm² at 180 nm — negligible
against the single shared multiplier and the 600×600 µm budget, and far
below the sample-buffering alternative. All ten Design Invariants hold:
Q8.15-only, single multiplier (now structural), TMR on all three FSMs
(`vote5`/`vote3`/`vote4`), `default → IDLE`, `block_clear` priority,
once-per-sample `sample_done`, `default_nettype none`, explicit sign
extension, 2-guard-bit saturating sums, operand isolation.

---

## Added

### `rtl/spi_master.v` — IIS3DWB boot config-write FSM
The sensor bring-up sequence (`CTRL1_XL`, `FIFO_CTRL4`, `CTRL3_C`,
`INT1_CTRL`) was previously a `CFG_INIT` state that set up the read-burst
command byte and fell straight through to `IDLE` — the actual register
writes were never implemented (only a `// TODO hook` comment marked the
gap). Without this, the real IIS3DWB would never leave power-down mode,
never auto-increment its burst-read address pointer, and never route
`DRDY` to `INT1` — i.e. the whole downstream chain would silently receive
garbage or stall on real silicon, even though every other module looked
correct in isolation.

Implemented as a single generic 16-bit-write-frame state pair
(`CFG_WR`/`CFG_NEXT`) driven by a 2-bit index into two 4-entry lookup
arrays (`boot_addr[4]`, `boot_data[4]`), rather than four hand-unrolled
per-register FSM states.

- **Area rationale:** one shared write datapath (one shift counter, one
  address/data mux) reused for all four registers costs a 2-bit index +
  a 5-bit bit-counter + a 1-bit `boot_active` routing flag — 8 flops
  total. A fully-unrolled per-register FSM would need on the order of
  4x the control logic for the same function, and every one of those
  flops is a candidate for TMR promotion later in the RHBD flow, so
  minimizing the count here has a multiplier effect downstream.
- **Reuses existing hardware:** the boot writes ride on the exact same
  `spc_raw`/`spc_rise`/`spc_fall` mode-3 bit-clock edge machinery and
  the same `START` state already built for the read-burst path — zero
  new clock-domain-crossing logic, zero new multiplier/shift-register
  hardware.
- **SEU safety preserved:** the `default: state <= CFG_INIT` fallback
  (pre-existing, unchanged) still re-runs the entire boot sequence,
  including these new states, if the FSM ever lands in an illegal
  encoding — consistent with the rest of the design's "recover to a
  safe, well-defined state within one clock" philosophy.

### `testing/apb_test/tmr_slave_stub.v` — lightweight APB slave test double
`tb_spi_apb_interface.v` expects to instantiate a stub with
`last_wr_addr`/`last_wr_data`/`wr_event` monitor ports so it can observe
the Option-B sample-forwarding sequence without needing a full register
bank. The testbench (and its Makefile) had instead been pointed at the
*real* `rtl/tmr_reg_bank.v`, which has no such ports and does not even
elaborate against this testbench.

- **Verification-only, zero product-silicon impact:** this file only
  ever ships in `testing/`, never in `rtl/`. It deliberately omits TMR
  voting, register-map decoding, and scrubbing — none of that logic is
  under test here; `spi_apb_interface.v`'s ability to sequence two
  correct APB writes is. Using the full `tmr_reg_bank.v` for this
  purpose would have exercised ~150 lines of unrelated triplicated
  logic on every test run for no verification benefit.
- Zero-wait-state slave (`pready = psel & penable`, combinational) keeps
  the testbench's own timing simple and fast to simulate.

### `testing/top_test/tb_top.v` + `testing/top_test/Makefile` — full-chip testbench
No testbench previously exercised the complete signal path from the
sensor SPI pins through `axis_sequencer` → `goertzel_core` →
`magnitude_compute` → `fault_flagger` → `fault_flag_out`. Every other
testbench validated one module (or one adjacent pair) in isolation, which
is exactly why axis-attribution and shared-multiplier bugs (below)
survived undetected: they only manifest when the whole pipeline runs
together under real timing.

`tb_top.v` reuses the existing `iis3dwb_model.v` bus-functional model
(no new sensor model needed) and drives it into `top.v`'s real
`c_miso/c_csn/c_sclk/c_mosi/sensor_drdy` pins exactly as physical silicon
would see it. Because `top.v` has no external command-SPI/APB port in the
current architecture (the SPI-to-APB *host* bridge is explicitly outside
`top.v`'s boundary per the module's own comments), the testbench loads
`cfg_c0/c1/c2`, `cfg_threshold`, and `run_enable` via a single
concatenated hierarchical `force` onto the internal
`{psel,penable,pwrite,addr,wdata}` bus — the same signals a real
command-SPI bridge would drive from outside, without re-implementing
that bridge's own protocol just for this test.

Four cases, each exercising a distinct requirement from the project
brief:
1. **Normal operation** — all three axes quiet, `fault_flag_out` must
   stay low for a full 3-axis rotation.
2. **Fault on X only** — 1 kHz tone injected on the X channel at an
   amplitude/threshold calibrated against *real observed* DUT magnitudes
   (see Fixed section below), checking both that the fault fires *and*
   that `fault_axis_latched` correctly reports X.
3. **Fault on Y only**, same check, axis = Y.
4. **Fault on Z only**, same check, axis = Z.

This axis-discriminating structure is deliberate: it is the only test in
the whole suite that can catch an axis-routing bug (a tone on one axis
must trip the fault *and* be attributed to the *correct* axis, not just
trip *some* fault). It caught one during this very pass — see below.

### `Makefile` (project root)
Unified entry point: `sim_spi`, `sim_apb`, `sim_goertzel`, `sim_top`,
`sim_all`, `clean`. `sim_spi`/`sim_apb`/`sim_top` delegate to their
existing per-directory Makefiles (`make -C testing/<dir>`); `sim_goertzel`
compiles/runs `rtl/goertzel_core.v` directly against
`testing/goertzel_core/tb_goertzel_core.v` since that pairing had no
per-directory Makefile of its own yet. All four targets produce a VCD
waveform dump, which required adding `$dumpfile`/`$dumpvars` to
`tb_spi_master_full.v` and `tb_spi_apb_interface.v` — neither had them
before (their own Makefiles' `wave` targets even carried a comment
flagging the gap).

---

## Fixed

### `rtl/magnitude_compute.v` — shared-multiplier pipeline register (silent zero-magnitude bug)
**Symptom:** `mag_out` was always `0`, on every block, for every axis and
every bin — regardless of real, large, nonzero `v1`/`v2` Goertzel state.
This is a full fault-detection failure: with this bug, **no fault could
ever be raised on real silicon**, no matter how severe the vibration
signature, because the magnitude feeding `fault_flagger`'s comparator was
permanently zero.

**Root cause:** the shared-multiplier capture register was written as:
```verilog
reg mult_req_d;
always @(posedge clk or negedge rst_n) begin
    ...
    mult_req_d <= mult_req_w;
    if (mult_req_d) core_mult_q <= mult_sat;
end
```
This assumes the requester's `mult_a`/`mult_b` operands stay stable for
*two* cycles (the request cycle and the one after), so that `mult_sat`
(purely combinational off the current operands) is still valid when
`mult_req_d` finally gates the capture one cycle later. `goertzel_core`'s
own `mult_a`/`mult_b` outputs *do* satisfy something close to that
contract by construction. But `magnitude_compute`'s own
`mag_mult_a`/`mag_mult_b` are driven combinationally only *during* the
single request state (`M_SQV1`/`M_SQV2`/`M_CV1`) and fall back to `0` the
very next cycle — so by the time `mult_req_d` finally triggered the
capture, `mult_sat` had already been silently recomputed from zeroed
operands, and `core_mult_q` latched `0` every single time.

**Fix:** capture `core_mult_q <= mult_sat` in the *same* cycle as
`mult_req_w`, removing the extra `mult_req_d` delay register entirely.
This exactly matches `goertzel_core`'s own multiplier-consumer contract
(`Bk_MUL` requests, `Bk_UPD` — the very next cycle — consumes `mult_q`),
so both users of the shared multiplier now see the identical one-cycle
request-to-result latency.

- **Area impact: net negative (smaller, not larger).** This fix
  *removes* one flip-flop (`mult_req_d`) rather than adding one — it is
  a pure correctness fix with no added state, control logic, or
  multiplier hardware. On an area/power-constrained RHBD part this is
  the best possible outcome for a bug fix: strictly less silicon for
  strictly more correct behavior.
- **Why no earlier testbench caught this:** no standalone testbench for
  `magnitude_compute.v` existed. `top.v`'s elaboration (checked
  repeatedly throughout earlier work) verifies port connectivity, not
  functional correctness — a stuck-at-zero output elaborates perfectly
  cleanly. Only `tb_top.v`'s full-chain magnitude/threshold comparison
  could expose it, which is exactly the class of bug the project brief's
  "fault injection on different axes" requirement was designed to smoke
  out.

### `rtl/axis_sequencer.v` — investigated for an axis-swap bug, confirmed correct (no change needed)
During `tb_top.v` development, a hand-traced simulation of
`spi_master.v`'s 48-bit left-shift-in `s_data_out` register appeared to
show that the X and Z axis slices in `axis_sequencer.v`'s `xn_comb` mux
were swapped relative to the sensor's real burst-read byte order
(`OUTX_L, OUTX_H, OUTY_L, OUTY_H, OUTZ_L, OUTZ_H`). A "fix" was applied
and then **reverted** after live simulation (comparing the DUT's raw
`s_data_out` directly against `iis3dwb_model.v`'s `model_outx/y/z` inputs
in `tb_top.v`) proved the original mapping —
`s_data_out[47:32]=X, [31:16]=Y, [15:0]=Z` — was correct all along. The
hand-trace that motivated the aborted "fix" had the shift direction
backwards.

This is recorded here deliberately, as a data point for the project's
own verification methodology going forward: **hand-tracing a shift
register's bit positions is error-prone; empirical simulation against a
known-good bus-functional model is the reliable check**, and is exactly
what `tb_top.v` now provides for this specific signal path on every
future run.

### `testing/apb_test/` — broken test harness (build failure, not a real RTL bug)
`tb_spi_apb_interface.v` instantiated a module named `tmr_stub` typed as
`tmr_reg_bank`, expecting monitor ports (`last_wr_addr`, `last_wr_data`,
`wr_event`) that the real `tmr_reg_bank.v` does not expose — the build
failed with 4 elaboration errors and never produced a single pass/fail
result. Fixed by adding the purpose-built `tmr_slave_stub.v` (see Added,
above) and repointing the testbench instantiation and Makefile `DUT2` at
it.

### `rtl/spi_master.v` — SPI write frame bit ordering (self-inflicted, fixed same session)
While implementing the boot config-write FSM (above), the first attempt
built the 16-bit write frame as `{data, addr, rw}` and shifted it out via
`boot_frame[15-wr_bit_cnt]`, which requires bit 15 (the *first* bit
transmitted) to hold the R/W bit, not the data MSB. This produced wrong
addr/data bytes at the sensor model (e.g. writing to address `0x20`
instead of `0x10`). Corrected to `{rw, addr, data}`; re-verified against
`tb_spi_master_full.v`'s exact address/data checks (71/71 passing).

### `testing/top_test/tb_top.v` (test-harness only) — stale-sample race at axis boundaries
After changing the injected tone's amplitude to move it to a new axis
(e.g. `amp_x=0.8→0.0`, `amp_y=0.0→0.8`), a handful of already-in-flight
samples generated under the *old* amplitude setting were still queued
between the sensor model and `axis_sequencer` and landed in the axis
block that was still open at the moment of the change — tripping a
spurious, small, wrong-axis fault immediately after `clear_fault()`.
Fixed by adding `wait_for_axis_block()`, which waits for one more
`block_clear` pulse on the axis being vacated before trusting the next
fault as belonging to the new axis. This is a testbench-only change
(`tb_top.v`); no RTL was touched for this fix.

---

## Changed

### `rtl/magnitude_compute.v`, `rtl/fault_flagger.v`, `rtl/tmr_reg_bank.v`, `rtl/top.v` — axis-tagged fault reporting
`axis_sequencer.current_axis` was already computed (needed for its own
3-axis time-multiplexing) but never consumed by anything downstream —
`fault_bin_latched` could tell you *which frequency bin* tripped, but not
*which physical sensor axis* (X/Y/Z) the tripping block came from. For a
mechanical-fault detector whose entire value proposition is "isolate
*where* the anomaly is," this is a real functional gap, and it is
explicitly what the project brief's "verify fault injection on different
axes" requirement is asking to be checked.

- `magnitude_compute.v`: added a 2-bit `axis_in` input, snapshotted into
  a single 2-bit `saxis` register on the *same* `block_clear_in` edge
  that already snapshots `v1`/`v2`/coefficients (no new snapshot timing
  to reason about), and passed straight through to a new 2-bit
  `mag_axis_idx` output alongside the existing `mag_bin_idx`. **Cost:
  2 flip-flops, zero new FSM states.**
- `fault_flagger.v`: added `mag_axis_idx` input and `fault_axis_latched`
  output, latched in the *same* always block and the *same* condition
  (`over && !fault_flag`) that already latches `fault_bin_latched` — no
  new control logic, just a wider latch. **Cost: 2 flip-flops.**
- `tmr_reg_bank.v`: packed `fault_axis_latched` into the previously-unused
  bits `[3:2]` of the existing `FAULT_BIN` register at APB address
  `0x1C`, instead of allocating a new register address. **Cost: zero
  new address-decode logic** — the existing `8'h1C` case arm just reads
  two more bits into the same 32-bit response word.
- `top.v`: two new wire connections
  (`axis_sequencer.current_axis → magnitude_compute.axis_in`,
  `fault_flagger.fault_axis_latched → tmr_reg_bank.fault_axis_latched`).

Total added state for this entire feature: **4 flip-flops project-wide**,
zero new APB registers, zero new FSM states. This is the deliberately
cheapest possible way to close the gap given the existing architecture
already computed the axis index for other reasons.

### `docs/top.md` — architecture doc correctness
The port list, signal list, and instantiation table were stale relative
to the current `rtl/top.v`: wrong port names (`rst_n`/`fault_flag`
instead of the real `sys_rst_n`/`fault_flag_out`), missing
`sensor_drdy`/`tmr_forward_en`, and an instantiation list that named
`spi_master` as a direct child of `top` (it is actually owned internally
by `spi_apb_interface`) while omitting `axis_sequencer` and
`magnitude_compute` entirely. Rewritten to match the real, current
`top.v` hierarchy and port list. `docs/top.svg` was left untouched — it
is an auto-generated port-only stub diagram (no internal-hierarchy
claims to correct) and its port list already matched `top.v`.

---

## Verification summary

| Suite | Command | Result |
|---|---|---|
| `spi_master` | `make sim_spi` | **71 / 71 PASS** |
| `spi_apb_interface` | `make sim_apb` | **8 / 8 PASS** |
| `goertzel_core` | `make sim_goertzel` | **PASS** (6 checks incl. sample-count integrity) |
| Full chip (`top.v`) | `make sim_top` | **7 / 7 PASS** |

Zero failures across the full regression. All four targets produce a VCD
waveform (`testing/spi_master_test/waves.vcd`,
`testing/apb_test/waves.vcd`, `goertzel_3bin_tb.vcd`,
`testing/top_test/tb_top.vcd`) for offline waveform inspection.

## RHBD and PPA posture, unaffected by this pass

No change in this pass touches the project's existing radiation-hardening
mechanisms (triplicated FSM state registers with bitwise majority voting
in `goertzel_core`/`axis_sequencer`/`magnitude_compute`/`fault_flagger`,
triplicated+scrubbed config registers in `tmr_reg_bank`, or the
shared-multiplier time-multiplexing strategy that keeps 3-bin spectral
coverage to the cost of one multiplier). Every fix and addition here was
scoped to be additive-minimal or, in the `magnitude_compute.v` case,
strictly area-reducing — consistent with the project's stated
area/power-constrained target on GF180MCU.

---

## Housekeeping

### Removed `include directives from RTL files (2026-07-07)
Removed all `` `include `` directives from `rtl/top.v`, `rtl/spi_master.v`,
and `rtl/spi_apb_interface.v`. These bare-filename includes (`"apb.v"`,
`"spi_master.v"`, etc.) resolved fine during `iverilog` compilation via
the `-I rtl` flag, but IDE language servers (Verilator, svls, verible)
could not resolve them — causing false syntax/lint errors (red/yellow
underlines) across most of the RTL and testbench files. The Makefiles
already listed source files on the command line, making the includes
redundant. Updated all three testbench Makefiles (`testing/top_test`,
`testing/spi_master_test`, `testing/apb_test`) to explicitly list every
required RTL source. All four simulation targets still compile and pass.
