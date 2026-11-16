# Select the complete accelerator in the already-open Vivado project.
if {[llength [get_projects -quiet]] == 0} { error "Open the Vivado project first" }
set accelerator_root [file normalize [file join [file dirname [info script]] ..]]
set accelerator_src [file join $accelerator_root fpga_streaming_dsp fpga_streaming_dsp.srcs]
foreach name {axis_fifo.v fir_core.v dsp_datapath.v axi_lite_regs.v dsp_accelerator.v} {
    set path [file join $accelerator_src sources_1 new $name]
    if {[llength [get_files -quiet [list $path]]] == 0} {
        add_files -norecurse -fileset sources_1 [list $path]
    }
    set_property file_type Verilog [get_files [list $path]]
    set_property is_enabled true [get_files [list $path]]
}
set path [file join $accelerator_src sim_1 tb_dsp_accelerator.sv]
if {[llength [get_files -quiet [list $path]]] == 0} {
    add_files -norecurse -fileset sim_1 [list $path]
}
set_property file_type SystemVerilog [get_files [list $path]]
set_property used_in {simulation} [get_files [list $path]]
set_property is_enabled true [get_files [list $path]]
foreach old_clock [get_files -quiet *fir_core_ooc.xdc] {
    set_property is_enabled false [get_files [list $old_clock]]
}
foreach name {dsp_accelerator_timing.xdc dsp_accelerator_ooc.xdc} {
    set path [file join $accelerator_root constraints $name]
    if {[llength [get_files -quiet [list $path]]] == 0} {
        add_files -norecurse -fileset constrs_1 [list $path]
    }
    set_property is_enabled true [get_files [list $path]]
    if {$name eq "dsp_accelerator_ooc.xdc"} {
        set_property used_in {implementation} [get_files [list $path]]
    } else {
        set_property used_in {synthesis implementation} [get_files [list $path]]
    }
}
set_property top dsp_accelerator [get_filesets sources_1]
set_property top tb_dsp_accelerator [get_filesets sim_1]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1
puts "PASS: complete accelerator project sources and simulation top configured"
puts "For module-level physical acceptance, run scripts/run_implementation.ps1; it includes OOC context and hold repair."
