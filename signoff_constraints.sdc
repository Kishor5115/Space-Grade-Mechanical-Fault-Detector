
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
