# Physical implementation helpers. These commands alter only the implementation
# netlist; the canonical RTL and its clock-cycle behavior are unchanged.

proc plan_input_hold_repairs {} {
    set plans {}
    foreach port [get_ports -filter {DIRECTION == IN && NAME != clk}] {
        set paths [get_timing_paths -quiet -from $port -to [get_clocks {clk interface_clk}] -delay_type min -max_paths 1]
        if {[llength $paths]} {
            set slack [get_property SLACK [lindex $paths 0]]
            if {$slack < 0} {
                # This is a repair heuristic, not an assumed device delay. Real
                # setup/hold are measured again after every placement/routing.
                set stages [expr {int(ceil(-$slack/0.100))+3}]
                lappend plans [list $port $stages $slack]
            }
        }
    }
    return $plans
}

proc apply_input_hold_repairs {plans iteration channel} {
    set count 0
    foreach plan $plans {
        lassign $plan port stages slack
        set stem [regsub -all {[^A-Za-z0-9_]} $port _]
        set original_net [get_nets -of_objects $port]
        if {[llength $original_net] != 1} { error "Unexpected input net for hold repair: $port" }
        # Split at the PORT, retaining every existing internal load and hierarchy
        # connection on original_net. The inserted chain is exactly y=x.
        disconnect_net -net $original_net -objects $port
        set previous_net [create_net impl_hold_r${iteration}_${stem}_input]
        connect_net -net $previous_net -objects $port
        for {set stage 0} {$stage < $stages} {incr stage} {
            set buffer [create_cell -reference LUT1 impl_hold_r${iteration}_${stem}_${stage}]
            set_property INIT 2'h2 $buffer
            set_property DONT_TOUCH true $buffer
            connect_net -net $previous_net -objects [get_pins $buffer/I0]
            if {$stage == $stages-1} {
                connect_net -net $original_net -objects [get_pins $buffer/O]
            } else {
                set previous_net [create_net impl_hold_r${iteration}_${stem}_${stage}_out]
                connect_net -net $previous_net -objects [get_pins $buffer/O]
            }
            incr count
        }
        puts $channel "$iteration\t$port\t$slack\t$stages"
    }
    flush $channel
    return $count
}

proc audit_identity_buffers {path} {
    set channel [open $path w]
    puts $channel "cell\tinit\tinput_net\toutput_net"
    set count 0
    foreach buffer [get_cells -quiet impl_hold_r*] {
        set init [string tolower [get_property INIT $buffer]]
        if {[get_property REF_NAME $buffer] ne "LUT1" || $init ni {2'h2 2'b10 2'd2 0x2 2} ||
            ![get_property DONT_TOUCH $buffer]} { error "Non-identity hold cell: $buffer / $init" }
        set input_net [get_nets -of_objects [get_pins $buffer/I0]]
        set output_net [get_nets -of_objects [get_pins $buffer/O]]
        if {[llength $input_net] != 1 || [llength $output_net] != 1} { error "Disconnected hold cell: $buffer" }
        puts $channel "$buffer\t$init\t$input_net\t$output_net"
        incr count
    }
    close $channel
    return $count
}

proc audit_module_routing {path} {
    set channel [open $path w]
    puts $channel "port\tdirection\tfunctional\tpartition_pin\tanchor_in_route"
    set functional_count 0
    set missing_locations 0
    set missing_anchors 0
    set boundary_nets [dict create]
    foreach port [get_ports -filter {NAME != clk}] {
        set direction [get_property DIRECTION $port]
        set nets [get_nets -quiet -segments -of_objects $port]
        set roots [get_nets -quiet -of_objects $port]
        # Ignored PROT/reserved inputs can legitimately have no surviving net.
        # They have no functional timing paths and need no partition node.
        if {[llength $roots]} {
            set root_net [get_property NAME $roots]
            foreach net $nets { dict set boundary_nets [get_property NAME $net] $root_net }
        }
        if {$direction eq "IN"} {
            set paths [get_timing_paths -quiet -from $port -to [get_clocks {clk interface_clk}] -max_paths 1]
        } else {
            set paths [get_timing_paths -quiet -from [get_clocks {clk interface_clk}] -to $port -max_paths 1]
        }
        set functional [expr {[llength $paths] > 0}]
        set location [get_property HD.ASSIGNED_PPLOCS $port]
        set anchor_present 0
        if {$functional} {
            incr functional_count
            if {[llength $location] != 2} {
                incr missing_locations
            } else {
                lassign $location tile wire
                set anchor [get_nodes -of_objects [get_wires $tile/$wire]]
                set route_nodes [get_nodes -of_objects $nets]
                set anchor_present [expr {[llength $anchor] == 1 && [lsearch -exact $route_nodes $anchor] >= 0}]
                if {!$anchor_present} { incr missing_anchors }
            }
        }
        puts $channel "$port\t$direction\t$functional\t$location\t$anchor_present"
    }
    close $channel

    # An OOC interface subnet ends at a partition node, with the parent-side net
    # deliberately absent. Vivado labels such boundary stubs ANTENNAS. Accept
    # only those attached to declared module ports AND audited physical anchors.
    # Never waive an antenna on an internal net, or any gap/conflict/unplaced net.
    set expected_stubs [dict create]
    set unexpected 0
    # Query the net's ROUTE_STATUS property directly. Some tool versions return
    # inconsistent -return_nets classifications for hierarchical OOC subnets.
    foreach net [get_nets -hier -filter {ROUTE_STATUS == ANTENNAS}] {
        if {[dict exists $boundary_nets [get_property NAME $net]] && [get_property DRIVER_COUNT $net] <= 1} {
            dict set expected_stubs [dict get $boundary_nets [get_property NAME $net]] 1
        } else { incr unexpected }
    }
    foreach kind {UNPLACED PARTIAL GAPS CONFLICTS MULTI_DRIVER} {
        incr unexpected [llength [get_nets -hier -quiet -filter "ROUTE_STATUS == $kind"]]
    }
    return [dict create functional_ports $functional_count missing_boundary_ports $missing_locations \
        missing_boundary_anchors $missing_anchors expected_ooc_boundary_stubs [dict size $expected_stubs] \
        unexpected_route_nets $unexpected]
}
