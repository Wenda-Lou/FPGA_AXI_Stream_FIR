# Run in XSim before the unchanged complete-top testbench starts.
# Capture actual public interfaces plus explicit observational bench probes.
open_vcd accelerator.vcd
foreach signal {
    clk resetn check_latency enable history_clear
    s_axis_tdata s_axis_tvalid s_axis_tready
    m_axis_tdata m_axis_tvalid m_axis_tready
    s_axi_awaddr s_axi_awvalid s_axi_awready
    s_axi_wdata s_axi_wstrb s_axi_wvalid s_axi_wready
    s_axi_bresp s_axi_bvalid s_axi_bready
} {
    set object [get_objects /tb_dsp_accelerator/$signal]
    if {[llength $object] != 1} { error "Missing waveform signal: $signal" }
    log_vcd $object
}
run all
close_vcd
quit
