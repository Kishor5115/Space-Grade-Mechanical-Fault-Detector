# System Architecture — Space-Grade Mechanical Fault Detector

> **SSCS Chipathon 2026 — Track B (Sensor Circuits) | Team B22 — Team Space Jam**

---

## 1. Overview

This document describes the detailed system architecture of the Space-Grade Mechanical Fault Detector ASIC. The chip connects to an off-chip STMicroelectronics **IIS3DWB** digital MEMS vibration sensor via SPI, computes frequency-domain energy for three programmable fault frequencies across all three physical sensor axes (X, Y, Z) simultaneously, and asserts a **sticky digital fault flag** when any (bin, axis) energy exceeds a configurable threshold.

The key microarchitectural innovation is the **Interleaved Tri-Axis Goertzel (ITAG)** core, which processes all three axes every sample period using a single shared hardware multiplier — eliminating inter-axis detection latency while remaining within the ~600×600 µm die budget of the GF180MCU node.

---

## 2. Chip-Level Boundary

```
                ┌────────────────────────────────────────────────────────────────────┐
SATELLITE       │                        rtl/top.v (chip boundary)                   │
STRUCTURAL      │                                                                    │
MEMBER          │  Pin        Direction  Description                                 │
   │            │  ─────────────────────────────────────────────────────────────    │
   ▼            │  clk        IN         System clock (16 MHz, single domain)        │
 [IIS3DWB]──────│  sys_rst_n  IN         Active-low synchronous reset                │
 MEMS Sensor    │  c_miso     IN         SPI MISO (sensor → ASIC)                   │
   │  │  │  │   │  c_csn      OUT        SPI chip-select, active-low                 │
   │  │  │  │   │  c_sclk     OUT        SPI bit clock (Mode 3, idles high)          │
   │  │  │  │   │  c_mosi     OUT        SPI MOSI (ASIC → sensor)                   │
   │  │  │  └───│  sensor_drdy IN        DRDY interrupt from sensor (async)          │
   │  │  └──────│─────────────────────────────────────────────────────────          │
   │  └─────────│─ (SPI bus)                                                        │
   └────────────│─────────────────────────────────────────────────────────          │
                │  cmd_sclk   IN         Command-SPI bit clock (host → ASIC, async) │
                │  cmd_csn    IN         Command-SPI chip-select, active-low        │
                │  cmd_mosi   IN         Command-SPI MOSI (host → ASIC, write-only) │
                │  tmr_forward_en IN     0=Option A (local only), 1=Option B        │
                │  fault_flag_out OUT    Sticky digital fault flag → host/RISC      │
                └───────────────────────────────────────────────────────────────────┘
```

