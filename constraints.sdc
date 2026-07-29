# constraints.sdc — Space-Grade-Mechanical-Fault-Detector, single-clock-domain macro.
# CLOCK_PORT / CLOCK_PERIOD come from the LibreLane config env at runtime — do not hardcode here.

create_clock -name core_clock -period $::env(CLOCK_PERIOD) [get_ports $::env(CLOCK_PORT)]
set_clock_uncertainty 0.25 [get_clocks core_clock]
set_clock_transition 0.15 [get_clocks core_clock]

# I/O delay budget (placeholder until real pad/board timing is known).
set_input_delay  -clock core_clock -max [expr $::env(CLOCK_PERIOD) * 0.3] [all_inputs]
set_output_delay -clock core_clock -max [expr $::env(CLOCK_PERIOD) * 0.3] [all_outputs]

# Async reset — REQUIRED before this SDC is correct.
# Confirm the actual reset port name from rtl/top.v (Step 1 of the notebook prints it),
# then uncomment and fill in below. Leaving this commented means STA will try to close
# setup/hold on the reset net as if it were a synchronous signal, which will falsely
# eat timing margin or mask real violations.
set_false_path -from [get_ports sys_rst_n]

# TMR note: this SDC does not need per-copy multicycle/false-path exceptions for the
# tmr_reg_bank / axis_sequencer / goertzel_core / magnitude_compute triplication —
# that's a synthesis-attribute concern ((* keep *) / dont_touch on the redundant
# register copies), not a timing-constraint one. Don't add exceptions here for it.
