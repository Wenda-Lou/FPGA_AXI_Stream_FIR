# Source this from the already-open project's Tcl Console. Keep the verified
# standalone sources available while selecting the new integration simulation.
if {[llength [get_projects -quiet]] == 0} {
    error "Open the Vivado project before sourcing configure_datapath_project.tcl"
}
set datapath_root [file normalize [file join [file dirname [info script]] ..]]
set datapath_src [file join $datapath_root fpga_streaming_dsp fpga_streaming_dsp.srcs]
foreach name {axis_fifo.v fir_core.v dsp_datapath.v} {
    set path [file join $datapath_src sources_1 new $name]
    if {[llength [get_files -quiet [list $path]]] == 0} {
        add_files -norecurse -fileset sources_1 [list $path]
    }
    set_property file_type Verilog [get_files [list $path]]
    set_property is_enabled true [get_files [list $path]]
}
set path [file join $datapath_src sim_1 tb_dsp_datapath.sv]
if {[llength [get_files -quiet [list $path]]] == 0} {
    add_files -norecurse -fileset sim_1 [list $path]
}
set_property file_type SystemVerilog [get_files [list $path]]
set_property used_in {simulation} [get_files [list $path]]
set_property is_enabled true [get_files [list $path]]
set path [file join $datapath_root constraints fir_core_ooc.xdc]
if {[llength [get_files -quiet [list $path]]] == 0} {
    add_files -norecurse -fileset constrs_1 [list $path]
}
set_property used_in {synthesis implementation} [get_files [list $path]]
set_property top dsp_datapath [get_filesets sources_1]
set_property top tb_dsp_datapath [get_filesets sim_1]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1
puts "PASS: buffered FIR datapath project sources and simulation top configured"
