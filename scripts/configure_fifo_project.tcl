# Run from the Tcl Console of the already-open Vivado project.
# This also updates an open GUI whose in-memory file list predates disk edits.
if {[llength [get_projects -quiet]] == 0} {
    error "Open the Vivado project before sourcing configure_fifo_project.tcl"
}
set fifo_root [file normalize [file join [file dirname [info script]] ..]]
foreach integration_constraint [get_files -quiet *dsp_accelerator_*.xdc] {
    set_property is_enabled false [get_files [list $integration_constraint]]
}
foreach standalone_clock [get_files -quiet *fir_core_ooc.xdc] {
    set_property is_enabled true [get_files [list $standalone_clock]]
}
set fifo_rtl [file join $fifo_root fpga_streaming_dsp fpga_streaming_dsp.srcs sources_1 new axis_fifo.v]
set fifo_tb [file join $fifo_root fpga_streaming_dsp fpga_streaming_dsp.srcs sim_1 tb_axis_fifo.sv]

foreach pattern {sample_reg.sv sample_counter.sv tb_sample_reg.sv tb_sample_counter.sv} {
    foreach old_file [get_files -quiet *$pattern] {
        if {![file exists $old_file]} { remove_files [list $old_file] }
    }
}
foreach old_tb [get_files -quiet -of_objects [get_filesets sim_1] *tb_axis_fifo.sv] {
    if {[file normalize $old_tb] ne $fifo_tb} { remove_files [list $old_tb] }
}
if {[llength [get_files -quiet [list $fifo_rtl]]] == 0} {
    add_files -norecurse -fileset sources_1 [list $fifo_rtl]
}
if {[llength [get_files -quiet [list $fifo_tb]]] == 0} {
    add_files -norecurse -fileset sim_1 [list $fifo_tb]
}
set_property file_type SystemVerilog [get_files [list $fifo_tb]]
set_property used_in {simulation} [get_files [list $fifo_tb]]
set_property is_enabled true [get_files [list $fifo_tb]]
set_property top axis_fifo [get_filesets sources_1]
set_property top tb_axis_fifo [get_filesets sim_1]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1
puts "PASS: FIFO project sources and simulation top configured"
