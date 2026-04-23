# Standalone timing constraints for pcpi_ml_activations top module.
# Use when implementing this module by itself in Vivado.

# Primary clock constraint for standalone closure (50 MHz, 20 ns period).
# This is a practical default for out-of-context implementation of this module.
# Tighten this (e.g. 10.000 ns for 100 MHz) only if your timing report shows positive slack.
create_clock -name pcpi_clk -period 20.000 [get_ports clk]

# resetn is treated as asynchronous control, not data-timed to pcpi_clk.
set_false_path -from [get_ports resetn]
