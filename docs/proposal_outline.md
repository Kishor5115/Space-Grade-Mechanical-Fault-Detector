# Space-Grade Mechanical Fault Detector

## SSCS Chipathon 2026 — Track B (Sensor Circuits)

Radiation-hardened by design (RHBD) ASIC for autonomous spacecraft vibration and mechanical fault detection using a mixed-precision Goertzel algorithm via the LibreLane standalone `gf180mcu` digital flow.

---

## Overview

Modern spacecraft and satellite systems exhibit distinct high-frequency mechanical vibration signatures prior to catastrophic mechanical failure (e.g., reaction wheel bearing degradation, cryogenic pump wear, deployment gear micro-cracks). Detecting these signatures early at the structural edge is critical for autonomous fault isolation and telemetry reduction.

This project implements an autonomous, low-power, radiation-tolerant edge processing ASIC capable of real-time spectral vibration analysis using a custom mixed-precision Goertzel DSP core on the GlobalFoundries 180nm (GF180MCU) node. Bypassing vulnerable, unhardened on-chip mixed-signal design, the ASIC integrates directly with an off-chip **STMicroelectronics IIS3DWB Digital MEMS Vibration Sensor**. The design utilizes a strictly register-based, SRAM-free architecture to evaluate structural anomalies natively and asserts a physical hardware interrupt upon verifying a persistent fault condition.

---

## System Architecture

The ASIC operates inside a standalone custom padring configuration (`workshop_padring_librelane`), removing any dependency on an external platform harness like Efabless Caravel.


<add image>

