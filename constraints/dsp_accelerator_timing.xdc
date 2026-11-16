# Complete accelerator interface contract for MODULE-LEVEL implementation.
# These are declared integration budgets, not measured board/processor delays.
# All AXI4-Lite, AXI4-Stream and reset signals are synchronous to this clock.
# The parent must meet these budgets; revalidate them when integrating elsewhere.
create_clock -name clk -period 10.000 -waveform {0.000 5.000} [get_ports clk]

# The virtual clock models external launch/capture edges with zero phase offset
# from clk. It also constrains combinational boundary paths (e.g. reset -> ready).
# It is a timing reference only and creates no second hardware clock domain.
create_clock -name interface_clk -period 10.000 -waveform {0.000 5.000}

# Explicit user margin for every internal/interface relationship. Device jitter
# is still included by Vivado; these values are not a measured jitter estimate.
set_clock_uncertainty -setup 0.100 -from [get_clocks {clk interface_clk}] -to [get_clocks {clk interface_clk}]
set_clock_uncertainty -hold 0.050 -from [get_clocks {clk interface_clk}] -to [get_clocks {clk interface_clk}]

set module_inputs [get_ports -filter {DIRECTION == IN && NAME != clk}]
set module_outputs [get_ports -filter {DIRECTION == OUT}]

# Upstream logic plus interconnect delivers data 0.5 .. 2.0 ns after its edge.
# Include resetn: it is a synchronous reset and must meet setup/hold normally.
set_input_delay -clock [get_clocks interface_clk] -min 0.500 $module_inputs
set_input_delay -clock [get_clocks interface_clk] -max 2.000 $module_inputs

# Reserve 2.0 ns for downstream setup/logic and require 0.5 ns external hold.
# Output MIN is NEGATIVE receiver hold time, not another setup allowance.
set_output_delay -clock [get_clocks interface_clk] -min -0.500 $module_outputs
set_output_delay -clock [get_clocks interface_clk] -max 2.000 $module_outputs

# No false paths, multicycle paths, reset exclusions or timing-disable commands.
# References: AMD UG903 (I/O delay constraints) and UG949 (output delay signs).
