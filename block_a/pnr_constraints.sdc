# B22_A wrapper: the e1 constraints without the c_sclk generated clock. As a clock
# net, c_sclk_OUT is skipped by repair_design and its long wire to the edge pin
# goes unbuffered. Nothing in the e1 constraints refers to c_sclk.
source [file join [file dirname [info script]] ../librelane/pnr_constraints.sdc]
delete_generated_clock [get_clocks c_sclk]
