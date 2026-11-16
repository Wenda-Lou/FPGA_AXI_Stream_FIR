# Reproducible default-configuration MODULE implementation, not a board bitstream.
# Keep RTL unchanged and use explicit clock/interface/physical context constraints.
# Run with Vivado -mode batch -source scripts/implement_accelerator.tcl.
set implementation_root [file normalize [file join [file dirname [info script]] ..]]
set output_dir [file join $implementation_root build accelerator_impl]
file mkdir $output_dir
set_param general.maxThreads 2
source [file join $implementation_root scripts implementation_utils.tcl]

proc write_text {path text} {
    set channel [open $path w]
    puts $channel $text
    close $channel
}

# Write a failure marker first; a failed new run must not leave a stale PASS.
write_text [file join $output_dir acceptance.tsv] "status\tincomplete"
set source_manifest [open [file join $output_dir inputs.tsv] w]
puts $source_manifest "path\tsize\tmtime"
foreach relative_path {
    scripts/implement_accelerator.tcl scripts/implementation_utils.tcl
    constraints/dsp_accelerator_timing.xdc constraints/dsp_accelerator_ooc.xdc
    fpga_streaming_dsp/fpga_streaming_dsp.srcs/sources_1/new/axis_fifo.v
    fpga_streaming_dsp/fpga_streaming_dsp.srcs/sources_1/new/fir_core.v
    fpga_streaming_dsp/fpga_streaming_dsp.srcs/sources_1/new/dsp_datapath.v
    fpga_streaming_dsp/fpga_streaming_dsp.srcs/sources_1/new/axi_lite_regs.v
    fpga_streaming_dsp/fpga_streaming_dsp.srcs/sources_1/new/dsp_accelerator.v
} {
    set path [file join $implementation_root $relative_path]
    puts $source_manifest "$relative_path\t[file size $path]\t[file mtime $path]"
}
close $source_manifest
foreach name {axis_fifo.v fir_core.v dsp_datapath.v axi_lite_regs.v dsp_accelerator.v} {
    read_verilog [list [file join $implementation_root fpga_streaming_dsp fpga_streaming_dsp.srcs sources_1 new $name]]
}
read_xdc [list [file join $implementation_root constraints dsp_accelerator_timing.xdc]]
synth_design -top dsp_accelerator -part xc7a35tcpg236-1 -mode out_of_context
if {[llength [get_sites -quiet BUFGCTRL_X0Y0]] != 1} { error "Assumed parent clock source site is unavailable" }
if {[llength [get_ports -filter {DIRECTION == IN && NAME != clk}]] == 0 ||
    [llength [get_ports -filter {DIRECTION == OUT}]] == 0 ||
    [llength [get_ports -quiet -filter {DIRECTION == INOUT}]] != 0} {
    error "Unexpected accelerator port directions; review interface timing constraints"
}
# Apply physical-only context after synthesis, avoiding synthesis-specific XDC
# restrictions and warnings about placement constraints being ignored by synth.
read_xdc [list [file join $implementation_root constraints dsp_accelerator_ooc.xdc]]
set_property HD.PARTITION true [current_design]
# A whole-device OOC Pblock establishes reusable routing context; the boundary
# pin range is the separate, fixed rectangular region declared in the XDC.
create_pblock accelerator_region
add_cells_to_pblock [get_pblocks accelerator_region] -top
resize_pblock [get_pblocks accelerator_region] -add [get_sites -filter {SITE_TYPE == SLICEL || SITE_TYPE == SLICEM || SITE_TYPE == DSP48E1}]
set_property IS_SOFT false [get_pblocks accelerator_region]
set_property CONTAIN_ROUTING true [get_pblocks accelerator_region]
if {[get_msg_config -count -severity {CRITICAL WARNING}] != 0} { error "Critical warnings during constraint loading/synthesis" }
foreach corner {SLICE_X0Y0 SLICE_X65Y99} {
    if {[llength [get_sites -quiet $corner]] != 1} { error "Invalid boundary-region endpoint: $corner" }
}
report_timing_summary -delay_type min_max -report_unconstrained -check_timing_verbose -max_paths 5 \
    -file [file join $output_dir timing_synth_constrained.rpt]
write_checkpoint -force [file join $output_dir synthesized.dcp]

