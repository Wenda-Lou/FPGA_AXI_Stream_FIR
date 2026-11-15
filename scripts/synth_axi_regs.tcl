# Default register-bank synthesis and clock-only internal timing estimate.
# Bus/event/control I/O delays and full-system post-route timing remain pending.
set regs_root [file normalize [file join [file dirname [info script]] ..]]
set output_dir [file join $regs_root build axi_regs_synth]
file mkdir $output_dir
set_param general.maxThreads 2
read_verilog [list [file join $regs_root fpga_streaming_dsp fpga_streaming_dsp.srcs sources_1 new axi_lite_regs.v]]
read_xdc [list [file join $regs_root constraints fir_core_ooc.xdc]]
synth_design -top axi_lite_regs -part xc7a35tcpg236-1 -mode out_of_context
report_utilization -file [file join $output_dir utilization.rpt]
report_timing_summary -file [file join $output_dir timing_synth.rpt]
set setup_paths [get_timing_paths -quiet -delay_type max -max_paths 1]
set hold_paths [get_timing_paths -quiet -delay_type min -max_paths 1]
if {[llength $setup_paths] == 0 || [llength $hold_paths] == 0} {
    error "Register bank has no constrained internal setup/hold paths"
}
set setup_slack [get_property SLACK [lindex $setup_paths 0]]
set hold_slack [get_property SLACK [lindex $hold_paths 0]]
if {$setup_slack < 0 || $hold_slack < 0} {
    error "Register bank internal timing failed: setup=$setup_slack hold=$hold_slack"
}
write_checkpoint -force [file join $output_dir axi_lite_regs_synth.dcp]
puts "PASS: axi_lite_regs out-of-context synthesis setup_slack=$setup_slack hold_slack=$hold_slack"
close_design
