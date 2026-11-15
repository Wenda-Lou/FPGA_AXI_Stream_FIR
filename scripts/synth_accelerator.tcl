# Complete accelerator synthesis with a clock-only internal timing target.
# External AXI timing assumptions and placement/routing remain separate work.
set accelerator_root [file normalize [file join [file dirname [info script]] ..]]
set output_dir [file join $accelerator_root build accelerator_synth]
file mkdir $output_dir
set_param general.maxThreads 2
foreach name {axis_fifo.v fir_core.v dsp_datapath.v axi_lite_regs.v dsp_accelerator.v} {
    read_verilog [list [file join $accelerator_root fpga_streaming_dsp fpga_streaming_dsp.srcs sources_1 new $name]]
}
read_xdc [list [file join $accelerator_root constraints fir_core_ooc.xdc]]
synth_design -top dsp_accelerator -part xc7a35tcpg236-1 -mode out_of_context
report_utilization -file [file join $output_dir utilization.rpt]
report_timing_summary -file [file join $output_dir timing_synth.rpt]
set setup_paths [get_timing_paths -quiet -delay_type max -max_paths 1]
set hold_paths [get_timing_paths -quiet -delay_type min -max_paths 1]
if {[llength $setup_paths] == 0 || [llength $hold_paths] == 0} {
    error "Accelerator has no constrained internal setup/hold paths"
}
set setup_slack [get_property SLACK [lindex $setup_paths 0]]
set hold_slack [get_property SLACK [lindex $hold_paths 0]]
if {$setup_slack < 0 || $hold_slack < 0} {
    error "Accelerator internal timing failed: setup=$setup_slack hold=$hold_slack"
}
write_checkpoint -force [file join $output_dir dsp_accelerator_synth.dcp]
puts "PASS: dsp_accelerator out-of-context synthesis setup_slack=$setup_slack hold_slack=$hold_slack"
close_design
