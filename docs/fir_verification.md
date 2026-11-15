# FIR Core: Interface, Verification and Synthesis

Status: the standalone FIR module is complete for the acceptance configurations
below. Parameterized Verilog RTL, control/status ports, self-checking simulation,
independent Python comparison and default-configuration synthesis are complete.
Buffered FIFO/FIR integration is verified separately in the
[datapath report](datapath.md). The [register bank](axi_lite_regs.md) is verified
separately; full AXI-controlled streaming integration is verified in the
[complete accelerator](accelerator.md). Physical implementation remains pending.

## Files and Reproduction

- [fir_core.v](../fpga_streaming_dsp/fpga_streaming_dsp.srcs/sources_1/new/fir_core.v): two-stage signed fixed-point datapath.
- [tb_fir_core.sv](../fpga_streaming_dsp/fpga_streaming_dsp.srcs/sim_1/tb_fir_core.sv): directed tests, assertions, scoreboard and randomized traffic.
- [run_fir.ps1](../scripts/run_fir.ps1): simulation matrix and Python comparison.
- [compare_fir_events.py](../scripts/compare_fir_events.py): independent event replay through `FirModel`.
- [synth_fir.tcl](../scripts/synth_fir.tcl) and [clock constraint](../constraints/fir_core_ooc.xdc): standalone synthesis and internal timing checks.

Detailed English comments explain the RTL, testbench and reproduction scripts.
The original [baseline snapshot](../reports/fir_core/baseline_rtl.txt) remains
unchanged; its [annotated reading copy](../reports/fir_core/baseline_rtl_annotated.txt)
explains the earlier linear-sum implementation and is not a project source.
Existing regression/synthesis reports retain their tested, pre-comment byte hashes.
[Comment provenance](../reports/fir_core/comment_provenance.json) maps those sources
to the annotated versions and records that all non-comment code lines are identical.

