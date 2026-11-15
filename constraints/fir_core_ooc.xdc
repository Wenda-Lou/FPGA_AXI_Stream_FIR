# Standalone internal-clock target; external I/O delays belong to integration.
# A 10 ns period requests 100 MHz timing analysis on rising edges of clk.
# create_clock describes timing to Vivado; it does not generate a physical clock.
# No input/output delays are specified here, so this isolated-block check covers
# constrained internal paths. Add system/board interface constraints at integration
# and verify timing again after placement and routing.
create_clock -name clk -period 10.000 [get_ports clk]
