# Complete DSP Accelerator

`dsp_accelerator` connects the verified AXI4-Lite register bank to the buffered
FIR datapath. The top and its integrated simulation are complete for the matrix
below. Full-system physical implementation and post-route timing remain pending.

```text
AXI4-Lite -> registers -> enable / coefficients / history clear
                ^                       |
                | status/events         v
AXI4-Stream -> input FIFO -> FIR -> output FIFO -> AXI4-Stream
```

## Sources and Interface

- [dsp_accelerator.v](../fpga_streaming_dsp/fpga_streaming_dsp.srcs/sources_1/new/dsp_accelerator.v): Verilog top with detailed integration comments.
- [tb_dsp_accelerator.sv](../fpga_streaming_dsp/fpga_streaming_dsp.srcs/sim_1/tb_dsp_accelerator.sv): AXI drivers, register-map model, arithmetic scoreboard, assertions and concurrent traffic.
- [run_accelerator.ps1](../scripts/run_accelerator.ps1): simulation matrix and Python replay.
- [configure_accelerator_project.tcl](../scripts/configure_accelerator_project.tcl): Vivado file sets and top selection.
- [synth_accelerator.tcl](../scripts/synth_accelerator.tcl): default complete-top OOC synthesis and constrained internal timing checks.

The design exposes one clock/reset pair, one AXI4-Lite slave and one streaming
input/output pair. All state uses rising-edge `clk` and synchronous active-low
`resetn`. Stream signals are `s_axis_tdata/tvalid/tready` and
`m_axis_tdata/tvalid/tready`; data words represent signed two's-complement samples.
There is no TLAST, TKEEP, packet protocol or separate saturation sideband.

AXI4-Lite addresses are 8-bit byte offsets; data is 32 bits with four write-byte
strobes. AWPROT/ARPROT are accepted and ignored. The map and access rules are
unchanged from the [register-bank contract](axi_lite_regs.md): CONTROL at `0x00`,
STATUS at `0x04`, input/output counters at `0x08/0x0C`, and coefficients at
`0x20+4*k`.

Compile-time parameters are `DATA_WIDTH`, `COEFF_WIDTH`, `OUTPUT_WIDTH`, `TAPS`,
the three fractional-bit counts, and independent `INPUT_FIFO_DEPTH` and
`OUTPUT_FIFO_DEPTH`. Defaults are eight Q1.15 taps, 16-bit data/coefficients/output
and depth-16 FIFOs. The constituent modules enforce their documented width,
power-of-two and nonnegative-shift restrictions.

## Integration Behavior

The register bank owns coefficients, ENABLE, the two transfer counters and sticky
SATURATED. The datapath owns both FIFOs, the FIR pipeline and global idle. The top
connects these boundaries without adding a data register or duplicating state.

Input/output counters receive EXTERNAL stream handshakes, qualified by reset.
They do not count clock cycles with valid asserted, internal FIFO transfers or
FIR productions. A disabling CONTROL commit sees the old ENABLE at that edge,
so its last accepted input is still processed and counted. Subsequent external
inputs stop while all previously accepted work can drain.

Global idle includes both FIFOs and both FIR valid stages. The register bank
permits coefficient writes or soft clear only when disabled and globally idle.
Its qualified history-clear strobe reaches the datapath on that same commit edge.
A stalled B response does not repeat the command. Soft clear is not wired to
hardware reset: pending AXI responses survive it, while history/counters/sticky
status clear and coefficients remain unchanged. Disable/re-enable alone preserves
sample history.

Sticky SATURATED receives the event when a clipped FIR result enters the output
FIFO. It can set before the receiver consumes any output. A blocked result does
not repeatedly issue this event. The datapath still logically buffers per-result
clipping metadata for verification; the external stream exports data only.

Hardware reset clears the register bank, coefficients, FIFO occupancy, pipeline
valids and FIR history, and abandons pending AXI transactions/results. No separate
reset or enable gating interrupts the internal drain path during normal operation.

No-stall external handshake latency is four clocks and steady throughput one
sample per clock. Total accepted-but-unconsumed capacity is the sum of both FIFO
depths plus two FIR stages: 34 samples in the default configuration.

## Run the Integrated Simulation

