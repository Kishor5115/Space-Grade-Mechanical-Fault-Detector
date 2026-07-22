# constraints.sdc
# CLOCK_PORT / CLOCK_PERIOD are pulled from the LibreLane config env at runtime.

create_clock -name core_clock -period $::env(CLOCK_PERIOD) [get_ports $::env(CLOCK_PORT)]
set_clock_uncertainty 0.25 [get_clocks core_clock]
set_clock_transition 0.15 [get_clocks core_clock]

# I/O delay budget — tighten once real pad/board timing is known
set_input_delay -clock core_clock -max [expr $::env(CLOCK_PERIOD) * 0.3] [all_inputs]
set_output_delay -clock core_clock -max [expr $::env(CLOCK_PERIOD) * 0.3] [all_outputs]

# Async reset (if top.v has one) should be excluded from setup/hold analysis:
# set_false_path -from [get_ports <reset_port>]
