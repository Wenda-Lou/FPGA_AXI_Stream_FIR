# OOC PHYSICAL CONTEXT, read after dsp_accelerator_timing.xdc.
# The parent is assumed to supply clk from this legal Artix-7 global-buffer site.
# This is a declared placement context, not a package pin or physical-board clock.
set_property HD.CLK_SRC BUFGCTRL_X0Y0 [get_ports clk]

# OOC interface nets are not fully routed by default. Give every non-clock port
# a partition-pin range so the router also implements boundary nets. Use the
# a verified rectangular slice region rather than inventing board package pins.
# This constrains boundary-pin placement, not all module cells. A real parent
# must revalidate this context and may choose a different interface region.
# Endpoints queried from xc7a35tcpg236-1; control flow belongs in the Tcl runner,
# not in XDC (Vivado accepts only a restricted Tcl command set in XDC files).
set_property HD.PARTPIN_RANGE {SLICE_X0Y0:SLICE_X65Y99} [get_ports -filter {NAME != clk}]
# Context syntax follows AMD UG905, Context Constraints. This file is OOC-only.
