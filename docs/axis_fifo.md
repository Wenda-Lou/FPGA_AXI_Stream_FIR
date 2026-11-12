# AXI Stream FIFO: Design and Validation

Status: the FIFO module is complete for the tested configurations below.
RTL is Verilog; the testbench is SystemVerilog. FIR processing and the full
accelerator are separate milestones.

## Files

- [axis_fifo.v](../fpga_streaming_dsp/fpga_streaming_dsp.srcs/sources_1/new/axis_fifo.v): synthesizable FIFO.
- [tb_axis_fifo.sv](../fpga_streaming_dsp/fpga_streaming_dsp.srcs/sim_1/tb_axis_fifo.sv): canonical self-checking testbench.
- [run_fifo.ps1](../scripts/run_fifo.ps1): simulation regression and result checks.
- [configure_fifo_project.tcl](../scripts/configure_fifo_project.tcl): synchronize an open Vivado project's file list.
- [synth_fifo.tcl](../scripts/synth_fifo.tcl): standalone synthesis check.

## Interface and Behavior

| Item | Contract |
| --- | --- |
| `DATA_WIDTH` | Positive data width in bits; default 16 |
| `DEPTH` | Power of two, at least 2; default 16 |
| `occupancy` | Unsigned count with `$clog2(DEPTH) + 1` bits, ranging from 0 through DEPTH |
| Clock/reset | Single rising-edge clock; active-low synchronous reset clears count and pointers |
| Input transfer | A rising edge with `resetn`, `s_valid` and `s_ready` high |
| Output transfer | A rising edge with `resetn`, `m_valid` and `m_ready` high |
| Ready/valid | Both are low during reset; otherwise input is ready below full and output is valid above empty |
| Empty behavior | No combinational input bypass; a newly written sample becomes available after its write edge |
| Full behavior | A write is rejected when full even if a read occurs on the same edge; the source must hold its pending sample |
| Output read | Combinational read of the oldest stored word; data remains stable while valid and stalled |
| Empty output data | Unspecified and ignored when `m_valid = 0` |
| Simultaneous transfers | Both pointers advance; count is unchanged |
| Reset with traffic | Accepted but unconsumed words are discarded; memory contents need not be cleared |

The source must hold `s_valid` and `s_data` until acceptance or reset. Gating
ready/valid with reset suppresses advertised transfers while reset is asserted;
state clearing still occurs on the clock edge. The module has no packet sidebands
or clock-domain crossing. Small asynchronous-read storage maps to distributed RAM
in the measured build.

## Simulation Results

Tool: Vivado Simulator 2026.1, build 6511674. All 32 runs passed, with no assertion
failures or scoreboard mismatches.

| Width | Depth | Seeds | Random inputs per seed | Total random inputs |
| --- | --- | --- | --- | --- |
| 16 | 16 | 1 through 20 | 10,000 | 200,000 |
| 16 | 2 | 1, 7, 42 | 1,000 | 3,000 |
| 16 | 4 | 1, 7, 42 | 1,000 | 3,000 |
| 8 | 4 | 1, 7, 42 | 1,000 | 3,000 |
| 32 | 16 | 1, 7, 42 | 1,000 | 3,000 |

Each run includes reset, empty read attempts, single and multiple samples,
high-bit/all-ones payloads, output stalls, filling to capacity, a held blocked
input, simultaneous requests at full, repeated pointer wraparound, and reset
while input and output are blocked. Every run demonstrates 1,024 consecutive
cycles with both an accepted input and an accepted output.

The randomized phase continues until the required number of inputs has actually
been accepted. It uses input gaps, held input payloads under backpressure, random
output readiness and periodic 24-cycle output stalls. A queue scoreboard compares
accepted outputs in order. Final draining checks conservation:

```text
accepted writes = accepted reads + words discarded by reset
```

Separate negative checks confirmed that `DEPTH=3` triggers the parameter guard,
and that a temporary copy with memory deliberately narrowed to four bits fails
the data scoreboard. These checks used generated copies/snapshots under `build/`.

The retained [regression results](../reports/axis_fifo/regression_results.json)
contain source hashes and per-run metrics. Log names refer to files regenerated
under `build/fifo_sim/`. Other parameter combinations have not been included in
this acceptance run.

## Synthesis Results and Timing Scope

Default configuration: width 16, depth 16. Target: `xc7a35tcpg236-1`.

| Resource | Post-synthesis use |
| --- | --- |
| LUTs | 26: 14 for logic and 12 for distributed RAM |
| Flip-flops | 13 |
| Inferred latches | 0 |
| BRAM | 0 |
| DSP | 0 |

See the retained [utilization report](../reports/axis_fifo/utilization_synth.rpt)
and [synthesized timing report](../reports/axis_fifo/timing_synth.rpt).

The standalone timing report applies a 10 ns clock and reports setup WNS
`+7.048 ns` and hold slack `+0.218 ns` on the synthesized netlist. The report
lists 19 input ports without input delays and 23 output ports without output
delays. Vivado also issues `Timing 38-242` because an out-of-context clock-buffer
location is unspecified. These results provide an early synthesis check;
top-level I/O timing, placement/routing, final frequency and physical-board
behavior remain unvalidated.

Reproduction commands and GUI setup are in [development.md](development.md).
