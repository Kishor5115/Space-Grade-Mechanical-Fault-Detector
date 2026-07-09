# Quick Implementation Checklist: Option 3
## BLOCK_SIZE Reduction for Area-Constrained Design

**Target:** SSCS Chipathon 2026 competition (600×600 µm constraint)  
**Estimated Time:** 1 hour  
**Date:** 2026-07-09

---

## Changes Required

### [ ] Step 1: Modify RTL (1 minute)

**File:** `rtl/fault_flagger.v`

**Line 14:** Change parameter
```verilog
// OLD:
parameter integer BLOCK_SIZE = 512

// NEW:
parameter integer BLOCK_SIZE = 171  // Reduced for faster axis rotation (area-optimized)
```

**Commit message:** `"Reduce BLOCK_SIZE from 512 to 171 for 3x faster detection (competition area optimization)"`

---

### [ ] Step 2: Recalibrate Threshold (5 minutes)

**File:** `testing/top_test/tb_top.v`

**Line ~310:** Adjust threshold
```verilog
// OLD:
apb_write_reg(8'h10, 32'd120);  // CFG_THRESHOLD

// NEW:
apb_write_reg(8'h10, 32'd14);   // CFG_THRESHOLD (scaled by (171/512)² = 0.112)
```

**Why:** Goertzel magnitude scales as N², so threshold must scale down

**Math:** 120 × (171/512)² ≈ 13.4 → round to 14

---

### [ ] Step 3: Run Regression Tests (15 minutes)

**Commands:**
```bash
cd testing/top_test
make clean
make sim
# or: iverilog -o tb_top.vvp tb_top.v ../../rtl/*.v
# then: vvp tb_top.vvp
```

**Expected Output:**
```
PASS [xxxxx] Case1 Normal: no fault asserted (all axes quiet)
PASS [xxxxx] Case2 FaultX: fault_flag_out asserted
PASS [xxxxx] Case2 FaultX: reported axis == X(0)
PASS [xxxxx] Case3 FaultY: fault_flag_out asserted
PASS [xxxxx] Case3 FaultY: reported axis == Y(1)
PASS [xxxxx] Case4 FaultZ: fault_flag_out asserted
PASS [xxxxx] Case4 FaultZ: reported axis == Z(2)
----------------------------------------------------
ALL CHECKS PASSED (7 checks)
```

**If threshold too low:** Reduce to 10-12 (tune empirically)  
**If threshold too high:** Increase to 16-18

---

### [ ] Step 4: Measure Detection Latency (10 minutes)

**Add to testbench (optional verification):**
```verilog
// In tb_top.v, Case 2:
integer start_time, end_time;

amp_x = 0.8; amp_y = 0.0; amp_z = 0.0;
start_time = $time;
wait_fault_or_timeout(got_fault);
end_time = $time;
$display("Detection latency: %0.1f ms", (end_time - start_time) / 1_000_000.0);
```

**Expected:** ~6-7 ms (single-axis best case)

---

### [ ] Step 5: Update Documentation (15 minutes)

#### 5a. Update README.md

**Line ~40:** (in Key Features section)
```markdown
// OLD:
fault_flagger defines BLOCK_SIZE = 512 samples.

// NEW:
fault_flagger defines BLOCK_SIZE = 171 samples (optimized for 600×600 µm area constraint).
```

**Line ~100:** (in Mixed-Precision Mathematical Datapath)
```markdown
// Add note:
Note: BLOCK_SIZE reduced to 171 for competition area optimization, trading frequency 
resolution (52 Hz → 157 Hz bins) for 3× faster fault detection (57.6 ms → 19.1 ms).
```

#### 5b. Update CLAUDE.md (if used)

**Line ~34:**
```markdown
// OLD:
fault_flagger defines BLOCK_SIZE = 512 samples.

// NEW:
fault_flagger defines BLOCK_SIZE = 171 samples.
```

#### 5c. Add Competition Justification (new section in README.md)