## Key Features
* Direct Digital MEMS Interfacing: High-efficiency hardware spi_master.v core engineered specifically to parse the STMicroelectronics IIS3DWB sensor data stream (16-bit 2's complement PCM, $26.667\text{ kHz}$ Output Data Rate, $6.3\text{ kHz}$ mechanical bandwidth).
* Mixed-Precision Fixed-Point Datapath: * Input Vector ($x[n]$): Native 16-bit signed integer passed directly from the SPI shift registers with zero format-conversion latency.Frequency Coefficient ($C$): 16-bit fixed-point format configured in Q2.14 precision (1 sign bit, 1 integer bit, 14 fractional bits) mapping dynamic target bounds between $-2.0$ and $+2.0$ ($C = 2 \cdot \cos(2\pi \frac{f_k}{f_s})$).
* State Accumulators ($v_1, v_2$): Dual historical state channels expanded to 32-bit signed integers to safely absorb severe bit-growth overflow across long block iteration boundaries ($N = 256$ to $512$).Dynamic Mid-Flight Calibration: Host processing node loads coefficient boundaries dynamically via an SPI-to-APB hardware translation bridge, modifying baseline fault profiles across changing orbit conditions.
* Autonomous Alarm Verification Mesh: Multi-stage TMR'd verification counter ensures that the structural anomaly limit must be breached for 5 consecutive calculation blocks before raising the primary hardware alarm, neutralizing Single Event Transient (SET) false flags.
* SRAM-Free Design Matrix: Fully registers-only implementation. All temporary state retention maps directly to standard logic cell flip-flops, rendering the system impervious to macro-level memory corruption.


## Mixed-Precision Mathematical Datapath
The core Goertzel filter maps a single second-order Infinite Impulse Response (IIR) transfer function step recursively for each incoming time-domain vibration sample. To prevent precision degradation or bit misalignment, variables scale across the following architectural grid:$$\text{State Equation: } v[n] = x[n] + \left(C \cdot v[n-1]\right) - v[n-2]$$$$\text{Terminal Magnitude Equation: } |X(f_k)|^2 = v_1^2 + v_2^2 - (C \cdot v_1 \cdot v_2)$$Structural Precision GridSample Input ($x[n]$): 16 bits $\rightarrow$ [15:0] Signed Integer.Coefficient ($C$): 16 bits $\rightarrow$ [15:0] Fixed-Point Q2.14.Internal Multiplier Node ($C \cdot v[n-1]$): 16-bit Q2.14 multiplied by 32-bit Integer $\rightarrow$ Output intermediate scaled down by 14 bits via arithmetic right shifts (>>> 14) to produce a synchronized 32-bit signed integer accumulator update vector.State Nodes ($v[n-1], v[n-2]$): 32 bits $\rightarrow$ [31:0] Signed Integer.


Module Name,Source File,Description
spi_master.v,rtl/spi_master.v,"Synchronous serial master core tracking ST IIS3DWB bootup protocols, interrupt synchronization, and 16-bit sample capture."
apb_bridge.v,rtl/apb_bridge.v,"Configuration interface translating external Command SPI packets to localized, structured APBv2 bus operations."
config_regs.v,rtl/config_regs.v,"Structural TMR storage framework housing dynamic runtime variables (C [16-bit Q2.14], THRESHOLD [32-bit Integer], N [16-bit Integer])."
goertzel_core.v,rtl/goertzel_core.v,Area-optimized fixed-point math execution core featuring resource-shared multipliers and parity-checked 32-bit storage arrays.
fault_flagger.v,rtl/fault_flagger.v,"Squaring block computing magnitude limits, executing comparison boundaries, and running the TMR debounce validation state machine."
tmr_voter.v,rtl/tmr_voter.v,Primitively synthesized combinational 2-out-of-3 majority voting element deployed across triplicated state fields.
vibration_top.v,rtl/vibration_top.v,"High-level chip enclosure bounding the 1.8V core logic, connecting internal nodes to level-shifted physical pad ring frames."


## Radiation Hardening Strategy (RHBD)
Because GlobalFoundries 180nm bulk silicon is a commercial planar CMOS process with no inherent physical radiation tolerance, structural defense metrics are enforced across all levels of design entry:

1. RTL-Level Microarchitectural Hardening (SEU/SET Mitigation)
Triplicated Structural Configuration: Every dynamic register slice holding mathematical coefficients or operational bounds is instantiated across three identical register sub-banks (Bank A, Bank B, Bank C). A combinational 2-out-of-3 majority voter assesses bit state continuously. Synthesis pruning is explicitly blocked using tracking attributes:

* Shadow Accumulator Parity Tracking: Mathematical accumulators ($v_1, v_2$) dual-track state data alongside dedicated parity compilation bits. If a Single Event Upset (SEU) corrupts an accumulator register bit mid-calculation, a parity mismatch flag triggers an instantaneous soft-reset of the active block, wiping out the localized error before it can evaluate into a fraudulent terminal alarm condition.
* Temporal Control Signal Dampening: Critical asynchronous lines (RST_N, S_INT1) pass through narrow RC/Delay-chain filtering networks to completely attenuate Single Event Transient (SET) logic glitches under $1.5\text{ ns}$.

2. Physical Placement & Layout Hardening (SEL/MBU Mitigation)
* Continuous Heavy Substrate Tapping: Well and substrate contacts bypass standard cell automated configurations and are hard-forced at an ultra-dense spacing grid ($< 12\mu\text{m}$ pitch). This guarantees low substrate resistance, preventing the local voltage drop required to activate latch-up paths.
* Enclosed Guard Ring Perimeters: Active NMOS and PMOS standard cell islands are framed inside heavy continuous $P^+$ and $N^+$ diffusion isolation guard structures to collect stray electron-hole pairs generated by high-energy cosmic ions.
* Spatially Interleaved Bus Networks: Parallel address, control, and data tracks driving cross-core traffic are physically separated via interleaved $V_{SS}$ ground tracks. Angled heavy-ion tracks crossing multiple wires hit ground paths instead of neighboring data lines, eliminating Multi-Bit Upsets (MBU).
* Relaxed Density Routing Budgets: The physical routing configuration inside LibreLane restricts maximum cell layout capacity (PL_TARGET_DENSITY) strictly to 35% – 45%. This provides extensive whitespace tracks for complex TMR routing interconnects and allows the automated tool to patch in protective Antenna Diodes across long interconnect wire runs.

## Target Technology Configurations
* Foundry Development Node: GlobalFoundries GF180MCU

* Automated RTL-to-GDS Flow: LibreLane Open-Source Design Compilation Suite

* Physical Pad Implementation: 14-Pin Standalone Custom Layout Template (workshop_padring_librelane)

* Standard Cell Library Selection: gf180mcu_fd_sc_mcl (7-track, multi-channel library)

* Source Hardware Language: Verilog HDL

## Repository Directory Tree

├── docs/           # Technical high-level specification proposals and architecture block diagrams
├── rtl/            # Radiation-hardened synthesizable Verilog HDL source implementations
│   ├── apb_bridge.v
│   ├── config_regs.v
│   ├── fault_flagger.v
│   ├── goertzel_core.v
│   ├── spi_master.v
│   ├── tmr_voter.v
│   └── vibration_top.v
├── tb/             # Verilog testbenches incorporating ST IIS3DWB bus functional behavioral models
├── verification/   # Golden algorithmic fixed-point reference software packages (Python framework)
├── sim/            # Waveform generation profiles, simulation configurations, and validation tracking
├── scripts/        # Compilation run-files, design synthesis setups, and automated verification loops
└── openlane/       # Custom physical design layout parameters and RHBD target config configuration files


## Team
B22: Team Space Jam

## Project Status
Current Status: Phase 1 Architecture Planning and System Boundary Definition.
