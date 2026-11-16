# Synchronize the already-open Vivado project with the canonical FIR files.
# Source this in the project's Tcl Console. This script edits project references
# and properties; remove_files below does not delete source files from disk.
if {[llength [get_projects -quiet]] == 0} {
    error "Open the Vivado project before sourcing configure_fir_project.tcl"
}
set fir_root [file normalize [file join [file dirname [info script]] ..]]
# Restore standalone timing when switching back from complete-top analysis.
foreach integration_constraint [get_files -quiet *dsp_accelerator_*.xdc] {
    set_property is_enabled false [get_files [list $integration_constraint]]
}
set fir_rtl [file join $fir_root fpga_streaming_dsp fpga_streaming_dsp.srcs sources_1 new fir_core.v]
set fir_tb [file join $fir_root fpga_streaming_dsp fpga_streaming_dsp.srcs sim_1 tb_fir_core.sv]
set fir_clock_constraints [file join $fir_root constraints fir_core_ooc.xdc]
# Remove alternate copies from their respective file sets so an old module with
# the same name cannot silently shadow the canonical source or testbench.
foreach old_rtl [get_files -quiet -of_objects [get_filesets sources_1] *fir_core.v] {
    if {[file normalize $old_rtl] ne $fir_rtl} { remove_files [list $old_rtl] }
}
foreach old_tb [get_files -quiet -of_objects [get_filesets sim_1] *tb_fir_core.sv] {
    if {[file normalize $old_tb] ne $fir_tb} { remove_files [list $old_tb] }
}
if {[llength [get_files -quiet [list $fir_rtl]]] == 0} {
    add_files -norecurse -fileset sources_1 [list $fir_rtl]
}
if {[llength [get_files -quiet [list $fir_tb]]] == 0} {
    add_files -norecurse -fileset sim_1 [list $fir_tb]
}
if {[llength [get_files -quiet [list $fir_clock_constraints]]] == 0} {
    add_files -norecurse -fileset constrs_1 [list $fir_clock_constraints]
}
# RTL uses Verilog; the bench needs SystemVerilog assertions and dynamic queues.
# Keep the bench simulation-only and the clock constraint synthesis/implementation-only.
set_property file_type Verilog [get_files [list $fir_rtl]]
set_property file_type SystemVerilog [get_files [list $fir_tb]]
set_property used_in {simulation} [get_files [list $fir_tb]]
set_property used_in {synthesis implementation} [get_files [list $fir_clock_constraints]]
set_property is_enabled true [get_files [list $fir_clock_constraints]]
set_property is_enabled true [get_files [list $fir_rtl]]
set_property is_enabled true [get_files [list $fir_tb]]
# Design top identifies the hardware block; simulation top identifies the module
# that generates clock/stimulus and instantiates that block as the DUT.
set_property top fir_core [get_filesets sources_1]
set_property top tb_fir_core [get_filesets sim_1]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1
puts "PASS: FIR project sources and simulation top configured"