From the repository root:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ./scripts/run_fir.ps1 -VivadoBin 'E:/2026.1/Vivado/bin' -Python 'H:/2025.1/tps/win64/python-3.13.0/python.exe'
```

Use your installed tool paths if different. Defaults run 20 seeds of 10,000
accepted random inputs for the required configuration and three seeds of 1,000
inputs for each smoke configuration. `-Seeds`, `-Samples`, `-SmokeSamples` and
`-SkipSmoke` permit shorter runs. Logs, events and Python summaries are generated
under `build/fir_sim/`. `results.json` records metrics and source hashes.

For synthesis:

```powershell
New-Item -ItemType Directory -Force build/fir_synth | Out-Null
& 'E:/2026.1/Vivado/bin/vivado.bat' -mode batch -nojournal -source ./scripts/synth_fir.tcl -log ./build/fir_synth/synth.log
```

The synthesis script fails on missing or negative constrained internal setup/hold
paths. It writes reports and a checkpoint under `build/fir_synth/`.

## Parameters and Numerical Rules

| Parameter | Default | Contract |
| --- | --- | --- |
| `DATA_WIDTH` | 16 | Signed input width, 2 through 32 bits |
| `COEFF_WIDTH` | 16 | Signed coefficient width, 2 through 32 bits |
| `OUTPUT_WIDTH` | DATA_WIDTH | Signed output width, 2 through 32 bits |
| `TAPS` | 8 | Power of two in 1 through 32 |
| `INPUT_FRAC_BITS` | DATA_WIDTH - 1 | Input fractional bits, 0 through DATA_WIDTH - 1 |
| `COEFF_FRAC_BITS` | COEFF_WIDTH - 1 | Coefficient fractional bits, 0 through COEFF_WIDTH - 1 |
| `OUTPUT_FRAC_BITS` | OUTPUT_WIDTH - 1 | Output fractional bits, 0 through OUTPUT_WIDTH - 1 |

The output shift `INPUT_FRAC_BITS + COEFF_FRAC_BITS - OUTPUT_FRAC_BITS` must be
nonnegative. Products retain `DATA_WIDTH + COEFF_WIDTH` bits. The accumulator and
every adder-tree node retain an additional `$clog2(TAPS)` bits. The accumulator is
sign-extended when the output format is wider, then arithmetically shifted,
rounding toward negative infinity. The shifted value is saturated before output
narrowing. Exact representable rail values do not count as saturation.

Tap 0 is the least-significant `COEFF_WIDTH` bits of the coefficient input and
multiplies the newest accepted sample. The remaining products use previous
accepted samples; clock gaps do not insert zeros. The default is signed Q1.15.
The pipeline uses registered products followed by full-width balanced addition,
shifting/saturation and a registered output. No extra FIR-tail outputs are emitted.

## Control and Streaming Contract

All state uses a single rising-edge clock and active-low synchronous reset.
Ready/valid transfers occur only on rising edges outside reset. The core globally
stalls when its output is valid and the receiver is not ready.

| Signal | Behavior |
| --- | --- |
| `idle` | High exactly when both pipeline valid stages are empty; nonzero sample history alone does not make the core busy |
| `history_clear` | Suppresses new input acceptance while high; history is cleared on a rising edge with `idle = 1` |
| Busy clear pulse | Blocks inputs for that cycle but preserves history and pending results; clearing is ignored while busy |
| Held clear request | Pending results continue to drain; history clears after idle is reached and the request is still asserted |
| Coefficients | External packed input; change only while idle with `history_clear` asserted |
| `m_saturated` | Valid with `m_valid`; true exactly when that output was clipped; held with output data during backpressure |

An idle clear preserves coefficients, generates no output and accepts no input on
its clear edge. An upstream source presenting a sample during clear must hold it
until a later handshake or reset. Hardware reset discards pending results and
clears history/valid flags and output saturation; external coefficients retain
their externally driven values. Data and saturation status are ignored while
`m_valid = 0`.

For coefficient replacement, stop ingress, drain the pipeline, update the packed
coefficients while asserting `history_clear` through a rising edge, then release
clear and resume ingress. In the full accelerator this must use global IDLE,
including both FIFOs. The core-level `idle` signal alone does not describe FIFO
occupancy. Output FIFO integration must enqueue `{m_saturated, m_data}` together
to preserve their association under stalls.

## Verification Method and Results

Vivado Simulator 2026.1 passed all 38 acceptance runs:

| Taps | Input / coefficient / output bits | Fractional bits I / C / O | Seeds | Random inputs per seed |
| --- | --- | --- | --- | --- |
| 8 | 16 / 16 / 16 | 15 / 15 / 15 | 1 through 20 | 10,000 |
| 1 | 16 / 16 / 16 | 15 / 15 / 15 | 1, 7, 42 | 1,000 |
| 4 | 16 / 16 / 16 | 15 / 15 / 15 | 1, 7, 42 | 1,000 |
| 4 | 8 / 8 / 8 | 7 / 7 / 7 | 1, 7, 42 | 1,000 |
| 4 | 12 / 10 / 14 | 9 / 8 / 10 | 1, 7, 42 | 1,000 |
| 4 | 8 / 8 / 16 | 0 / 0 / 0 | 1, 7, 42 | 1,000 |
| 1 | 4 / 4 / 12 | 0 / 0 / 0 | 1, 7, 42 | 1,000 |

The suite accepted 218,000 random inputs, plus directed traffic. All 263,938
completed outputs and saturation flags matched Python. Total accepted inputs
were 264,014; 76 results were deliberately discarded by hardware resets. There
were no assertion failures or scoreboard mismatches. Every run demonstrated
1,050 consecutive output transfers and two-cycle input-to-output handshake
latency without stalls.

Directed coverage includes signed shifting, zero coefficients, all impulse taps,
positive/negative saturation when mathematically reachable, full accumulator
precision, natural rail values versus clipped values, output/data-flag hold,
idle with nonzero history, idle clears, coefficient replacement without reset,
clear coincident with a deferred input, ignored busy pulses, a held clear that
drains before clearing, and hardware reset while input/output are blocked.

The driver changes inputs on falling edges and preserves blocked payloads. A
queue scoreboard observes ports only, using a separate 64-bit behavioral model.
Assertions check source and output stability. Python independently replays actual
accepted transactions and checks data, saturation flags and conservation:

```text
accepted inputs = accepted outputs + results discarded by hardware reset
```

Exports start with `P taps input_width coeff_width output_width input_frac
coeff_frac output_frac`, then contain `C index signed_coefficient`, `I sample`,
`O result saturated`, `R` for a core reset edge and `H` for an accepted idle clear.
Busy clear requests produce no `H` event. Resets/clears preserve external
coefficients. Old fixed-format event files remain readable by the comparator.

All 27 Python model/vector/event tests passed. Negative HDL checks reject
non-power-of-two taps and negative shift configurations. The acceptance matrix
is explicit; other legal combinations have not been exhaustively tested. The
SystemVerilog behavioral oracle supports at most 62 accumulator bits; the RTL
uses its parameter-derived width and Python uses arbitrary-precision integers.

See [regression results](../reports/fir_core/regression_results.json) for all
counts and exact source hashes.

## Synthesis and Timing Optimization

Default configuration, `xc7a35tcpg236-1`, Vivado 2026.1 build 6511674, 10 ns clock,
out-of-context synthesis, identical constraints and synthesis settings:

| Metric | Linear accumulation baseline | Balanced fabric adder tree |
| --- | --- | --- |
| Setup WNS | -5.319 ns | +0.937 ns |
| Setup TNS | -90.418 ns | 0.000 ns |
| Hold slack | +0.282 ns | +0.339 ns |
| LUTs | 48 | 265 |
| Slice flip-flops | 99 | 19 |
| DSP48E1 blocks | 8 | 8 |
| BRAM tiles | 0 | 0 |
| Handshake latency without stalls | 2 cycles | 2 cycles |
| Steady-state throughput | 1 result/cycle | 1 result/cycle |

The baseline mapped to a long combinational DSP cascade. The final RTL uses a
full-width balanced adder tree with signal-level `use_dsp = "no"` on adder nodes,
while multiplication continues to use eight DSPs. This trades LUTs for a
6.256 ns improvement in synthesized setup slack. Slice register counts exclude
registers absorbed into DSP blocks. The attribute is described in
[AMD's USE_DSP documentation](https://docs.amd.com/r/en-US/ug901-vivado-synthesis/USE_DSP).

Baseline and optimized RTL both passed the same 38-run suite. Retained evidence:

- [Optimized utilization](../reports/fir_core/utilization_synth.rpt) and [timing](../reports/fir_core/timing_synth.rpt).
- [Machine-readable comparison](../reports/fir_core/synthesis_comparison.json).
- [Baseline RTL snapshot](../reports/fir_core/baseline_rtl.txt), [regression](../reports/fir_core/baseline_regression_results.json), [utilization](../reports/fir_core/baseline_utilization_synth.rpt) and [timing](../reports/fir_core/baseline_timing_synth.rpt).

These are post-synthesis internal timing estimates. The timing report lists
148 input and 20 output bits without external delay constraints, and emits
`Timing 38-242` because the standalone clock-buffer location is unspecified.
Placement/routing, top-level I/O timing and board behavior remain integration
work; no measured maximum clock frequency is claimed.

## Vivado GUI

With the project open, synchronize sources, the FIR clock constraint and tops:

```tcl
source {E:/DSP Accelerator AXI Interface/scripts/configure_fir_project.tcl}
```

Launch behavioral simulation and use Run All. GUI defaults run seed 1 with
10,000 accepted random inputs and write event output in the simulator's working
directory. The command-line runner performs the complete matrix and independent
Python comparison.