An external host/RISC-V core connects to `cmd_sclk`/`cmd_csn`/`cmd_mosi` to program coefficients, threshold, and control. `cmd_spi_slave` samples these pins asynchronously, 2-FF-synchronizes them into the core clock domain, and turns each 40-bit `{address, data}` frame into an APB write via its own `apb` master and the `apb_arb2` arbiter — so the internal APB bus (`tmr_reg_bank`'s register map, §5 of `IO_SPECIFICATION.md`) is reachable from outside `top.v` without any additional clock domain. During register-level unit testing, the internal APB bus may also be driven directly by a testbench.

---

## 3. Functional Block Diagram

```
  sensor_drdy (async) ──► ff_2_sync ──► spi_master
                                             │
  c_miso ──────────────────────────────────► │ (SPI Mode 3 burst read)
  c_csn  ◄────────────────────────────────── │
  c_sclk ◄────────────────────────────────── │
  c_mosi ◄────────────────────────────────── │
                                             │ s_data_out[47:0]
                                             │ s_data_out_valid
                                             ▼
                                    spi_apb_interface
                                    ┌───────────────────────────────────────┐
                                    │ Local holding register (48-bit)        │
                                    │ Addr 0x0: STATUS { data_ready }        │
                                    │ Addr 0x4: SAMPLE0 = burst[31:0]        │
                                    │ Addr 0x8: SAMPLE1 = {0, burst[47:32]} │
                                    │                                        │
                                    │ Option B: fwd FSM pushes each sample  │
                                    │ to tmr_reg_bank over APB              │
                                    └──────────────────┬────────────────────┘
                                                       │ req_valid / req_addr /
                                                       │ resp_rdata (local poll)
                                                       ▼
                                             axis_sequencer
                                    ┌────────────────────────────────┐
                                    │ Polling FSM (TMR, vote3)        │
                                    │ Polls STATUS → SAMPLE0 → SAMPLE1│
                                    │ Demuxes 48-bit burst into:      │
                                    │   core_x_n[15:0] = burst[47:32]│
                                    │   core_y_n[15:0] = burst[31:16]│
                                    │   core_z_n[15:0] = burst[15:0] │
                                    └───────┬────────────────────────┘
                                            │ core_data_ready (1 pulse/sample)
                                            │ core_x_n, core_y_n, core_z_n
                                            ▼
                                      goertzel_core (ITAG)
                              ┌───────────────────────────────────────────────┐
                              │ 19-state FSM (TMR, 5-bit vote5):               │
                              │  S_IDLE → XB0_MUL/UPD → XB1_MUL/UPD →        │
                              │           XB2_MUL/UPD → YB0_MUL/UPD → ...    │
                              │           ZB2_MUL/UPD → S_IDLE               │
                              │                                                │
                              │ Recursion: v[n] = x[n] + C·v[n-1] - v[n-2]   │
                              │ (Q8.15, fused saturating 3-input add)          │
                              │                                                │
                              │ 18 state registers: v1/v2 × 3 bins × 3 axes  │
                              │ Coefficients C0/C1/C2 shared across all axes  │
                              │ mult_req/mult_a/mult_b → shared multiplier    │
                              └──────────────────┬────────────────────────────┘
                                                 │ v1x_0..v2z_2 (18 wires)
                                                 │ mult_req, mult_a, mult_b
                                                 │ sample_done (1 pulse/sample)
                                                 ▼
                                        magnitude_compute
                              ┌───────────────────────────────────────────────┐
                              │ Owns the SINGLE chip-wide multiplier.v        │
                              │ Arbitrates: goertzel has priority;            │
                              │ mag engine steals idle window                  │
                              │                                                │
                              │ On block_clear:                                │
                              │  Snapshots 18 v1/v2 values                    │
                              │  Computes for each of 9 (axis,bin) pairs:     │
                              │    |X|² = v1² + v2² - C·v1·v2               │
                              │  Emits: mag_out[31:0], mag_bin_idx[1:0],     │
                              │         mag_axis_idx[1:0], mag_out_valid      │
                              │  (9 pulses per block, one per axis/bin)       │
                              └──────────────────┬────────────────────────────┘
                                                 │ mag_out, mag_bin_idx,
                                                 │ mag_axis_idx, mag_out_valid
                                                 ▼
                                          fault_flagger
                              ┌───────────────────────────────────────────────┐
                              │ TMR block counter (vote_cnt, 3 copies)        │
                              │ Counts sample_done pulses                     │
                              │ block_clear fires every BLOCK_SIZE (512)      │
                              │                                                │
                              │ Comparator: mag_in > cfg_threshold?           │
                              │   → Set sticky fault_flag                     │
                              │   → Latch fault_mag_latched, fault_bin_latched│
                              │   → Latch fault_axis_latched (X=0/Y=1/Z=2)   │
                              │ Cleared by explicit cfg_fault_clear write     │
                              └──────────┬───────────────────────────────────┘
                                         │ fault_flag, fault_mag/bin/axis_latched
                                         ▼
                                    tmr_reg_bank  ◄──── Internal APB bus
                              ┌──────────────────────────────────────────────┐
                              │ APB slave (triplicated + 1024-cycle scrub)   │
                              │ Register map (byte addr):                    │
                              │  0x00 CTRL       Write-1-pulse control       │
                              │  0x04 CFG_C0     Q8.15 Goertzel coeff bin 0  │
                              │  0x08 CFG_C1     Q8.15 Goertzel coeff bin 1  │
                              │  0x0C CFG_C2     Q8.15 Goertzel coeff bin 2  │
                              │  0x10 CFG_THRESHOLD Fault magnitude threshold │
                              │  0x14 STATUS     fault_flag (read-only)      │
                              │  0x18 FAULT_MAG  Latched tripping magnitude  │
                              │  0x1C FAULT_BIN  {axis[1:0], bin[1:0]}       │
                              └──────────────────────────────────────────────┘
                                         │
                                         ▼
                               fault_flag_out (to host/RISC core)
```

---

## 4. Module Hierarchy

```
top (rtl/top.v)
├── spi_apb_interface (rtl/spi_apb_interface.v)
│   ├── spi_master (rtl/spi_master.v)
│   │   ├── clk_divider (rtl/clk_divider.v)       — SPI clock generation (÷8)
│   │   ├── ff_2_sync (rtl/ff_2_sync.v)           — sensor_drdy CDC
│   │   └── ff_2_sync (rtl/ff_2_sync.v)           — s_miso CDC
│   └── apb (rtl/apb.v)                            — APB master (Option B forwarder, arb m0)
├── cmd_spi_slave (rtl/cmd_spi_slave.v)            — external config receiver
│   ├── ff_2_sync (rtl/ff_2_sync.v)               — cmd_sclk CDC
│   ├── ff_2_sync (rtl/ff_2_sync.v)               — cmd_csn CDC
│   └── ff_2_sync (rtl/ff_2_sync.v)               — cmd_mosi CDC
├── apb (rtl/apb.v)                                — APB master (command-SPI config, arb m1)
├── apb_arb2 (rtl/apb_arb2.v)                      — 2:1 APB arbiter (m1 priority)
├── tmr_reg_bank (rtl/tmr_reg_bank.v)             — APB slave, config/status
├── axis_sequencer (rtl/axis_sequencer.v)          — SPI sample demuxing
├── goertzel_core (rtl/goertzel_core.v)            — ITAG IIR engine
├── magnitude_compute (rtl/magnitude_compute.v)    — owns multiplier.v
│   └── multiplier (rtl/multiplier.v)              — single chip-wide multiplier
└── fault_flagger (rtl/fault_flagger.v)            — block counter + comparator
```

---

## 5. Signal Chain (Step-by-Step)

| Step | What Happens | Key Signal |
|---|---|---|
| 1 | `spi_master` runs IIS3DWB boot config on reset (4 register writes) | `state == CFG_INIT` |
| 2 | Sensor asserts `sensor_drdy` at 26.667 kHz after acquiring a sample | `sensor_drdy` (async) |
| 3 | `ff_2_sync` synchronizes `sensor_drdy` to the core clock | `sync_ready_w` |
| 4 | `spi_master` asserts `c_csn` low; shifts out 8-bit read command `0xA8` | `TX_ADDR` state |
| 5 | `spi_master` shifts in 48-bit burst: `{OUTX_H, OUTX_L, OUTY_H, OUTY_L, OUTZ_H, OUTZ_L}` | `RX_DATA` state |
| 6 | `spi_master` asserts `s_data_out_valid`; `spi_apb_interface` latches into `sample_reg` | `sm_data_out_valid` |
| 7 | `axis_sequencer` polls `STATUS` register; reads `SAMPLE0` then `SAMPLE1` | `S_POLL_REQ` → `S_PRESENT` |
| 8 | `axis_sequencer` presents X[15:0], Y[15:0], Z[15:0] simultaneously to `goertzel_core` | `core_data_ready` pulse |
| 9 | `goertzel_core` runs 18-state ITAG FSM: 6 cycles/axis × 3 axes | `XB0_MUL` → `ZB2_UPD` |
| 10 | For each (axis, bin): multiply C×v1 via shared multiplier, fused-add `v1_new = sat(x + C·v1 - v2)` | `mult_req`, `mult_q` |
| 11 | `goertzel_core` pulses `sample_done` at `ZB2_UPD` (one pulse per sample) | `sample_done` |
| 12 | `fault_flagger` increments TMR block counter; fires `block_clear` every 512 samples | `block_clear` |
| 13 | `magnitude_compute` snapshots all 18 v1/v2 values on `block_clear_in` | snapshot registers |
| 14 | `magnitude_compute` computes `|X|² = v1² + v2² - C·v1·v2` for 9 (axis,bin) pairs | 9 × `mag_out_valid` pulses |
| 15 | `fault_flagger` compares each `mag_out` to `cfg_threshold`; sets sticky `fault_flag` on first trip | `fault_flag`, `fault_axis_latched` |
| 16 | `fault_flag_out` asserts to host/RISC core; readable via `tmr_reg_bank` `STATUS` register | `fault_flag_out` |

---

## 6. Fixed-Point Datapath

| Signal | Width | Format | Notes |
|---|---|---|---|
| Sensor sample `x_n/y_n/z_n` from IIS3DWB | 16-bit | Signed 2's complement integer (Q1.15) | Delivered as raw PCM by IIS3DWB |
| Goertzel state `v1_k`, `v2_k` | 24-bit | Q8.15 signed | Sign-extended from 16→24 on input |
| Goertzel coefficient `C0/C1/C2` | 24-bit | Q8.15 signed | `C_k = 2·cos(2π·f_k/Fs)` |
| Shared multiplier product | 48-bit → 24-bit | Full product right-shifted 15, saturated to Q8.15 | Single chip-wide instance |
| Magnitude `\|X(f_k)\|²` | 32-bit | Unsigned integer (sum of squared Q8.15 values) | Compared to threshold |
| Threshold `cfg_threshold` | 32-bit | Unsigned integer | Programmed via APB writes |
| Block size | 512 samples | Fixed parameter | `BLOCK_SIZE` in `fault_flagger` |

**Goertzel recursion (per axis, per bin, every sample):**
```
v1_new = sat( x[axis] + C_k · v1 - v2 )    [Q8.15, fused 3-input add]
v2_new = v1_old
```

**Terminal magnitude (per axis/bin, once per 512-sample block):**
```
|X(f_k)|² = v1² + v2² - C_k · v1 · v2      [computed on shared multiplier]
```

---

## 7. Timing Budget

At 16 MHz system clock / 26.667 kHz sensor ODR:

| Period | Value |
|---|---|
| System clock period | 62.5 ns |
| Sensor sample period | 37.5 µs |
| Clock cycles per sample | 600 cycles |
| Goertzel active cycles per sample | 18 cycles (3.0%) |
| Magnitude computation (block boundary) | 55 cycles (9.2%) |
| Idle cycles (non-boundary sample) | 582 cycles (97.0%) |
| Worst-case margin (boundary sample) | 527 idle cycles |
| Detection latency | ≤ 19.2 ms (one block) |

---

## 8. Radiation Hardening Architecture

| Technique | Implementation | Targeted Failure Mode |
|---|---|---|
| TMR on `goertzel_core` FSM | 3×5-bit state (vote5), all copies driven from voted next-state | SEU flipping FSM state bit |
| TMR on `magnitude_compute` FSM | 3×4-bit state (vote4) | SEU flipping FSM state bit |
| TMR on `axis_sequencer` polling FSM | 3×3-bit state (vote3) | SEU flipping polling state |
| TMR + scrub on `tmr_reg_bank` config registers | 3 physical register copies + 1024-cycle periodic scrub | SEU flipping config bit |
| SEU-safe default states | All FSMs default→S_IDLE for any illegal encoding | Multi-bit SEU producing illegal code |
| Sticky fault flag with explicit clear | `fault_flag` only clears on `cfg_fault_clear` write | SET glitch on comparator |
| Async signal CDC | 2-stage D-FF synchronizer on `sensor_drdy` and `s_miso` | Metastability |
| SRAM-free design | All state in flip-flops only | Heavy-ion SRAM macro upsets |
| Block-period scrub on Goertzel state | `block_clear` zeroes all 18 v-regs every 512 samples | SEU on unprotected v-state |

---

## 9. Technology Target

| Parameter | Value |
|---|---|
| Foundry | GlobalFoundries GF180MCU |
| Node | 180 nm bulk CMOS |
| RTL-to-GDS Flow | LibreLane open-source |
| Standard Cell Library | `gf180mcu_fd_sc_mcl` |
| Core supply | 1.8 V |
| IO supply | 3.3 V |
| Target clock | 16 MHz (single domain) |
| Die budget | ~600×600 µm |
