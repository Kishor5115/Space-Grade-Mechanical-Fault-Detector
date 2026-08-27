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
analysis inaccurate.` No real voltage-source/pad locations were supplied, because this macro is not
yet placed in a chip-level padring. The reported worst IR drop (109 µV) assumes power delivered
uniformly at the macro's boundary — it reflects LibreLane's default, not any actual pad geometry.

**This must be re-run once the macro's position in the chip-level padring and its actual power/ground
pad locations are known.** Treat the current number as a placeholder, not a sign-off result.

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
