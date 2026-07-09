
# Entity: top 
- **File**: top.v

## Diagram
![Diagram](top.svg "Diagram")
## Ports

| Port name      | Direction | Type | Description |
| -------------- | --------- | ---- | ----------- |
| clk            | input     |      | System clock |
| sys_rst_n      | input     |      | Active-low async reset |
| c_miso         | input     |      | IIS3DWB SPI MISO |
| c_csn          | output    |      | IIS3DWB SPI chip-select (active low) |
| c_sclk         | output    |      | IIS3DWB SPI bit clock (mode 3) |
| c_mosi         | output    |      | IIS3DWB SPI MOSI |
| sensor_drdy    | input     |      | IIS3DWB DRDY interrupt (async) |
| tmr_forward_en | input     |      | 0=local-read only (Option A), 1=also forward samples to tmr_reg_bank over APB (Option B) |
| fault_flag_out | output    |      | Sticky fault/alarm output to host/RISC core |

## Signals

| Name                | Type        | Description |
| ------------------- | ----------- | ----------- |
| seq_req_valid/write/addr/wdata/done, seq_resp_rdata | wire | axis_sequencer <-> spi_apb_interface local register poll port |
| apb_pwrite/psel/penable/p_addr/pwdata/prdata/pready  | wire | Internal APB bus, spi_apb_interface (master) -> tmr_reg_bank (slave) |
| cfg_c0/cfg_c1/cfg_c2 | wire [23:0] | Q8.15 Goertzel coefficients, bin 0/1/2 (triplicated in tmr_reg_bank) |
| cfg_threshold        | wire [31:0] | Fault magnitude threshold (triplicated in tmr_reg_bank) |
| cfg_start/cfg_stop/cfg_fault_clear/run_enable | wire | Control pulses/latch decoded from tmr_reg_bank CTRL register |
| fault_flag           | wire        | Combinational fault_flagger output, registered sticky in tmr_reg_bank read path |
| fault_mag_latched    | wire [31:0] | Magnitude that tripped the last fault |
| fault_bin_latched    | wire [1:0]  | Frequency bin (0-2) that tripped the last fault |
| fault_axis_latched   | wire [1:0]  | Sensor axis (0=X/1=Y/2=Z) that tripped the last fault |
| core_data_ready      | wire        | axis_sequencer -> goertzel_core: new per-axis sample presented |
| core_x_n             | wire [15:0] | axis_sequencer -> goertzel_core: Q1.15 sample for the active axis |
| block_clear          | wire        | fault_flagger -> goertzel_core/magnitude_compute: 512-sample block boundary pulse |
| current_axis         | wire [1:0]  | axis_sequencer -> magnitude_compute: which axis (X/Y/Z) is active this block |
| mult_req/mult_a/mult_b/mult_q | wire | Shared multiplier request bus, goertzel_core <-> magnitude_compute |
| v1_0/v2_0/v1_1/v2_1/v1_2/v2_2 | wire [23:0] | Per-bin Goertzel state, goertzel_core -> magnitude_compute |
| sample_done          | wire        | goertzel_core -> fault_flagger: 1 pulse per completed sample (all 3 bins) |
| mag_out/mag_bin_idx/mag_axis_idx/mag_out_valid | wire | magnitude_compute -> fault_flagger: per-bin, per-axis magnitude result stream |

## Instantiations

- spi_apb_inst: spi_apb_interface (owns spi_master_inst: spi_master internally)
- tmr_inst: tmr_reg_bank
- axseq_inst: axis_sequencer
- goertzel_inst: goertzel_core
- mag_inst: magnitude_compute
- ff_inst: fault_flagger
