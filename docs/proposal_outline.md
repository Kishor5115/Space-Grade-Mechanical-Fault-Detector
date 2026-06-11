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

```text
       OFF-CHIP SATELLITE ENVIRONS             │           ASIC STANDALONE PADRING BOUNDARY
┌────────────────────────────────────────┐     │     ┌───────────────────────────────────────────┐
│ STMicroelectronics IIS3DWB MEMS Sensor │     │     │             [3.3V VDDIO Ring]             │
│  ┌──────────────────────────────────┐  │     │     │             [1.8V VDD Ring]               │
│  │ Piezoelectric MEMS Transducer    │  │     │     │                                           │
│  └────────────────┬─────────────────┘  │     │     │  ┌───────────┐             ┌───────────┐  │
│                   ▼                    │     │     │  │  S_CLK    │────────────>│Glitch     │  │
│  ┌──────────────────────────────────┐  │     │     │  │  RST_N    │────────────>│Filters    │  │
│  │ 16-bit PCM ADC (fs=26.667 kHz)   │  │     │     │  └───────────┘             └─────┬─────┘  │
│  └────────────────┬─────────────────┘  │     │     │                                  │      │
│                   ▼                    │     │     │  ┌───────────┐                   ▼      │
│  ┌──────────────────────────────────┐  │────>│────>│  │  S_INT1   │───────────>[Sync Mesh]   │
│  │ SPI Slave Interface & Interrupter│  │<───│<───>│  │  S_SPI Bus│<──────────>[SPI Master]  │
│  └──────────────────────────────────┘  │     │     │  └───────────┘                   │      │
└────────────────────────────────────────┘     │     │                                  ▼      │
                                               │     │                        ┌──────────────────┐
┌────────────────────────────────────────┐     │     │                        │Internal APB Bus  │
│       Satellite Flight Computer        │     │     │                        │(Interleaved/Gnd) │
│  ┌──────────────────────────────────┐  │────>│────>│  ┌───────────┐         └─────────┬────────┘
│  │ Command Master SPI Interface     │  │<───│<───>│  │  C_SPI Bus│────────> [Bridge]  │      │
│  └──────────────────────────────────┘  │     │     │  └───────────┘                  │      │
│                                        │     │     │                                 ▼      │
│  ┌──────────────────────────────────┐  │     │     │  ┌───────────┐         ┌──────────────────┐
│  │ Hardware Alarm Monitor Interrupt │  │<────│<────│  │ ALARM_IRQ │<────────│ TMR Config Regs  │
│  └──────────────────────────────────┘  │     │     │  └───────────┘         └─────────┬────────┘
└────────────────────────────────────────┘     │     │                                  │      │
                                               │     │                                  ▼      │
                                               │     │                        ┌──────────────────┐
                                               │     │                        │Goertzel Core IP  │
                                               │     │                        │(32-bit Accum)    │
                                               │     │                        └──────────────────┘
