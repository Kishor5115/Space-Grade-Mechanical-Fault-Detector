# PPA Report — Space-Grade Mechanical Fault Detector
## LibreLane RTL-to-GDSII Area Estimate Run

**Design:** `vibration_top` — Space-Grade Goertzel Vibration Fault Detector  
**Technology:** GlobalFoundries GF180MCU (gf180mcuD), 180 nm  
**Flow:** LibreLane Classic (OpenLane 2), Docker image `hpretl/iic-osic-tools:chipathon26`  
**Run tag:** `RUN_2026-06-11_07-38-49`  
**Run date:** 2026-06-11  
**Purpose:** **Initial area estimate** for SSCS Chipathon 2026 Track B submission.  
**GDS:** `librelane/runs/RUN_2026-06-11_07-38-49/final/gds/vibration_top.gds` (5.2 MB)

> **Note:** This is a first-pass area estimate run. Timing violations exist in the slow-corner
> (ss/125°C/4.5 V) because the `repair_design` post-global-placement step was disabled to
> work around an OpenROAD tool crash on this design size. The area and logic numbers are
> architecturally representative and suitable for chipathon area budgeting.

---

## 1. Area (Primary Estimate Goal)

| Metric | Value |
|---|---|
| Die size | 700 × 700 µm = **0.490 mm²** |
| Core area | 693.28 × 689.92 µm = **0.478 mm²** |
| Standard cell area (logic only) | **151,947 µm²** = 0.152 mm² |
| Sequential cell area (flip-flops) | 26,312 µm² |
| Combinational cell area | 95,243 µm² |
| Clock buffer/inverter area | 4,188 µm² |
| I/O buffer area | 92 µm² |
| Timing-repair buffer area | 6,531 µm² |
| Antenna diode area | 1,879 µm² |
| Core utilization (stdcells / core) | **31.8%** |
| Placement density target | 50% |
| Fill cells used (unused silicon) | 326,360 µm² (filler) |

### Area Breakdown by Cell Class

| Cell class | Count | Area (µm²) | % of stdcell area |
|---|---|---|---|
| Multi-input combinational | 4,656 | 95,243 | 62.7% |
| Sequential (DFF) | 352 | 26,312 | 17.3% |
| Timing-repair buffers | 119 | 6,531 | 4.3% |
| Clock buffers | 64 | 3,850 | 2.5% |
| Tap cells | 3,117 | 13,685 | 9.0% |
| Endcap cells | 352 | 1,545 | 1.0% |
| Antenna cells | 428 | 1,879 | 1.2% |
| Inverters | 280 | 2,463 | 1.6% |
| Buffers | 7 | 92 | 0.1% |

**Total placed instances:** 22,696 (including fill)  
**Logic instances (stdcell only):** 9,395

### TMR Area Impact

The design employs Triple Modular Redundancy on all critical FSM state registers and
debounce counters. The sequential cell count (352 DFFs) reflects this triplication.
Without TMR, the equivalent sequential area would be approximately **8,771 µm²** (one-third).
TMR adds ~17,541 µm² of register overhead (~11.5% of total stdcell area), which is the
expected cost for SEU-hardened space-grade design at this datapath width.

### Synthesis-Level Area

Yosys reported a pre-placement chip area of **123,919 µm²** for `vibration_top` (all
sub-modules inlined). After placement and routing with 119 hold-repair buffers and
428 antenna diodes inserted, the placed stdcell area is **151,947 µm²** — a
**22.6% increase** from synthesis to signoff due to physical optimisations.

---

## 2. Performance (Timing)

**Target clock:** `clk` = 50 ns period (20 MHz)

### Setup Timing by Corner

| Corner | Setup WNS (ns) | Setup TNS (ns) | Violations |
|---|---|---|---|
| nom_tt_025C_5v00 | **+17.44** | 0 | 0 ✅ |
| nom_ff_n40C_5v50 | +29.50 | 0 | 0 ✅ |
| nom_ss_125C_4v50 | -9.71 | -209.8 | 24 ⚠️ |
| max_tt_025C_5v00 | +16.17 | 0 | 0 ✅ |
| max_ff_n40C_5v50 | +28.68 | 0 | 0 ✅ |
| max_ss_125C_4v50 | **-11.99** | -261.6 | 24 ⚠️ |
| min_tt_025C_5v00 | +18.49 | 0 | 0 ✅ |
| min_ff_n40C_5v50 | +30.17 | 0 | 0 ✅ |
| min_ss_125C_4v50 | -7.84 | -167.0 | 24 ⚠️ |

**Setup violations are confined to the slow-corner (ss/125°C/4.5 V) only.**  
The tt and ff corners are clean with large positive slack (up to +30 ns). The ss
violations are a direct consequence of skipping `repair_design` post-global-placement
(which crashed on this design size). A full run with repair enabled is expected to
close timing in the ss corner; at 20 MHz with 50 ns budget the slack margin is
substantial in all other corners.

### Hold Timing

| Metric | Value |
|---|---|
| Hold WNS (worst across all corners) | **+0.105 ns** |
| Hold TNS (worst across all corners) | **0** (no violations) |
| Hold violations | **0** ✅ |

Hold timing is **clean across all 9 corners**. Minimum hold slack is +0.105 ns (ff corner).

### Pre-synthesis fmax

OpenROAD pre-PnR STA reported: **fmax = 36.75 MHz** (period_min = 27.2 ns), comfortably
above the 20 MHz target.

