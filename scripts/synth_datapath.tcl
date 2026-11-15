# Synthesize the buffered streaming block, before AXI4-Lite integration.
# This clock-only OOC estimate does not constrain external control/data delays
# and does not substitute for final full-system placement/routing acceptance.
set project_root [file normalize [file join [file dirname [info script]] ..]]
set output_dir [file join $project_root build datapath_synth]
file mkdir $output_dir
set_param general.maxThreads 2
foreach name {axis_fifo.v fir_core.v dsp_datapath.v} {
    read_verilog [list [file join $project_root fpga_streaming_dsp fpga_streaming_dsp.srcs sources_1 new $name]]
}
# The existing constraint describes the same clk port and 10 ns target.
read_xdc [list [file join $project_root constraints fir_core_ooc.xdc]]
synth_design -top dsp_datapath -part xc7a35tcpg236-1 -mode out_of_context
report_utilization -file [file join $output_dir utilization.rpt]
report_timing_summary -file [file join $output_dir timing_synth.rpt]
set setup_paths [get_timing_paths -quiet -delay_type max -max_paths 1]
set hold_paths [get_timing_paths -quiet -delay_type min -max_paths 1]
if {[llength $setup_paths] == 0 || [llength $hold_paths] == 0} {
    error "Datapath has no constrained internal setup/hold paths"
}
set setup_slack [get_property SLACK [lindex $setup_paths 0]]
set hold_slack [get_property SLACK [lindex $hold_paths 0]]
if {$setup_slack < 0 || $hold_slack < 0} {
    error "Datapath internal timing failed: setup=$setup_slack hold=$hold_slack"
}
write_checkpoint -force [file join $output_dir dsp_datapath_synth.dcp]
puts "PASS: dsp_datapath out-of-context synthesis setup_slack=$setup_slack hold_slack=$hold_slack"
close_design
