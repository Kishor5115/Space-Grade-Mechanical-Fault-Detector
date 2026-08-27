
#=============================================================================
# signoff_constraints.sdc -- Space-Grade Mechanical Fault Detector (top)
# SIGNOFF_SDC_FILE: used by OpenROAD.STAPostPNR only -- the real spec.
#
# System clock : 16 MHz -> 62.5 ns period (hard requirement, do not loosen)
# SPI bit clock: 16/8 = 2 MHz (c_sclk), <= IIS3DWB 10 MHz SPI max.
#=============================================================================

set clk_period_ns 62.5
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
# pnr_constraints.sdc. See constraints.sdc for the full rationale.
#
# This is the SIGNOFF view: these are the limits the final DRV verdict is
# measured against. Note they can only TIGHTEN the check -- OpenSTA takes
# min(SDC limit, liberty pin limit) -- so adding set_max_transition 3.0 here
# does NOT relax the 2.6 ns liberty limit at the ff_n40C_5v50 corner where the
# violations actually appear. Fixing DRVs by loosening the signoff limit would
# be meaningless; the point of this block is to make PnR aware of the limits
# so it repairs them, and to tighten the typical corner from 4.0 ns to 3.0 ns.
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
