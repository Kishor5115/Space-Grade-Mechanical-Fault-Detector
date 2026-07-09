# Space-Grade Vibration Pattern Anomaly Detector
## Chipathon Presentation Notes

---

# Project Overview

## Problem

Modern satellites continuously generate vibration data due to:
- Reaction wheels
- Mechanical fatigue
- Launch stresses
- Micro-meteor impacts

Streaming raw vibration data continuously to the onboard processor consumes bandwidth and power.

---

## Proposed Solution

We designed a space-grade edge-processing ASIC that performs onboard vibration anomaly detection.

Pipeline:

MEMS Sensor (IIS3DWB)
        ↓
SPI Master
        ↓
SPI-APB Interface
        ↓
Axis Sequencer
        ↓
Goertzel Core
        ↓
Magnitude Compute
        ↓
Fault Flagger
        ↓
TMR Register Bank
        ↓
Fault Interrupt to RISC-V

Instead of transmitting continuous raw vibration samples, only anomaly information is forwarded.

---

# Module 1 : SPI Master

## Purpose

- Interfaces directly with IIS3DWB
- Configures sensor after reset
- Reads XYZ acceleration samples
- Delivers 48-bit sample to the internal processing pipeline

## Key Features

- SPI Mode-3 (CPOL=1, CPHA=1)
- Burst read of 48-bit XYZ sample
- Automatic hardware initialization
- DRDY interrupt driven acquisition
- Valid/Ack handshake
- Single synchronous clock domain
- 2FF synchronizers for CDC

## Design Decisions

- Shared FSM for configuration and runtime acquisition
- Lookup-table based boot configuration
- Burst read reduces SPI overhead
- Event-driven acquisition lowers power
- Single clock domain simplifies STA
- Handshake prevents sample loss

---

# Module 2 : APB Master

## Purpose

Implements a standard AMBA APB Master that converts internal requests into APB bus transactions for accessing the TMR Register Bank.

## Key Features

- Standard APB protocol
- 3-state FSM
- Supports Read and Write
- Wait-state (PREADY) support
- Request/Done handshake

## Design Decisions

- APB selected due to low bandwidth register accesses
- Request-driven architecture minimizes switching activity
- Wait-state support allows slow peripherals
- Minimal FSM reduces area

---

# Module 3 : SPI-APB Interface

## Purpose

Communication wrapper between SPI Master and the internal register/bus architecture.

## Key Features

- Buffers latest sensor sample
- Local register interface
- Optional APB forwarding mode
- Independent forwarding FSM
- Valid/Ack interface with SPI Master

## Design Decisions

- Decouples sensor timing from processor timing
- Local buffering prevents data loss
- Option-A for fast bring-up
- Option-B enables TMR protected storage
- Edge-qualified requests prevent duplicate transactions

---

# Module 4 : TMR Register Bank

## Purpose

Provides a radiation-hardened configuration and status register bank using Triple Modular Redundancy (TMR).

It stores:

- Goertzel coefficients
- Detection threshold
- Control commands
- Fault status

and protects configuration against radiation-induced bit flips.

---

## Why TMR?

Space environments are susceptible to Single Event Upsets (SEUs), where radiation can randomly flip bits stored in flip-flops.

To improve reliability, each critical configuration register is stored three times.

The output is determined using majority voting.

---

## Register Map

0x00 : Control Register
- Start
- Stop
- Fault Clear

0x04 : Goertzel Coefficient C0

0x08 : Goertzel Coefficient C1

0x0C : Goertzel Coefficient C2

0x10 : Detection Threshold

0x14 : Fault Status

0x18 : Fault Magnitude

0x1C : Fault Information
- Frequency Bin
- Axis

---

## Key Features

- Triple Modular Redundancy (TMR)
- Majority Voter
- Periodic Configuration Scrubbing
- APB Slave Interface
- Programmable Coefficients
- Runtime Configuration
- Fault Status Registers