# Timing-driven implementation. Route_design performs hold fixing; do not weaken
# min-delay constraints or add false paths to hide a failure.
opt_design
place_design -directive Default
phys_opt_design -directive Default
route_design -directive Default
if {[get_property SLACK [lindex [get_timing_paths -delay_type min -max_paths 1] 0]] < 0} {
    route_design -directive Explore
}
# OOC boundary fragments can prevent post-route phys_opt from running. Repair
# fast input paths explicitly with audited identity LUTs, then place/route again.
# No register or clock edge is inserted and no timing constraint is relaxed.
set hold_channel [open [file join $output_dir hold_repairs.tsv] w]
puts $hold_channel "iteration\tport\tprevious_hold_slack_ns\tidentity_luts"
set iteration_channel [open [file join $output_dir iterations.tsv] w]
puts $iteration_channel "iteration\tsetup_wns_ns\thold_slack_ns\tadded_identity_luts"
puts $iteration_channel "0\t[get_property SLACK [get_timing_paths -delay_type max -max_paths 1]]\t[get_property SLACK [get_timing_paths -delay_type min -max_paths 1]]\t0"
for {set repair_iteration 1} {$repair_iteration <= 5} {incr repair_iteration} {
    if {[get_property SLACK [get_timing_paths -delay_type min -max_paths 1]] >= 0} { break }
    set plans [plan_input_hold_repairs]
    if {[llength $plans] == 0} { break }
    route_design -unroute
    set added [apply_input_hold_repairs $plans $repair_iteration $hold_channel]
    place_design -directive Explore
    phys_opt_design -directive ExploreWithAggressiveHoldFix
    route_design -directive Explore
    puts $iteration_channel "$repair_iteration\t[get_property SLACK [get_timing_paths -delay_type max -max_paths 1]]\t[get_property SLACK [get_timing_paths -delay_type min -max_paths 1]]\t$added"
    flush $iteration_channel
}
close $hold_channel
close $iteration_channel
write_checkpoint -force [file join $output_dir dsp_accelerator_routed.dcp]
# Verify the restorable artifact, not transient in-memory hierarchy/route caches.
# Reloading also normalizes boundary aliases introduced by RAM/physical changes.
close_design
open_checkpoint [file join $output_dir dsp_accelerator_routed.dcp]
write_xdc -force [file join $output_dir implemented_constraints.xdc]

set timing_text [report_timing_summary -delay_type min_max -report_unconstrained \
    -check_timing_verbose -max_paths 10 -path_type full_clock_expanded -return_string]
write_text [file join $output_dir timing_post_route.rpt] $timing_text
set check_text [check_timing -verbose -return_string]
write_text [file join $output_dir check_timing.rpt] $check_text
report_utilization -file [file join $output_dir utilization_post_route.rpt]
report_route_status -file [file join $output_dir route_status.rpt]
report_clocks -file [file join $output_dir clocks.rpt]
report_clock_interaction -file [file join $output_dir clock_interaction.rpt]
report_exceptions -file [file join $output_dir exceptions.rpt]
report_drc -name accelerator_drc -file [file join $output_dir drc_post_route.rpt]
report_methodology -name accelerator_methodology -file [file join $output_dir methodology.rpt]

set failures {}
set checks {}
# Route 35-39 from an intermediate repair iteration is resolved only if final
# measured timing passes. All other critical warning classes remain fatal.
set critical_count [get_msg_config -count -severity {CRITICAL WARNING}]
set iterative_timing_messages [get_msg_config -count -id {Route 35-39}]
if {$critical_count > $iterative_timing_messages} { lappend failures "unresolved critical warnings during implementation" }
# Fail closed if a required coverage check is missing from the tool report.
foreach check {no_clock constant_clock pulse_width_clock unconstrained_internal_endpoints no_input_delay no_output_delay multiple_clock generated_clocks loops latch_loops partial_input_delay partial_output_delay} {
    set pattern [format {checking\s+%s\s+\(([0-9]+)\)} $check]
    if {![regexp $pattern $timing_text ignored count]} {
        error "Missing timing-coverage result: $check"
    }
    dict set checks $check $count
    if {$count != 0} { lappend failures "timing coverage $check=$count" }
}

