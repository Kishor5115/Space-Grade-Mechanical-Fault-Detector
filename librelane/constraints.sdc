
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
# 62.5
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

# Command-SPI config bus is sampled asynchronously and 2-FF synchronized into
# the clk domain (single-clock, oversampled receiver -- cmd_spi_slave.v), so
# cut it from timing like the other async inputs.
set_false_path -from [get_ports cmd_sclk]
set_false_path -from [get_ports cmd_csn]
set_false_path -from [get_ports cmd_mosi]

# Async reset: asynchronous assert, release is reset-synchronized in practice.
set_false_path -from [get_ports sys_rst_n]

# Single sticky status output; no synchronous receiver timing to close here.
set_false_path -to [get_ports fault_flag_out]

#-----------------------------------------------------------------------------
# Budget the remaining synchronous I/O at a conservative fraction of the
# period. clk itself is excluded from input-delay budgeting.
#-----------------------------------------------------------------------------
set io_delay [expr {$clk_period_ns * 0.30}]
set clk_indx [lsearch [all_inputs] [get_ports clk]]
set non_clk_inputs [lreplace [all_inputs] $clk_indx $clk_indx ""]
set_input_delay  -clock clk $io_delay $non_clk_inputs
set_output_delay -clock clk $io_delay [all_outputs]

# --- Suppress expected/harmless OpenROAD warnings ---
# STA-1140: duplicate standard cell library read
if {[info commands suppress_message] != ""} {
    suppress_message STA 1140
    # RSZ-0020: 2 floating nets (VDD/VSS)
    suppress_message RSZ 0020
}

#=============================================================================
# Design-rule (DRV) constraints -- max fanout / transition / capacitance
#-----------------------------------------------------------------------------
# WHY THIS BLOCK EXISTS (do not delete):
#   Setting FALLBACK_SDC / PNR_SDC_FILE / SIGNOFF_SDC_FILE replaces LibreLane's
#   built-in scripts/base.sdc *entirely*. base.sdc is what normally emits
#     set_max_fanout      $::env(MAX_FANOUT_CONSTRAINT)
#     set_max_transition  $::env(MAX_TRANSITION_CONSTRAINT)
#     set_max_capacitance $::env(MAX_CAPACITANCE_CONSTRAINT)
#   so without re-declaring them here, those config.yaml values are silently
#   DEAD and the only limits in play are the liberty's own per-pin limits.
#
#   Consequence observed before this fix: sys_rst_n fans out to 1,767 flop RN
#   pins through only 8 branch buffers (125-280 loads each). Nothing bounded
#   fanout, so resizer/repair_design only split the net far enough to satisfy
#   max_capacitance (the inserted buffers are literally named max_cap19..25),
#   leaving transition at 2.97-3.55 ns against a 2.6 ns limit at the fast
#   corner -> 260 max-slew + 8 max-cap violations at signoff.
#
#   These are read from the environment so config.yaml stays the single source
#   of truth; the guards keep the file usable standalone (e.g. manual OpenSTA).
#
#   NOTE: these can only ever TIGHTEN the check. OpenSTA applies the *minimum*
#   of the SDC limit and the liberty pin limit, so e.g. set_max_transition 3.0
#   cannot loosen a cell whose library limit is already 2.6 ns.
#
#   Liberty max_transition is corner-dependent in gf180mcu:
#     ff_n40C_5v50 -> 2.6 ns   (tightest; this is where violations show up)
#     tt_025C_5v00 -> 4.0 ns
#=============================================================================
if {[info exists ::env(MAX_FANOUT_CONSTRAINT)]} {
    set_max_fanout $::env(MAX_FANOUT_CONSTRAINT) [current_design]
} else {
    set_max_fanout 20 [current_design]
}

if {[info exists ::env(MAX_TRANSITION_CONSTRAINT)]} {
    set_max_transition $::env(MAX_TRANSITION_CONSTRAINT) [current_design]
} else {
    set_max_transition 3.0 [current_design]
}

if {[info exists ::env(MAX_CAPACITANCE_CONSTRAINT)]} {
    set_max_capacitance $::env(MAX_CAPACITANCE_CONSTRAINT) [current_design]
} else {
    set_max_capacitance 0.2 [current_design]
}