---

## Design Decisions

- Triplicated configuration registers improve SEU tolerance.
- Majority voting masks single-bit faults.
- Periodic scrubbing repairs corrupted replicas automatically.
- Configuration registers remain programmable through APB.
- Status registers are separated from configuration registers.

---

## Reliability Features

- Triple Modular Redundancy
- Majority Voting
- Periodic Scrubbing
- Single Event Upset mitigation
- Suitable for space applications

---

## What to Tell the Judges

The TMR Register Bank is the radiation-hardened configuration memory of our accelerator. Critical DSP coefficients and thresholds are stored using Triple Modular Redundancy. Majority voting masks any single upset, while a periodic scrubber repairs corrupted copies automatically, allowing the system to tolerate transient radiation-induced faults without interrupting operation.

---

# Module 5 : Axis Sequencer

## Purpose

Acts as the controller between the communication subsystem and the DSP engine.

It retrieves vibration samples from the SPI-APB interface, extracts the required axis (X, Y or Z), and sequentially feeds samples into the Goertzel Core.

---

## Key Features

- Poll-based sample acquisition
- Automatic X→Y→Z sequencing
- TMR protected FSM
- TMR protected axis index
- Periodic register scrubbing
- Handshake interface to Goertzel Core

---

## Functional Flow

SPI-APB Interface
        ↓
Poll STATUS Register
        ↓
If Sample Available
        ↓
Read SAMPLE0
        ↓
Read SAMPLE1
        ↓
Reconstruct 48-bit XYZ Sample
        ↓
Extract Current Axis
        ↓
Feed Goertzel Core
        ↓
Wait for Block Complete
        ↓
Advance X → Y → Z

---

## Design Decisions

- Polling architecture decouples communication from DSP.
- Axis processed sequentially to reuse a single Goertzel engine.
- FSM protected using Triple Modular Redundancy.
- Axis index protected using Triple Modular Redundancy.
- Periodic scrubbing repairs SEU-induced bit flips.
- Majority voting prevents FSM corruption.

---

## Area Optimization

Instead of implementing three parallel Goertzel engines (one for each axis), the design reuses a single DSP engine by processing X, Y and Z sequentially.

This significantly reduces silicon area and power.

---

## Reliability Features

- Triplicated FSM state registers
- Majority voted next-state logic
- Triplicated axis register
- Periodic scrubbing

---

## What to Tell the Judges

The Axis Sequencer schedules vibration samples into the DSP engine. It polls the communication interface for new samples, reconstructs the complete 48-bit XYZ data, selects one axis at a time, and sequentially feeds a shared Goertzel accelerator. By time-multiplexing the DSP engine instead of replicating hardware, the design achieves significant area savings while maintaining reliability through TMR-protected control logic.

---

# Module 6 : Goertzel Core (DSP Engine)

## Purpose

Implements a hardware-optimized Goertzel algorithm to detect vibration energy at three programmable frequency bins.

Instead of computing a full FFT, the design computes only the frequencies of interest, making it significantly smaller and lower power.

---

## Why Goertzel?

Our application only requires monitoring a few known fault frequencies rather than the complete frequency spectrum.

Compared to FFT:

- Lower hardware complexity
- Lower power
- Smaller silicon area
- Ideal for embedded edge processing

---

## Mathematical Equation

For each frequency bin:

v[n] = x[n] + C·v[n−1] − v[n−2]

where:

- x[n] : Input vibration sample
- C : Goertzel coefficient
- v[n−1], v[n−2] : Previous states

---

## Architecture

Single shared multiplier

↓

Time-multiplexed across

- Bin 0
- Bin 1
- Bin 2

↓

State memories

↓

Magnitude Computation

---

## Key Features

- Three programmable frequency bins
- Shared multiplier architecture
- Time-multiplexed processing
- Fused arithmetic datapath
- Fixed-point Q8.15 arithmetic
- Saturating arithmetic
- TMR-protected control FSM
- Operand isolation for power reduction