set setup_paths [get_timing_paths -delay_type max -max_paths 1]
set hold_paths [get_timing_paths -delay_type min -max_paths 1]
if {[llength $setup_paths] == 0 || [llength $hold_paths] == 0} { error "Missing constrained setup/hold paths" }
set setup_slack [get_property SLACK [lindex $setup_paths 0]]
set hold_slack [get_property SLACK [lindex $hold_paths 0]]
if {$setup_slack < 0 || $hold_slack < 0} { lappend failures "negative setup/hold slack: $setup_slack / $hold_slack" }

# Parse the complete twelve-column Design Timing Summary, including pulse width.
set summary_fields {}
foreach line [split $timing_text "\n"] {
    set fields [regexp -all -inline {\S+} $line]
    if {[llength $fields] == 12 && [string is double -strict [lindex $fields 0]] &&
        [string is double -strict [lindex $fields 4]] && [string is double -strict [lindex $fields 8]]} {
        set summary_fields $fields
        break
    }
}
if {[llength $summary_fields] != 12} { error "Cannot read complete Design Timing Summary" }
set pulse_slack [lindex $summary_fields 8]
foreach index {0 1 2 4 5 6 8 9 10} {
    if {[lindex $summary_fields $index] < 0 || ($index in {2 6 10} && [lindex $summary_fields $index] != 0)} {
        lappend failures "timing summary violations at column $index"
    }
}

set routed [report_route_status -boolean_check ROUTED_FULLY]
set route_errors [report_route_status -boolean_check ERRORS_IN_ROUTES]
set routing_audit [audit_module_routing [file join $output_dir boundary_ports.tsv]]
dict for {name count} $routing_audit {
    if {$name in {missing_boundary_ports missing_boundary_anchors unexpected_route_nets} && $count != 0} {
        lappend failures "$name=$count"
    }
}
set identity_buffers [audit_identity_buffers [file join $output_dir identity_buffers.tsv]]
set severe_drc [get_drc_violations -name accelerator_drc -quiet -filter {SEVERITY == "Error" || SEVERITY == "Critical Warning"}]
set severe_methodology [get_methodology_violations -name accelerator_methodology -quiet -filter {SEVERITY == "Error" || SEVERITY == "Critical Warning"}]
if {[llength $severe_drc] || [llength $severe_methodology]} { lappend failures "severe DRC/methodology violations" }

# Export each relationship, including pure boundary combinational paths. Actual
# endpoints make the internal/interface scope of the worst path reviewable.
set path_channel [open [file join $output_dir path_classes.tsv] w]
puts $path_channel "class\tcheck\tslack_ns\tstartpoint\tendpoint"
foreach specification {{register_to_register clk clk} {input_to_register interface_clk clk} {register_to_output clk interface_clk} {input_to_output interface_clk interface_clk}} {
    lassign $specification label source_clock destination_clock
    foreach delay {max min} {
        set paths [get_timing_paths -from [get_clocks $source_clock] -to [get_clocks $destination_clock] -delay_type $delay -max_paths 1]
        if {[llength $paths] == 0} { lappend failures "missing functional path class $label/$delay"; continue }
        set path [lindex $paths 0]
        puts $path_channel "$label\t$delay\t[get_property SLACK $path]\t[get_property STARTPOINT_PIN $path]\t[get_property ENDPOINT_PIN $path]"
    }
}
close $path_channel

set status [expr {[llength $failures] == 0 ? "passed" : "failed"}]
set acceptance "status\t$status\nsetup_wns_ns\t$setup_slack\nhold_slack_ns\t$hold_slack\npulse_width_slack_ns\t$pulse_slack\nrouted_fully\t$routed\nroute_errors\t$route_errors\nidentity_buffers\t$identity_buffers\nsevere_drc\t[llength $severe_drc]\nsevere_methodology\t[llength $severe_methodology]\nclock_source_site\t[get_property HD.CLK_SRC [get_ports clk]]\nboundary_range\t[get_property HD.PARTPIN_RANGE [lindex [get_ports -filter {NAME != clk}] 0]]"
dict for {name count} $routing_audit { append acceptance "\n$name\t$count" }
dict for {check count} $checks { append acceptance "\n$check\t$count" }
append acceptance "\nfailures\t[join $failures {; }]"
write_text [file join $output_dir acceptance.tsv] $acceptance
if {[llength $failures] != 0} { error "Accelerator implementation acceptance failed: [join $failures {; }]" }
puts "PASS: dsp_accelerator routed implementation setup_slack=$setup_slack hold_slack=$hold_slack pulse_slack=$pulse_slack"
close_design
