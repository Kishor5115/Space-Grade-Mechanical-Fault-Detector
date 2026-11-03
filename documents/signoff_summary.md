# Signoff Summary: `top` Macro, Run `PADCTRL_800_e1`

SSCS Chipathon 2026, Track B, Team B22 Space Jam. Results dated 2026-11-03.

| Item | Value |
|---|---|
| Macro layout | `ip/top/top.gds`, 800 µm x 800 µm |
| Macro GDS SHA-256 | `98c1cf55f44048e0edd156327ebd40ace8f7d5240c08ffdb2180c8a317b4cc37` |
| Chip layout | `gds/chip_top.gds`, run `E1_CHIP` |
| Chip netlists | `verilog/gl/chip_top.nl.v`, and powered `verilog/gl/chip_top.pnl.v` |
| Chip GDS SHA-256 | `e7417d717950d28fffe23eafdc4fd407ec8132f8e8a3b52aca624bbc3812dadb` |
| Settings | `librelane/config.yaml`, including the 300 µm maximum wire length |
| Cells and flops | 23,298 standard cells, 1,742 flops, 65.4% utilization |
| Raw logs | `documents/signoff_e1/` |

**Open item: formal equivalence is partial.** EQY proved 60 of 86 partitions. See section 3.

**Do not use `power__total` from this run's `metrics.json`.** It reports 490 mW, which is a tool artifact. Real core
power is about 45 mW. See section 4.

## 1. Results

| Check | Result |
|---|---|
| Magic DRC, flow | 0 errors |
| KLayout DRC, main deck | Clean, 0 violations |
| Routing DRC, flow | 0 errors |
| Antenna, flow | 0 violating nets |
| GDS LVS, Magic and Netgen | `Circuits match uniquely` |
| Layout XOR, flow | 0 differences |
| PDK slew and cap limits, 9 corners | No violations |
| Setup, 9 corners at 62.5 ns | Worst +4.738 ns at `max_ss_125C_4v50`, total negative slack 0 |
| Hold, 9 corners | Worst +0.114 ns at `min_ff_n40C_5v50` |
| RTL simulation (cocotb) | 23 of 23 pass |
| Legacy Verilog tests (`testing/`) | SPI 71 checks, APB 8, top 15, Goertzel: all pass |
| Golden model (`make test-golden`) | 4 of 4 pass |
| Gate-level simulation | 8 of 8 pass |
| RTL against netlist, same random stimulus | 0 differences over 660,055 clocks |
| Formal equivalence (EQY) | **Partial: 60 of 86 proved** |

The flat netlist has no RTL block names, so at gate level the 2 ITAG tests use the pins. Each of the 9 axis and bin
pairs must separately trip the flag, and at the fastest DRDY pacing the magnitude must land exactly on its golden
value. These replace the internal pulse count and multiplier-request checks, which still run on RTL.

## 2. RTL changes in this layout

**Bugs fixed.** Layouts before `PADCTRL_800_r10` contain all three.

| Bug | File | Effect before the fix |
|---|---|---|
| Sample bytes swapped | `rtl/axis_sequencer.v` | The DSP received `0x2211` for a sensor value of `0x1122` |
| Products shifted by 22 bits, not 15 | `rtl/magnitude_compute.v` | Every product was 128x too small, so the Goertzel filter did not resonate |
| Read command depended on DRDY phase | `rtl/spi_master.v` | At some phases the command went out as `0x28`, not `0xA8` |

**Changes new in this layout**

| Change | File | Reason |
|---|---|---|
| Samples shifted right 4 bits before the filter | `rtl/goertzel_core.v` | Near 1 kHz the state saturated above about 0.14 of full scale, and a strong tone could read almost zero |
| Reset released through a voted 2-flop synchronizer | `rtl/top.v` | Reset release is now timed. Worst recovery slack is +41 ns. Voting stops one upset from resetting the chip. |
| `_IN` ports on the 4 output pads | `rtl/top.v`, `librelane/pins.cfg`, `padring/src/chip_core.sv` | The chipathon `bidirectional_24ma` pad type connects `<name>_IN` to Y. The ports are unused, and input enables stay low. |

**Magnitude scale.** An on-bin tone of amplitude A now gives about `(256 * A / 16)^2 * 32768`, which is 32,768 at
A = 1/16. Thresholds and golden values from any earlier layout are not valid.

**Effect of the shift.** A bit-exact model, which matched all 27 `r10` golden values, swept random phases from 1/8 to
full scale at 520.8 Hz, 1041.7 Hz, 5000.1 Hz and 10000.1 Hz. With a threshold of 16,384, 0 of 8,448 blocks fell below
it, and only 1 block was more than 1% from ideal. The same kind of sweep at 1041.7 Hz before the shift had 107 of 1,200
blocks below a threshold of 4,194,304, with readings as low as 3,508 in a separate sweep.

Very small signals lose precision: 1/128 of full scale reads about 508 against an ideal 512, and 1/1024 reads 6 to 7
against an ideal 8. Bins below about 500 Hz have less headroom and were not swept.

## 3. Formal equivalence detail

| Partitions | Count | Meaning |
|---|---|---|
| Proved equivalent | 60 | Formally proved |
| Inconclusive | 25 | No mismatch within 10 steps, but the induction proof did not close |
| Counterexample | 1 | `spi_apb_inst.fwd_req_valid` |
| **Total** | **86** | |