From the repository root, adapting installed tool paths if necessary:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ./scripts/run_accelerator.ps1 -VivadoBin 'E:/2026.1/Vivado/bin' -Python 'H:/2025.1/tps/win64/python-3.13.0/python.exe'
```

Defaults run 20 seeds of 10,000 accepted random samples for the required build,
plus three seeds (1, 7, 42) of 1,000 samples for nine smoke configurations.
`-Seeds`, `-Samples`, `-SmokeSamples` and `-SkipSmoke` permit shorter runs.
Logs, accepted-event traces, Python summaries and exact source hashes are under
`build/accelerator_sim/`.

| Taps | Input / coefficient / output bits | Fractional bits | FIFO input / output depth | Runs |
| --- | --- | --- | --- | --- |
| 8 | 16 / 16 / 16 | 15 / 15 / 15 | 16 / 16 | 20 |
| 8 | 16 / 16 / 16 | 15 / 15 / 15 | 2 / 2 | 3 |
| 8 | 16 / 16 / 16 | 15 / 15 / 15 | 2 / 16 | 3 |
| 8 | 16 / 16 / 16 | 15 / 15 / 15 | 16 / 2 | 3 |
| 1 | 16 / 16 / 16 | 15 / 15 / 15 | 2 / 4 | 3 |
| 4 | 8 / 8 / 8 | 7 / 7 / 7 | 4 / 2 | 3 |
| 4 | 12 / 10 / 14 | 9 / 8 / 10 | 4 / 8 | 3 |
| 1 | 4 / 4 / 12 | 0 / 0 / 0 | 2 / 2 | 3 |
| 32 | 16 / 16 / 16 | 15 / 15 / 15 | 4 / 4 | 3 |
| 4 | 8 / 32 / 32 | 0 / 0 / 0 | 4 / 4 | 3 |

The bench configures the filter and enable through AXI4-Lite, rather than forcing
internal control wires. A register-map model checks accepted requests, responses,
byte masks, access rules, read snapshots and side effects. A separate 64-bit FIR
oracle advances only on accepted external input and queues expected values/flags.
Both internal production and external consumption are checked in order. The
bench rejects configurations that would overflow its 62-bit accumulator budget.

Directed cases check signed scaling, impulse order, history across gaps,
zero coefficients, clipping where representable and exact rails. Streaming tests
check 1,050 consecutive outputs and four-clock latency while AXI reads run in
parallel. Control tests check the disable commit edge, disabled drain, preserved
history, same-value coefficient writes clearing history, busy/enabled write
rejection, zero-strobe no-ops and soft clear with a held source and stalled R.

All buffers are filled before reset with AW-only, W-only and simultaneous stalled
B/R states in three separate fixtures. AXI and stream losses from reset are
explicitly accounted. Counter-wrap testing is the sole state-seeding exception:
the bench deposits `0xFFFFFFFE` into both counters and its model, then three real
stream input/output handshakes test wrap through the top's event connections.

Random traffic uses independent reproducible RNGs for stream data/backpressure
and concurrent AXI activity. Control traffic temporarily disables/re-enables,
reads changing status/counters and attempts illegal writes while processing.
Sources hold payloads until acceptance. Assertions check all AXI request/response
stability obligations and blocked stream payloads; occupancy and global idle are
checked against the independent pending-result queue.

Python replays the external `P/C/I/O/R/H` trace independently. Full-top hardware
reset exports `R` followed by zero coefficient `C` events, reflecting that this
top resets coefficient registers as well as history. Invalid writes generate no
arithmetic update; the AXI model separately verifies their error responses.

## Recorded Results

Vivado 2026.1 build 6511674 passed all 47 final runs on 2026-11-15:

- 227,000 accepted random samples and 284,800 total accepted inputs.
- 281,842 completed outputs and saturation flags independently matched Python.
- 2,958 pending samples deliberately discarded by the full-buffer reset fixtures.
- Each configuration reached its exact buffering capacity and produced a
  1,050-cycle continuous output burst with four-clock no-stall latency.
- 26,608 writes committed, 26,561 B responses and 50,073 R responses consumed.
- Reset deliberately discarded 47 AW-only requests, 47 W-only requests, 47 B
  responses and 47 R responses; all channel accounting equations matched.

These totals span reset and soft-clear epochs; software-visible counters follow
their specified reset/wrap behavior instead. See retained
[regression results](../reports/accelerator/regression_results.json) and
[summary/source hashes](../reports/accelerator/summary.json).

Default complete-top OOC synthesis uses 436 LUTs, 303 flip-flops, 8 DSPs and no
BRAM on `xc7a35tcpg236-1`. Internal setup WNS is +0.937 ns and hold slack +0.166 ns
at the 10 ns target. See [timing](../reports/accelerator/timing_synth.rpt) and
[utilization](../reports/accelerator/utilization_synth.rpt) reports.

There are zero unconstrained internal endpoints, but 58 input and 57 output
ports have no external delays. The OOC clock-source warning `Timing 38-242`
remains because no parent clock buffer location is specified. These results are
post-synthesis internal estimates. Final I/O timing assumptions, placement/routing,
post-route closure and the physical-implementation performance comparison remain
pending; a complete 100 MHz implementation has not yet been established.

## Vivado GUI and Synthesis

With the project open, run this in its Tcl Console:

```tcl
source {E:/DSP Accelerator AXI Interface/scripts/configure_accelerator_project.tcl}
```

Design top becomes `dsp_accelerator`, simulation top `tb_dsp_accelerator`. Launch
behavioral simulation, then Run All. GUI defaults run seed 1 with 10,000 accepted
random samples; the PowerShell runner also performs the Python comparison and
the full parameter matrix.

For isolated synthesis of the complete top:

```powershell
New-Item -ItemType Directory -Force build/accelerator_synth | Out-Null
& 'E:/2026.1/Vivado/bin/vivado.bat' -mode batch -nojournal -source ./scripts/synth_accelerator.tcl -log ./build/accelerator_synth/synth.log
```
