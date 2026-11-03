# Signoff Summary: `top` Macro, Run `PADCTRL_800_r10`

SSCS Chipathon 2026, Track B, Team B22 Space Jam. Results dated 2026-11-03.

| Item | Value |
|---|---|
| Layout | `ip/top/top.gds`, 800 µm x 800 µm |
| GDS SHA-256 | `9488f3fe0116baa5f6dea522ef1cf2fcbb49adbe96716fcb06585a8da9bd2a47` |
| Settings | `librelane/config.yaml`, including the 300 µm maximum wire length |
| Cells and flops | 23,309 standard cells, 1,792 flops, 66.6% utilization |
| Raw logs | `documents/signoff_r10/` |

**Open item: formal equivalence is partial.** EQY proved 60 of 86 partitions. See section 3.

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
| Setup, 9 corners at 62.5 ns | Worst +5.947 ns at `max_ss_125C_4v50`, total negative slack 0 |
| Hold, 9 corners | Worst +0.142 ns at `min_ff_n40C_5v50` |
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

These three bugs were found while building the golden model. All earlier layouts contain them.

| Bug | File | Effect before the fix |
|---|---|---|
| Sample bytes swapped | `rtl/axis_sequencer.v` | The DSP received `0x2211` for a sensor value of `0x1122` |
| Products shifted by 22 bits, not 15 | `rtl/magnitude_compute.v` | Every product was 128x too small, so the Goertzel filter did not resonate |
| Read command depended on DRDY phase | `rtl/spi_master.v` | At some phases the command went out as `0x28`, not `0xA8` |

Magnitude thresholds changed scale as a result. An on-bin tone of amplitude A now gives about
`(256 * A)^2 * 32768`. Thresholds from before these fixes are not valid.

**Remaining range limit.** The 24-bit filter state saturates on strong tones, and readings stop following
amplitude. The lowest saturated reading in `tb/golden_values.json` is 12,426,463, so keep thresholds well below it.

## 3. Formal equivalence detail

The earlier `verification/top.eqy` could not give a valid result, because it loaded standard cells as empty black
boxes and named a solver this image does not have. Both are now fixed.

| Partitions | Count | Meaning |
|---|---|---|
| Proved equivalent | 60 | Formally proved |
| Inconclusive | 25 | No mismatch within 10 steps, but the induction proof did not close |
| Counterexample | 1 | `spi_apb_inst.fwd_req_valid` |
| **Total** | **86** | |

**The counterexample.** EQY found a case where `tmr_forward_en` falls during operation and the netlist holds
`fwd_req_valid` high while the RTL clears it. EQY analyses each partition with its inputs unconstrained, so this may
come from a state the real chip cannot reach. It has not been explained.

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

Core only, with no pads included. Data activity barely changes the result, because the clock tree and flops take
about 98% of the power and there is no clock gating.

| Corner | Tool estimate | Simulated, full-scale random data | Current at estimate |
|---|---|---|---|
| `max_ff_n40C_5v50`, 5.5 V | **46.42 mW** | 46.26 mW | 8.4 mA |
| `nom_tt_025C_5v00`, 5.0 V | 36.76 mW | 36.63 mW | 7.4 mA |
| `max_ss_125C_4v50`, 4.5 V | 30.20 mW | 30.09 mW | 6.7 mA |

Leakage is under 6 µW at `ff` and about 31 µW at `ss`. As a hand estimate, `c_sclk` driving an assumed 20 pF load
adds about 0.9 mW at 5.5 V. The pads' own internal power is not modeled. None of these figures are measured.

## 5. IR drop

Static analysis at `max_ff_n40C_5v50` and 46.4 mW. The macro has 11 VDD and 11 VSS vertical Metal4 straps, so the
result depends on where the chip feeds them. The chip's real feed points are not modeled.

| Assumed feed | Worst VDD drop | Worst VSS drop |
|---|---|---|
| Flow default, ideal | 0.12 mV | 0.13 mV |
| All straps, both ends | 1.6 mV | 1.6 mV |
| All straps, one end | 5.6 mV | 5.6 mV |
| One strap, one point (very pessimistic) | 12.4 mV | 11.7 mV |

Even the very pessimistic case totals about 24 mV, or 0.44% of 5.5 V.

**Not covered:** dynamic IR drop, pad and bond-wire resistance, and the chip-level power grid. Static drop scales
with current. As a rough guide, if current peaks at 300 mA at clock edges with no help from decap, the one-end case
scales to about 200 mV per rail. That peak is an estimate and no tool has computed it.

## 6. Still open

1. **Formal equivalence** is partial (section 3).
2. **The chip top has not been rebuilt** with this macro. `gds/chip_top.gds` still holds the old macro and its bugs, and
   the `c_csn` pull-up in `padring/src/chip_core.sv` only takes effect after a rebuild. The rebuild needs the
   wafer-space PDK fork, which this container does not have.
3. **KLayout density checks:** the run reports its main deck. Whether density is included has not been confirmed.
4. **`def_ready` flags** in `info.yaml` are still `false`, pending confirmation of what they require.
