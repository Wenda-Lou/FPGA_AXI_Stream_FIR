# Out-of-context synthesis check for the default 16-bit, depth-16 FIFO.
set project_root [file normalize [file join [file dirname [info script]] ..]]
set output_dir [file join $project_root build fifo_synth]
file mkdir $output_dir
set_param general.maxThreads 2
read_verilog [list [file join $project_root fpga_streaming_dsp fpga_streaming_dsp.srcs sources_1 new axis_fifo.v]]
synth_design -top axis_fifo -part xc7a35tcpg236-1 -mode out_of_context
create_clock -name clk -period 10.000 [get_ports clk]
report_utilization -file [file join $output_dir utilization.rpt]
report_timing_summary -file [file join $output_dir timing_synth.rpt]
write_checkpoint -force [file join $output_dir axis_fifo_synth.dcp]
puts "PASS: axis_fifo out-of-context synthesis"
close_design
