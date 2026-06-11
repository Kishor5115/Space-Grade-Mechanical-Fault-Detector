# ============================================================================
# vibration_top.sdc — Timing constraints (pure SDC / OpenSTA compatible)
# Project : Space-Grade Mechanical Fault Detector
# Target  : GF180MCU, single clock domain @ 20 MHz (50 ns period)
# ----------------------------------------------------------------------------
# Rules: ONLY standard SDC 1.9 commands supported by OpenSTA/OpenROAD.
#   No PrimeTime extensions (remove_from_collection, foreach_in_collection).
# ============================================================================

# ---- Clock ------------------------------------------------------------------
create_clock -name clk -period 50.0 [get_ports clk]
set_clock_uncertainty 0.50 [get_clocks clk]
set_clock_transition  0.15 [get_clocks clk]

# ---- I/O timing budget (20% of period = 10 ns) ------------------------------
# Applying set_input_delay to all_inputs (including clk) is safe: OpenSTA
# treats the clock port as a clock source and the annotation is ignored for
# timing analysis. The rst_n false-path below exempts the reset from setup/hold.
set_input_delay  10.0 -clock clk [all_inputs]
set_output_delay 10.0 -clock clk [all_outputs]

# ---- Design rule constraints ------------------------------------------------
set_max_fanout     10  [current_design]
set_max_transition 1.5 [current_design]

# ---- Asynchronous reset false path ------------------------------------------
set_false_path -from [get_ports rst_n]
