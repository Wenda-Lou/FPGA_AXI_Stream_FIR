# Source in the open project's Tcl Console for register-bank unit simulation.
if {[llength [get_projects -quiet]] == 0} { error "Open the Vivado project first" }
set regs_root [file normalize [file join [file dirname [info script]] ..]]
foreach integration_constraint [get_files -quiet *dsp_accelerator_*.xdc] {
    set_property is_enabled false [get_files [list $integration_constraint]]
}
set regs_src [file join $regs_root fpga_streaming_dsp fpga_streaming_dsp.srcs]
set path [file join $regs_src sources_1 new axi_lite_regs.v]
if {[llength [get_files -quiet [list $path]]] == 0} {
    add_files -norecurse -fileset sources_1 [list $path]
}
set_property file_type Verilog [get_files [list $path]]
set_property is_enabled true [get_files [list $path]]
set path [file join $regs_src sim_1 tb_axi_lite_regs.sv]
if {[llength [get_files -quiet [list $path]]] == 0} {
    add_files -norecurse -fileset sim_1 [list $path]
}
set_property file_type SystemVerilog [get_files [list $path]]
set_property used_in {simulation} [get_files [list $path]]
set_property is_enabled true [get_files [list $path]]
set path [file join $regs_root constraints fir_core_ooc.xdc]
if {[llength [get_files -quiet [list $path]]] == 0} {
    add_files -norecurse -fileset constrs_1 [list $path]
}
set_property used_in {synthesis implementation} [get_files [list $path]]
set_property is_enabled true [get_files [list $path]]
set_property top axi_lite_regs [get_filesets sources_1]
set_property top tb_axi_lite_regs [get_filesets sim_1]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1
puts "PASS: AXI register bank project sources and simulation top configured"
