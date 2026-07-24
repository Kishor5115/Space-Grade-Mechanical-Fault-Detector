#=============================================================================
# constraints.sdc -- Space-Grade Mechanical Fault Detector (top)
#-----------------------------------------------------------------------------
# Single synchronous clock domain. One master clock drives every flip-flop in
# the design (spi_master, apb, axis_sequencer, goertzel_core, magnitude_compute,
# fault_flagger, tmr_reg_bank, cmd_spi_slave). The SPI bit clock on c_sclk is
# a /8 division of this clock (rtl/clk_divider.v) and is NEVER used to clock
# internal logic -- it is only emitted to the sensor and re-timed to clk via
# clk-domain edge detectors -- so there are no internal generated-clock domains
# and no inter-clock CDC exceptions to manage.
#
# System clock : 16 MHz  -> 62.5 ns period
# SPI bit clock: 16/8 = 2 MHz (c_sclk), <= IIS3DWB 10 MHz SPI max.
#=============================================================================

set clk_period_ns 62.5
create_clock -name clk -period $clk_period_ns [get_ports clk]

# --- SPI bit clock: clk/8 emitted on c_sclk (documentation/output timing) ---
# Declared as a generated clock so signoff STA understands the /8 ratio for
# the c_sclk / c_mosi output path toward the sensor. No internal register is
# clocked by it.
create_generated_clock -name c_sclk -source [get_ports clk] -divide_by 8 \
    [get_ports c_sclk]

# --- clock uncertainty / transition (conservative for a 180 nm node) ---
set_clock_uncertainty 0.25 [get_clocks clk]
set_clock_transition  0.15 [get_clocks clk]

#-----------------------------------------------------------------------------
# Asynchronous inputs -- synchronized on-chip by the 2-FF ff_2_sync macro
# (sensor_drdy, c_miso) or static config straps (tmr_forward_en). Cut them
# from timing so STA does not attempt to close a path from an unrelated /
# non-existent launch clock. Metastability is handled structurally by the
# synchronizer, not by timing.
#-----------------------------------------------------------------------------
set_false_path -from [get_ports sensor_drdy]
set_false_path -from [get_ports c_miso]
set_false_path -from [get_ports tmr_forward_en]

# Async reset: asynchronous assert, release is reset-synchronized in practice.
set_false_path -from [get_ports sys_rst_n]

# Single sticky status output; no synchronous receiver timing to close here.
set_false_path -to [get_ports fault_flag_out]

#-----------------------------------------------------------------------------
# Budget the remaining synchronous I/O at a conservative fraction of the
# period. clk itself is excluded from input-delay budgeting.
#-----------------------------------------------------------------------------
set io_delay [expr {$clk_period_ns * 0.30}]
set data_inputs  [remove_from_collection [all_inputs] [get_ports clk]]
set_input_delay  -clock clk $io_delay $data_inputs
set_output_delay -clock clk $io_delay [all_outputs]