---

## Design Decisions

- Shared multiplier instead of three multipliers reduces area significantly.
- One Goertzel engine processes three bins sequentially.
- Fused recurrence removes intermediate accumulator registers.
- Input sample registered once to decouple communication timing.
- Saturation logic prevents arithmetic overflow.
- Multiplier remains disabled during idle cycles to reduce dynamic power.
- Control FSM protected using Triple Modular Redundancy.

---

## Area Optimizations

Instead of:

3 Multipliers

3 Independent DSP Pipelines

the design uses:

1 Shared Multiplier

Time Multiplexing

This significantly reduces silicon area while still meeting the throughput requirement.

---

## Power Optimizations

Approximately 375 clock cycles are available per sensor sample.

Only six cycles are required for Goertzel computation.

The multiplier remains idle for the remaining cycles through operand isolation, minimizing dynamic power.

---

## Reliability Features

- TMR protected FSM
- Majority voted state transitions
- SEU-safe recovery
- Safe block reset
- Saturating arithmetic

---

## What to Tell the Judges

The Goertzel Core is the computational engine of the accelerator. It implements three programmable spectral filters using a single shared multiplier that is time-multiplexed across all frequency bins. By replacing an FFT with the Goertzel algorithm and aggressively sharing hardware resources, the design achieves substantial area and power savings while still providing accurate vibration frequency analysis suitable for edge processing in space applications.

---

# Module 7 : Magnitude Compute

## Purpose

Computes the final Goertzel magnitude for each programmable frequency bin using the final recursive state variables.

It also manages the shared hardware multiplier between the Goertzel Core and the Magnitude Engine.

---

## Why is this module required?

The Goertzel Core only computes the recursive filter states:

- v[n-1]
- v[n-2]

These states are not directly useful for fault detection.

The Magnitude Compute module converts these states into the actual spectral energy using the Goertzel magnitude equation.

---

## Mathematical Equation

For each frequency bin,

Magnitude² = v1² + v2² − C × v1 × v2

where

- v1 = Final Goertzel state
- v2 = Previous Goertzel state
- C = Goertzel coefficient

The resulting value represents the vibration energy at that frequency.

---

## Functional Flow

Goertzel Core
        │
        ▼
Final States (v1,v2)
        │
        ▼
Snapshot on Block Boundary
        │
        ▼
Shared Multiplier
        │
        ▼
Magnitude Computation
        │
        ▼
Magnitude Output
(Bin Index + Axis Index)

---

## Key Features

- Computes magnitude for three programmable frequency bins
- Shares multiplier with Goertzel Core
- Snapshots Goertzel state before reset
- Outputs frequency bin index
- Outputs physical axis index
- TMR protected magnitude FSM
- Fixed-point Q8.15 arithmetic
- Saturating arithmetic

---

## Design Decisions

### Snapshot Architecture

The Goertzel Core clears its internal states at every block boundary.

Before this happens, the Magnitude Compute module captures:

- v1
- v2
- Goertzel coefficient
- Current axis

This allows magnitude computation to continue independently while the Goertzel Core immediately starts processing the next block.

---

### Shared Multiplier

Instead of implementing another hardware multiplier,

the Magnitude Engine shares the multiplier already used by the Goertzel Core.

Benefits:

- Lower silicon area
- Lower power
- Reduced hardware duplication

---

### Time-Multiplexed Magnitude Engine

One FSM computes the magnitudes for:

- Bin 0
- Bin 1
- Bin 2

using the same arithmetic hardware.

No dedicated hardware exists per frequency bin.

---

### Axis Snapshot

The axis information is stored together with the Goertzel states.

This guarantees that every magnitude result is correctly associated with:

- X
- Y
- Z

even if the Axis Sequencer changes to another axis during computation.

---

## Area Optimizations

