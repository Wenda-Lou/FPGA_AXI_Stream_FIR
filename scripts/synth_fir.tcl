# Standalone synthesis of the default 8-tap, signed Q1.15 FIR.
# Paths are relative to this script, independent of the launch directory.
# This estimates the isolated core; it does not place/route an integrated system.
set project_root [file normalize [file join [file dirname [info script]] ..]]
set output_dir [file join $project_root build fir_synth]
file mkdir $output_dir
set_param general.maxThreads 2
# Wrap each path in a Tcl list so spaces in the workspace name remain one path.
read_verilog [list [file join $project_root fpga_streaming_dsp fpga_streaming_dsp.srcs sources_1 new fir_core.v]]
read_xdc [list [file join $project_root constraints fir_core_ooc.xdc]]
# OOC treats the module as a block and avoids inserting top-level I/O buffers.
# The XDC provides a 10 ns internal clock target, without board I/O delays.
synth_design -top fir_core -part xc7a35tcpg236-1 -mode out_of_context
report_utilization -file [file join $output_dir utilization.rpt]
report_timing_summary -file [file join $output_dir timing_synth.rpt]
# A clean synthesis exit does not prove timing. Query the worst constrained
# maximum-delay (setup) and minimum-delay (hold) paths and fail explicitly.
# These are post-synthesis estimates, not final routed timing or proven Fmax.
set setup_paths [get_timing_paths -quiet -delay_type max -max_paths 1]
set hold_paths [get_timing_paths -quiet -delay_type min -max_paths 1]
if {[llength $setup_paths] == 0 || [llength $hold_paths] == 0} {
    error "FIR synthesis has no constrained internal timing paths"
}
set setup_slack [get_property SLACK [lindex $setup_paths 0]]
set hold_slack [get_property SLACK [lindex $hold_paths 0]]
if {$setup_slack < 0 || $hold_slack < 0} {
    error "FIR synthesized internal timing failed: setup=$setup_slack hold=$hold_slack"
}
# Save the synthesized netlist and constraints for later inspection in Vivado.
write_checkpoint -force [file join $output_dir fir_core_synth.dcp]
puts "PASS: fir_core out-of-context synthesis setup_slack=$setup_slack hold_slack=$hold_slack"
close_design
