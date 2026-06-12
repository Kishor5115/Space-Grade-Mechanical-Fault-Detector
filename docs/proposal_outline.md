# Space-Grade Mechanical Fault Detector

> **SSCS Chipathon 2026 — Track B (Sensor Circuits)**  
> Radiation-hardened by design (RHBD) ASIC for autonomous spacecraft vibration and mechanical fault detection using a mixed-precision Goertzel algorithm via the LibreLane standalone `gf180mcu` digital flow.

---

## Table of Contents

- [Overview](#overview)
- [System Architecture](#system-architecture)
- [Key Features](#key-features)
- [Mixed-Precision Mathematical Datapath](#mixed-precision-mathematical-datapath)
- [Module Reference](#module-reference)
- [Radiation Hardening Strategy (RHBD)](#radiation-hardening-strategy-rhbd)
- [Target Technology Configurations](#target-technology-configurations)
- [Repository Structure](#repository-structure)
- [References](#references)
- [Team](#team)
- [Project Status](#project-status)

---

## Overview

Modern spacecraft and satellite systems exhibit distinct high-frequency mechanical vibration signatures prior to catastrophic mechanical failure — reaction wheel bearing degradation, cryogenic pump wear, deployment gear micro-cracks. Detecting these signatures early at the structural edge is critical for autonomous fault isolation and telemetry reduction.

This project implements an autonomous, low-power, radiation-tolerant edge-processing ASIC capable of real-time spectral vibration analysis using a custom **mixed-precision Goertzel DSP core** on the GlobalFoundries 180 nm (GF180MCU) node.

Bypassing vulnerable, unhardened on-chip mixed-signal design, the ASIC integrates directly with an off-chip **STMicroelectronics IIS3DWB Digital MEMS Vibration Sensor**. The design uses a strictly register-based, SRAM-free architecture to evaluate structural anomalies natively and asserts a physical hardware interrupt upon verifying a persistent fault condition.

---

## System Architecture

The ASIC operates inside a standalone custom padring configuration (`workshop_padring_librelane`), removing any dependency on an external platform harness like Efabless Caravel.

![System Architecture Block Diagram](arch.png)

NOTE: Image is AI Generated

The system boundary is divided into three zones:

**Off-Chip Satellite Environs** → **ASIC Standalone Padring** → **Digital ASIC Core Boundary (`vibration_top.v`)**

The physical satellite structure transmits acoustic shockwave vibrations to the **STMicroelectronics IIS3DWB** MEMS sensor. The sensor outputs 16-bit 2's complement PCM samples at a 26.667 kHz ODR over a 5-wire SPI bus (`S_CSN`, `S_SCLK`, `S_MOSI`, `S_MISO`, `S_INT1`) into the padring. A separate **Command SPI Bus** from the satellite master computer (`C_CSN`, `C_SCLK`, `C_MOSI`, `C_MISO`) programs runtime coefficients via the APB bridge. The `ALARM_IRQ` pad drives the interrupt line back to the host.

Inside the core, the **Interrupt-Driven Synchronizer Mesh** (`spi_master.v`) captures raw 16-bit 2's complement PCM samples from the sensor SPI bus. Because the Goertzel engine operates in **Q8.15 fixed-point**, a dedicated **PCM-to-Q8.15 Format Converter** sign-extends and re-aligns each 16-bit integer sample into the Q8.15 representation before it enters the filter pipeline — introducing no additional pipeline stages beyond a single combinational shift-and-sign-extend operation.

Sample hand-off from the SPI clock domain to the core clock domain is handled by a lightweight **two-stage flip-flop synchroniser** on the `sample_valid` strobe. No FIFO or elastic buffer is required: at a 26.667 kHz sensor ODR against a 5–10 MHz core clock, the sample arrival rate is slow enough that a simple D-FF pair eliminates metastability with zero area or latency overhead.

The Command SPI bus from the satellite master computer is bridged onto the internal register fabric via the **SPI-to-APB Bridge** (`apb_bridge.v`), which translates incoming SPI command frames into structured APBv2 read/write transactions on the internal bus. This cleanly decouples the command interface clock domain from the core processing clock domain without shared-memory hazards. The computed magnitude from the **Multiplier-Shared Goertzel Filter Engine** (`goertzel_core.v`) feeds into the **Power Comparator & Fault Flagger** (`fault_flagger.v`). All dynamic configuration registers are triplicated across the **TMR Configuration Registers** (`config_regs.v`) and arbitrated by the **Internal APB Bus**.

---

## Key Features

### Direct Digital MEMS Interfacing
High-efficiency `spi_master.v` core engineered specifically to parse the ST IIS3DWB sensor data stream:
- 16-bit 2's complement PCM output at 26.667 kHz ODR
- 6.3 kHz mechanical bandwidth
- Boot protocol support including `CTRL1_XL [0x10=0xA0]`, `CTRL2_XL [0x11=0x0C]`, and `INT1_CTRL [0x0D=0x01]`

### PCM-to-Q8.15 Format Converter
The ST IIS3DWB outputs raw samples as **16-bit signed 2's complement integers**. The Goertzel core operates in **Q8.15 fixed-point** (1 sign bit, 8 integer bits, 15 fractional bits). A dedicated combinational converter sits at the boundary between `spi_master.v` and `goertzel_core.v`, performing a sign-aware shift-and-extend to map the integer sample into the Q8.15 domain with no precision loss and no additional clock cycle latency.

### Flip-Flop Based Clock Domain Crossing (No FIFO)
Sample delivery from the SPI capture clock domain to the core processing clock domain uses a **two-stage D-FF synchroniser** on the `sample_valid` strobe — no FIFO, no elastic buffer. At the IIS3DWB's 26.667 kHz ODR against a 5–10 MHz core clock, the inter-sample gap spans hundreds of core clock cycles, making a minimal synchroniser both sufficient and area-optimal for metastability elimination.

### SPI-to-APB Configuration Bridge
The satellite master computer programs runtime coefficients (`C`, `THRESHOLD`, `N`) over a dedicated **Command SPI Bus** (`C_CSN`, `C_SCLK`, `C_MOSI`, `C_MISO`). The `apb_bridge.v` module translates these incoming SPI command frames into fully compliant **APBv2 read/write transactions** on the internal register bus. This hard clock-domain boundary between the command SPI interface and the core processing clock prevents shared-bus timing hazards during mid-flight coefficient updates.

### Mixed-Precision Fixed-Point Datapath

| Signal | Width | Format |
|---|---|---|
| Sensor output `x_raw` | 16-bit | Signed 2's complement integer (native SPI capture) |
| Converted sample `x[n]` | 16-bit | **Q8.15 fixed-point** (post PCM→Q8.15 converter) |
| Coefficient `C` | 16-bit | Q2.14 fixed-point (`C = 2·cos(2π·fₖ/fₛ)`) |
| State Accumulators `v₁, v₂` | 32-bit | Signed integer |
| Magnitude `\|X(fₖ)\|²` | 32-bit | Unsigned integer |
| Threshold | 32-bit | Integer |
| Block Size `N` | 16-bit | Integer (256–512) |

The Q8.15 format for converted samples provides 8 integer bits and 15 fractional bits, giving sufficient headroom for the accumulator growth over a 256–512 sample block while preserving sub-LSB fractional precision through the recursive IIR stages.

### Dynamic Mid-Flight Calibration
The host processing node loads coefficient boundaries dynamically via the **SPI-to-APB Bridge** (`apb_bridge.v`), which translates Command SPI frames into APBv2 register writes targeting the TMR configuration banks. This modifies baseline fault profiles across changing orbit conditions without halting or resetting the running Goertzel filter.

### Autonomous Alarm Verification Mesh
A multi-stage TMR'd debounce counter requires the structural anomaly threshold to be breached for **5 consecutive Goertzel calculation blocks** before asserting the primary `ALARM_IRQ` hardware interrupt — neutralizing Single Event Transient (SET) false flags caused by cosmic ray hits.

### SRAM-Free Register Matrix
Fully flip-flop-only implementation. All temporary state maps directly to standard logic cell D-FFs, rendering the system impervious to macro-level SRAM cell corruption from heavy-ion strikes.

---

## Mixed-Precision Mathematical Datapath

The core Goertzel filter maps a single second-order IIR transfer function step recursively for each incoming time-domain vibration sample.

**State Recursion:**

$$v[n] = x[n] + \left(C \cdot v[n-1]\right) - v[n-2]$$

**Terminal Magnitude:**

$$|X(f_k)|^2 = v_1^2 + v_2^2 - \left(C \cdot v_1 \cdot v_2\right)$$

**Precision Grid:**

| Stage | Operation | Bit Width |
|---|---|---|
| Raw SPI capture `x_raw` | 16-bit 2's complement integer from IIS3DWB | 16-bit signed integer |
| PCM → Q8.15 conversion | Sign-extend + fractional-align into Q8.15 domain | 16-bit Q8.15 (combinational, zero latency) |
| Coefficient multiply `C · v[n-1]` | Q2.14 × 32-bit integer | 48-bit raw → arithmetic right-shift `>>> 14` → 34-bit truncated to 32-bit |
| Accumulator update | 32-bit integer add/subtract | 32-bit signed |
| Magnitude squares `v₁², v₂²` | 32-bit × 32-bit | 64-bit → compared against 32-bit threshold |
| Cross-term `C · v₁ · v₂` | Q2.14 × 32-bit × 32-bit | Scaled final compare |

The 14-bit arithmetic right shift on every multiplier output stage maintains accumulator synchronization while preserving the maximum representable precision at each pipeline stage. The PCM-to-Q8.15 converter is purely combinational — it does not add a pipeline register and introduces no extra clock cycle on the sample path.

---

## Module Reference

| Module | Source File | Description |
|---|---|---|
| `spi_master` | `rtl/spi_master.v` | Synchronous serial master core tracking ST IIS3DWB bootup protocols, interrupt synchronization, and 16-bit 2's complement PCM sample capture |
| `pcm_to_q815` | `rtl/pcm_to_q815.v` | Combinational PCM-to-Q8.15 format converter; sign-extends and fractional-aligns raw 16-bit integer samples from the sensor SPI path into the Q8.15 domain required by the Goertzel core |
| `apb_bridge` | `rtl/apb_bridge.v` | SPI-to-APB bridge translating incoming Command SPI frames from the satellite master computer into fully compliant APBv2 read/write transactions on the internal configuration register bus |
| `config_regs` | `rtl/config_regs.v` | Structural TMR storage framework housing dynamic runtime variables: `C` (16-bit Q2.14), `THRESHOLD` (32-bit integer), `N` (16-bit integer) |
| `goertzel_core` | `rtl/goertzel_core.v` | Area-optimized fixed-point math execution core featuring resource-shared multipliers and parity-checked 32-bit storage arrays; operates on Q8.15 formatted samples |
| `fault_flagger` | `rtl/fault_flagger.v` | Squaring block computing magnitude limits, executing comparison boundaries, and running the TMR debounce validation state machine |
| `tmr_voter` | `rtl/tmr_voter.v` | Primitively synthesized combinational 2-out-of-3 majority voting element deployed across all triplicated state fields |
| `vibration_top` | `rtl/vibration_top.v` | High-level chip enclosure bounding the 1.8 V core logic, connecting internal nodes to level-shifted physical pad ring frames |

---

## Radiation Hardening Strategy (RHBD)

GlobalFoundries 180 nm bulk silicon is a commercial planar CMOS process with no inherent physical radiation tolerance. Structural defense is therefore enforced at every level of the design hierarchy.

### 1. RTL-Level Microarchitectural Hardening (SEU / SET Mitigation)

**Triplicated Structural Configuration (TMR)**  
Every dynamic register slice holding mathematical coefficients or operational bounds is instantiated across three identical register sub-banks (Bank A, Bank B, Bank C). A combinational 2-out-of-3 majority voter assesses bit state continuously. Synthesis pruning is explicitly blocked using `dont_touch` / `keep` attributes to prevent the tool from optimizing away the redundant logic.

**Shadow Accumulator Parity Tracking**  
Mathematical accumulators `v₁` and `v₂` dual-track state data alongside dedicated parity compilation bits. If an SEU corrupts an accumulator register bit mid-calculation, a parity mismatch flag triggers an instantaneous soft-reset of the active Goertzel block — wiping the localized error before it can propagate to a fraudulent terminal alarm condition.

**Temporal Control Signal Dampening**  
Critical asynchronous control lines (`RST_N`, `S_INT1`) pass through narrow RC/delay-chain filtering networks to completely attenuate SET logic glitches under **1.5 ns** pulse width.

### 2. Physical Placement & Layout Hardening (SEL / MBU Mitigation)

**Continuous Heavy Substrate Tapping**  
Well and substrate contacts are hard-forced at an ultra-dense pitch of **< 12 µm**, bypassing standard cell automated configurations. This guarantees low substrate resistance, preventing the local voltage drop required to trigger parasitic PNPN latch-up paths.

**Enclosed Guard Ring Perimeters**  
Active NMOS and PMOS standard cell islands are framed inside heavy continuous P⁺ and N⁺ diffusion isolation guard ring structures to collect stray electron-hole pairs generated by high-energy cosmic ions before they can diffuse to sensitive nodes.

**Spatially Interleaved Bus Networks**  
Parallel address, control, and data tracks are physically separated via interleaved V_SS ground tracks. Angled heavy-ion particle tracks crossing multiple metal lines hit ground paths instead of neighboring data lines, eliminating Multi-Bit Upset (MBU) correlation across a single ion strike.

**Relaxed Density Routing Budgets**  
Physical routing configuration restricts maximum cell layout capacity (`PL_TARGET_DENSITY`) strictly to **35% – 45%**. This provides whitespace tracks for complex TMR routing interconnects and enables the automated place-and-route tool to insert protective Antenna Diodes across long interconnect wire runs.

---

## Target Technology Configurations

| Parameter | Value |
|---|---|
| Foundry Node | GlobalFoundries GF180MCU |
| RTL-to-GDS Flow | LibreLane Open-Source Design Compilation Suite |
| Pad Implementation | 14-Pin Standalone Custom Layout (`workshop_padring_librelane`) |
| Standard Cell Library | `gf180mcu_fd_sc_mcl` (7-track, multi-channel) |
| Source Language | Verilog HDL |
| Core Supply Voltage | 1.8 V |
| IO Supply Voltage | 3.3 V |
| Target Core Clock | 5 MHz – 10 MHz |
| Sample Window | 37.5 µs |

---

## Repository Structure

```
.
├── docs/           # Technical specification proposals and architecture block diagrams
├── rtl/            # Radiation-hardened synthesizable Verilog HDL source
│   ├── apb_bridge.v
│   ├── config_regs.v
│   ├── fault_flagger.v
│   ├── goertzel_core.v
│   ├── pcm_to_q815.v
│   ├── spi_master.v
│   ├── tmr_voter.v
│   └── vibration_top.v
├── tb/             # Verilog testbenches with ST IIS3DWB bus functional models
├── verification/   # Golden fixed-point reference software packages (Python)
├── sim/            # Waveform generation profiles, simulation configs, and validation tracking
├── scripts/        # Synthesis run-files, compilation setups, and automated verification loops
└── openlane/       # Custom physical design parameters and RHBD layout config files
```

---

## References

1. **STMicroelectronics IIS3DWB**: Datasheet - IIS3DWB - Ultrawide bandwidth, low-noise, 3-axis digital vibration sensor.
2. **IEEE Reference**: [https://ieeexplore.ieee.org/document/10127757](https://ieeexplore.ieee.org/document/10127757)
3. **EE671 Goertzel ASIC**: [https://github.com/abhineet-agarwal/EE671-Goertzel-ASIC](https://github.com/abhineet-agarwal/EE671-Goertzel-ASIC)


---

## Team

**B22 — Team Space Jam**  
SSCS Chipathon 2026, Track B (Sensor Circuits)

---

## Project Status

> **Phase 1 — Architecture Planning and System Boundary Definition**

- [x] System architecture defined
- [x] Block diagram completed
- [x] Mixed-precision datapath specification finalized
- [x] RHBD strategy documented
- [ ] RTL implementation in progress
- [ ] Functional simulation and verification
- [ ] Synthesis and timing closure (LibreLane)
- [ ] Physical layout and DRC/LVS sign-off
- [ ] Final GDS submission

---

*Built with LibreLane · GF180MCU · gf180mcu_fd_sc_mcl*