- Single shared multiplier
- One magnitude FSM reused across all bins
- Snapshot registers avoid duplicating Goertzel state memory
- Shared arithmetic datapath

---

## Power Optimizations

- Multiplier reused rather than duplicated
- Magnitude engine only becomes active at block boundaries
- Arithmetic hardware remains idle during normal sample processing

---

## Reliability Features

- Triplicated FSM
- Majority voted state transitions
- Snapshot isolation between computation stages
- Saturating arithmetic prevents overflow corruption

---

## What to Tell the Judges

The Magnitude Compute module converts the Goertzel filter states into usable spectral energy values. Instead of duplicating arithmetic hardware, it shares the multiplier with the Goertzel Core and performs magnitude computation only after an entire block has been processed. By snapshotting the Goertzel states before they are cleared, the design allows the DSP pipeline to continue processing while the previous block's magnitudes are calculated, improving hardware utilization without increasing latency.

---

# Module 8 : Fault Flagger

## Purpose

Acts as the final decision engine of the accelerator.

It performs three major functions:

- Maintains the 512-sample processing window
- Generates block boundaries
- Detects vibration anomalies by comparing computed magnitudes against a programmable threshold

---

## Functional Flow

Goertzel Core
        │
        ▼
Magnitude Compute
        │
Magnitude + Bin + Axis
        │
        ▼
Threshold Comparator
        │
        ▼
Fault Detection
        │
        ▼
Sticky Fault Register

---

## Key Features

- 512-sample block counter
- Programmable threshold comparison
- Sticky fault indication
- Stores fault magnitude
- Stores frequency bin
- Stores physical sensor axis
- TMR protected block counter

---

## Design Decisions

### Block-Based Processing

Instead of computing magnitudes after every incoming sample, the design processes a complete block of 512 samples before evaluating the spectrum.

Benefits:

- Improved frequency resolution
- Lower computation overhead
- Natural synchronization with Goertzel processing

---

### Immediate Threshold Detection

Every computed magnitude is immediately compared against a programmable threshold.

If

Magnitude > Threshold

the fault is detected immediately.

No additional averaging or debounce logic is required.

---

### Sticky Fault Register

Once a fault is detected,

the fault flag remains asserted until software explicitly clears it.

Benefits:

- Prevents transient faults from being missed.
- Allows software to read diagnostic information later.
- Simplifies system monitoring.

---

### Fault Attribution

When a fault occurs,

the following information is stored:

- Fault Magnitude
- Frequency Bin
- Physical Axis

This allows software to identify

- Which frequency failed
- Which sensor axis detected it
- How severe the vibration was

---

## Reliability Features

- Triple Modular Redundancy block counter
- Majority voted counter updates
- SEU tolerant sample counting
- Sticky fault storage

---

## Area Optimizations

- One comparator reused for all frequency bins
- One block counter for the complete accelerator
- No unnecessary debounce or filtering logic

---

## Power Optimizations

- Comparator only active when a valid magnitude is available.
- Decision logic remains idle during normal sample acquisition.

---

## What to Tell the Judges

The Fault Flagger is the final decision stage of our accelerator. It defines the 512-sample processing window, generates block boundaries for the DSP pipeline, and compares every computed spectral magnitude against a programmable threshold. Once a fault is detected, the module stores the fault magnitude together with its corresponding frequency bin and sensor axis, allowing the processor to precisely identify the source of the vibration anomaly while ensuring no fault event is lost through its sticky fault mechanism.

---

## Complete Accelerator Pipeline

IIS3DWB Sensor
        │
        ▼
SPI Master
        │
        ▼
SPI-APB Interface
        │
        ▼
Axis Sequencer
        │
        ▼
Goertzel Core
        │
        ▼
Magnitude Compute
        │
        ▼
Fault Flagger
        │
        ▼
TMR Register Bank
        │
        ▼
RISC-V Processor