**The counterexample.** On `r10`, EQY found a case where `tmr_forward_en` falls during operation and the netlist holds
`fwd_req_valid` high while the RTL clears it. `e1` fails on the same partition, and its trace has not been examined
separately. EQY analyses each partition with its inputs unconstrained, so this may come from a state the real chip cannot
reach. It has not been explained.

**Evidence at the pins.** Seeded random stimulus ran through RTL and the gate netlist for 660,055 clocks, including
41 changes of `tmr_forward_en` during operation. `c_csn`, `c_sclk`, `c_mosi` and `fault_flag_out` matched on every
clock. This is simulation evidence and not a proof. `fault_flag_out` rose only once in this run, so alarm behaviour
had less coverage than SPI.

**Operating rule.** Change `tmr_forward_en` only while `sys_rst_n` is low.

The inconclusive partitions are:

`apb_arb_inst.m0_penable`, `m0_psel`, `m0_pwrite`, `m1_penable`, `m1_psel`, `m1_pwrite`, `s_pready`;
`axseq_inst.core_data_ready`, `req_valid`, `run_enable`; `c_csn_OUT`, `c_mosi_OUT`, `c_sclk_OUT`; `cfg_fault_clear`;
`cmd_apb_master.req_done`, `req_valid`; `ff_inst.block_boundary`, `mag_in_valid`, `sample_done`; `fault_flag_out_OUT`;
`spi_apb_inst.apb_inst.req_done`, `data_ready`, `fwd_done`, `sm_data_out_valid`, `spi_master_inst.boot_active`.

## 4. Power at 16 MHz

Core only, with no pads included. The clock tree and flops take about 98% of the power, and there is no clock gating.

| Corner | Estimate, reset quiet | Simulated, full-scale random data | Current at simulated |
|---|---|---|---|
| `max_ff_n40C_5v50`, 5.5 V | 44.17 mW | **45.01 mW** | 8.2 mA |
| `nom_tt_025C_5v00`, 5.0 V | 35.02 mW | 35.66 mW | 7.1 mA |
| `max_ss_125C_4v50`, 4.5 V | 28.76 mW | 29.30 mW | 6.5 mA |

**The 490 mW in `metrics.json` is not real.** Without simulation, the tool assumes a toggle rate for every net. The reset
net now comes from flops, so it is assumed to toggle like data, and that net reaches all 1,742 flops through a large
buffer tree. In reality it changes only at startup. Rerunning the default estimate at `max_ff_n40C_5v50` gives 428 mW, and
marking only the reset net as quiet gives 44.2 mW. The gap between the flow's 490 mW and this 428 mW has not been traced.

As a hand estimate, `c_sclk` driving an assumed 20 pF load adds about 0.9 mW at 5.5 V. The pads' own internal power is not
modeled. None of these figures are measured.

## 5. IR drop

Static analysis at `max_ff_n40C_5v50` and 44.2 mW. The macro has 11 VDD and 11 VSS vertical Metal4 straps, so the result
depends on where the chip feeds them. The chip's real feed points are not modeled.

| Assumed feed | Worst VDD drop | Worst VSS drop |
|---|---|---|
| Flow default, ideal | 0.17 mV | 0.07 mV |
| All straps, both ends | 1.55 mV | 1.53 mV |
| All straps, one end | 5.22 mV | 5.22 mV |
| One strap, one point (very pessimistic) | 11.7 mV | 11.3 mV |

Even the very pessimistic case totals about 23 mV, or 0.42% of 5.5 V.

**Not covered:** dynamic IR drop, pad and bond-wire resistance, and the chip-level power grid.

## 6. Chip top (`E1_CHIP`)

Built on the `slot_1x1` pad ring from the template in the official `sscs-chipathon-2026` repo, with the wafer-space PDK
fork at 1.8.0. The macro inside has the GDS hash at the top of this document.

| Check | Result |
|---|---|
| Magic DRC | 0 |
| Routing DRC | 0 |
| Netgen LVS | 0 unmatched pins, nets and devices |
| Layout XOR | 0 |
| Antenna | 0 |
| Critical disconnected pins | 0 |
| Setup / hold | +29.97 ns / +17.19 ns |
| `c_csn` pull-up | Present: pad `bidir[26]` has `PU` tied high |

- **Slew and cap:** the flow reports 3 and 97 against the design's own tighter limits. A liberty-limits check on 5 of the 9
  corners found 0 violations for standard cells. It did not check pad cell limits.
- **Timing covers the boundary only.** The macro is a black box at this level, so setup and hold above do not re-check
  its internal paths. Those are in section 1.
- **KLayout DRC was not run at chip level.** The template flow disables it, and Magic DRC is the DRC used here.
- **The flow's chip-level power and IR figures are not valid**, because the macro is a black box. Use sections 4 and 5.

## 7. Still open

1. **Formal equivalence** is partial, and the `tmr_forward_en` counterexample is unexplained (section 3).
2. **KLayout density checks:** the run reports its main deck. Whether density is included has not been confirmed.
3. **`def_ready` flags** in `info.yaml` are still `false`, pending confirmation of what they require.