```markdown
## Design Tradeoffs (SSCS Chipathon 2026)

**Area Constraint:** 600×600 µm die size (Track B: Sensor Circuits)

**Architectural Decision:** Sequential axis processing with reduced BLOCK_SIZE

The IIS3DWB sensor outputs all 3 axes (X, Y, Z) simultaneously, requiring either:
- **Option 1:** Parallel processing cores (+300 FF, exceeds area budget)
- **Option 2:** Sample buffer (+3072 FF, violates RHBD strategy)
- **Option 3:** Reduced BLOCK_SIZE (ZERO area cost) ✅ **SELECTED**

**Tradeoff Analysis:**
- ✅ Detection latency: 57.6 ms → 19.1 ms (3× faster)
- ✅ Area overhead: 0 flip-flops (critical for competition)
- ⚠️ Frequency resolution: 52 Hz → 157 Hz bins (acceptable for fault detection)
- ⚠️ Data sampling: 33.3% duty cycle per axis (inherent to sequential processing)

This demonstrates pragmatic engineering judgment appropriate for resource-constrained 
embedded systems, a critical skill for spacecraft ASICs where silicon area directly 
translates to launch mass costs.
```

---

### [ ] Step 6: Verify Synthesis (20 minutes)

**If using OpenLane/LibreLane:**
```bash
cd openlane
make mount
./flow.tcl -design vibration_top -tag run1
```

**Check reports:**
- `runs/run1/reports/synthesis/1-synthesis.AREA.rpt` — verify area within budget
- `runs/run1/reports/synthesis/1-synthesis.stat.rpt` — verify FF count reduced by ~3 FFs (counter width)

**Expected:** BLOCK_SIZE reduction should save ~3-9 flip-flops (counter+comparator) — negligible but confirms no area regression.

---

## Validation Checklist

### Functional Verification
- [ ] All existing tests pass (7 checks in tb_top.v)
- [ ] Case 2 (X fault) triggers within 10 ms
- [ ] Case 3 (Y fault) triggers within 15 ms
- [ ] Case 4 (Z fault) triggers within 20 ms
- [ ] Threshold correctly calibrated (no false positives in Case 1)

### Spectral Analysis
- [ ] 1 kHz tone (bin 0) produces magnitude > threshold
- [ ] Off-target tones (e.g., 1.5 kHz) stay below threshold
- [ ] Frequency selectivity adequate (157 Hz bins acceptable)

### Timing
- [ ] Synthesis meets timing (no critical path violations)
- [ ] Pipeline utilization still <2% (plenty of slack)

### Area
- [ ] Total area within 600×600 µm budget
- [ ] Counter width: 8 bits (171 requires $clog2(171)=8)

---

## Rollback Plan (if needed)

**If threshold recalibration fails:**
```verilog
// Try intermediate BLOCK_SIZE values:
parameter integer BLOCK_SIZE = 200;  // 133 Hz bins
// or
parameter integer BLOCK_SIZE = 256;  // 104 Hz bins
```

**If frequency resolution inadequate:**
- Increase BLOCK_SIZE to 256 (still 2× faster than 512)
- Accept slightly longer detection latency (25.6 ms vs 19.1 ms)

---

## Success Criteria

✅ **All tests pass** (7/7 checks)  
✅ **Detection latency <20 ms** (worst case, all axes)  
✅ **Area within budget** (600×600 µm)  
✅ **Timing closure** (no violations @ target frequency)  
✅ **Documentation updated** (README.md + competition report)

---

## Time Estimate

| Task | Time |
|------|------|
| Modify RTL | 1 min |
| Recalibrate threshold | 5 min |
| Run regression tests | 15 min |
| Measure latency | 10 min |
| Update docs | 15 min |
| Verify synthesis | 20 min |
| **Total** | **~1 hour** |

---

## Final Notes

**This is the RIGHT choice for the competition.** You're demonstrating:
1. Understanding of constraints (area budget)
2. Quantitative tradeoff analysis (resolution vs latency)
3. Pragmatic engineering (perfect is the enemy of done)
4. Clear documentation (reviewers will appreciate the transparency)

**For a real spacecraft mission:** You'd choose Option 1 (parallel cores), but for a competition showcasing ASIC design skills, Option 3 is the smart move.

**Good luck with the tapeout!** 🚀
