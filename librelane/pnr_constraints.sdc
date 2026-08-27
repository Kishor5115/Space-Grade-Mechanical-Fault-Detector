
#=============================================================================
# pnr_constraints.sdc -- Space-Grade Mechanical Fault Detector (top)
# PNR_SDC_FILE: used by placement / CTS / routing steps only.
#
# Deliberately over-constrained vs. the real 16 MHz spec (see
# signoff_constraints.sdc for the real number) so the resizer/CTS optimize
# for extra margin during PnR. 55 ns is a starting point (~13.6% tighter
# than the real 62.5 ns) -- tune empirically, not a derived/guaranteed value.
#=============================================================================


set clk_period_ns 55.0
create_clock -name clk -period $clk_period_ns [get_ports clk]

create_generated_clock -name c_sclk -source [get_ports clk] -divide_by 8 \
    [get_ports c_sclk]

set_clock_uncertainty 0.25 [get_clocks clk]
set_clock_transition  0.15 [get_clocks clk]

set_false_path -from [get_ports sensor_drdy]
set_false_path -from [get_ports c_miso]
set_false_path -from [get_ports tmr_forward_en]
set_false_path -from [get_ports cmd_sclk]
set_false_path -from [get_ports cmd_csn]
set_false_path -from [get_ports cmd_mosi]
set_false_path -from [get_ports sys_rst_n]
set_false_path -to [get_ports fault_flag_out]

set io_delay [expr {$clk_period_ns * 0.30}]
set clk_indx [lsearch [all_inputs] [get_ports clk]]
set non_clk_inputs [lreplace [all_inputs] $clk_indx $clk_indx ""]
set_input_delay  -clock clk $io_delay $non_clk_inputs
set_output_delay -clock clk $io_delay [all_outputs]

if {[info commands suppress_message] != ""} {
    suppress_message STA 1140
    suppress_message RSZ 0020
}

#=============================================================================
# Design-rule (DRV) constraints -- KEEP IN SYNC with constraints.sdc and
# signoff_constraints.sdc. See constraints.sdc for the full rationale.
#
# Short version: a custom *_SDC_FILE replaces LibreLane's base.sdc, which is
# what normally emits these three. Without them, MAX_FANOUT_CONSTRAINT /
# MAX_TRANSITION_CONSTRAINT / MAX_CAPACITANCE_CONSTRAINT in config.yaml are
# dead, and nothing bounds the fanout of high-fanout nets like sys_rst_n
# (1,767 sinks). This is the PnR view, so these constraints are what actually
# drive resizer/repair_design buffer insertion during placement and routing.
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