### Clock Skew

| Skew metric | Worst value |
|---|---|
| Setup skew (worst) | +0.525 ns |
| Hold skew (worst) | -0.525 ns |

---

## 3. Power

All power values are from post-route parasitic extraction (RCX) at nom_tt_025C_5v00.

### Power at nom_tt_025C_5v00 (Static / Leakage-dominated)

| Group | Internal (W) | Switching (W) | Leakage (W) | Total (W) | % |
|---|---|---|---|---|---|
| Sequential | 3.922e-03 | 2.828e-05 | 1.553e-07 | **3.950e-03** | 96.6% |
| Combinational | 9.070e-05 | 4.743e-05 | 6.122e-07 | **1.387e-04** | 3.4% |
| Clock | 0 | 0 | 1.734e-07 | **1.734e-07** | ~0% |
| **Total** | **4.013e-03** | **7.571e-05** | **9.410e-07** | **4.089e-03 W** | 100% |

> Sequential cells dominate at 96.6% because the nom_tt STA run uses a static
> (non-propagated clock) model with no clock switching. The true dynamic power
> including clock network is captured in the ff/tt corners below.

### Power at max_ff_n40C_5v50 (Worst-case dynamic)

| Total Power | 10.26 mW |
|---|---|
| Sequential | 4.913 mW (47.9%) |
| Combinational | 0.323 mW (3.1%) |
| Clock network | 5.028 mW (49.0%) |

The clock network dominates dynamic power at max corner — typical for TMR designs
where CTS must drive tripled register loads.

### Power Grid

| Metric | Value |
|---|---|
| Worst IR drop (VDD) | 95.9 µV |
| Avg IR drop (VDD, nom) | 5 µV |
| Worst IR drop (VSS) | 43.1 µV |
| Power grid violations | **0** ✅ |

IR drop is negligible at this frequency; the power grid is clean.

---

## 4. Routing Metrics

| Metric | Value |
|---|---|
| Total routed wire length | **200,283 µm** (~200 mm) |
| Total vias | 35,480 (all single-cut) |
| Global route wire length | 321,762 µm |
| Max route wirelength (single net) | 7,917.6 µm |
| Routed nets | 5,514 |
| DRC errors (final) | **0** ✅ |
| Antenna violations (final) | **0** ✅ |
| Magic DRC errors | **0** ✅ |
| LVS errors | **0** ✅ |
| Routing layers used | Metal1–Metal4 |

Routing converged to 0 DRC errors in 7 iterations (starting from 1,055 initial violations).

---

## 5. Physical Verification

| Check | Result |
|---|---|
| Magic DRC | **0 errors** ✅ |
| LVS (Netgen) | **0 errors** ✅ — XOR difference = 0 |
| Antenna violations (post-route) | **0** ✅ |
| Power grid violations | **0** ✅ |
| Disconnected pins (logic) | 8 (non-critical; antenna-diode nets) |

---

## 6. Quality-of-Results Summary

| Metric | Value | Status |
|---|---|---|
| Die area | 0.490 mm² | ✅ Area estimate complete |
| Stdcell area | 0.152 mm² | ✅ |
| Core utilisation | 31.8% | ✅ (headroom for future TMR expansion) |
| Setup timing (tt/ff corners) | WNS ≥ +16 ns | ✅ |
| Setup timing (ss corner) | WNS = -12 ns | ⚠️ Needs repair_design fix |
| Hold timing (all corners) | WNS = +0.105 ns | ✅ Clean |
| Total power (max corner) | 10.26 mW | ✅ Low-power target met |
| DRC / LVS | 0 errors | ✅ |

---

## 7. Area Estimate Interpretation (Chipathon Focus)

This run's primary purpose is an **area budget estimate** for the SSCS Chipathon 2026
Track B submission.

| Budget item | Area (µm²) | Notes |
|---|---|---|
| Core logic (synth estimate) | 123,919 | Yosys pre-placement |
| Placed stdcell area | 151,947 | Post-route (+22.6% from buffers/diodes) |
| Die area used | 490,000 | 700 × 700 µm |
| Available core area | 478,308 | |
| Utilisation achieved | 31.8% | Conservative for TMR |
| Recommended minimum die | ~500 × 500 µm | At 50% utilisation |
| **Recommended die for submission** | **600 × 600 µm** | Leaves margin for ECO |

**Key takeaway:** The logic core fits comfortably in 600 × 600 µm at ~42% utilisation,
or 500 × 500 µm at ~60% utilisation (tight but feasible without TMR on datapath).
With the current 700 × 700 µm setting, there is ~68% free core area which is intentionally
conservative for a first-pass estimate. The GF180MCU shuttle tile is typically
1 × 1 mm — this design occupies roughly **15% of a standard tile** in logic area.

---

## 8. Recommended Next Steps

1. **Fix ss-corner timing:** Enable `RUN_POST_GPL_DESIGN_REPAIR: true` once OpenROAD
   is updated, or add `set_multicycle_path` for the shared multiplier's 7-cycle
   fault-detection datapath.
2. **Shrink die to 600 × 600 µm:** Re-run at 40–45% density after repair_design is fixed.
3. **Add I/O ring:** Current run has no pad frame; add GPIO pads for SPI, APB, interrupt.
4. **DRC with KLayout:** Run `make openlane_clean && make openlane_run` after enabling
   KLayout DRC in config (`RUN_KLAYOUT_DRC: true`).
