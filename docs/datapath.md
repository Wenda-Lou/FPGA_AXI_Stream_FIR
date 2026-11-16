# Buffered FIR Streaming Datapath

`dsp_datapath` connects the verified FIFO and FIR modules into one synchronous
streaming block. Direct configuration ports are ready for the separately verified
[AXI4-Lite register bank](axi_lite_regs.md). Both are now connected and verified
in the [complete accelerator](accelerator.md); its routed module context and
limitations are documented in [implementation](implementation.md).

```text
s_data/valid/ready -> input FIFO -> FIR -> output FIFO -> m_data/valid/ready
                                          payload: {saturation, data}
```

## Sources and Ports

- [dsp_datapath.v](../fpga_streaming_dsp/fpga_streaming_dsp.srcs/sources_1/new/dsp_datapath.v): parameterized Verilog wiring and global control qualification.
- [tb_dsp_datapath.sv](../fpga_streaming_dsp/fpga_streaming_dsp.srcs/sim_1/tb_dsp_datapath.sv): end-to-end scoreboard, protocol assertions, directed and random traffic.
- [run_datapath.ps1](../scripts/run_datapath.ps1): reproducible Xsim regression with independent Python replay.
- [configure_datapath_project.tcl](../scripts/configure_datapath_project.tcl): Vivado source sets and simulation top.
- [synth_datapath.tcl](../scripts/synth_datapath.tcl): isolated-block synthesis and constrained internal setup/hold checks.

The arithmetic parameters match `fir_core`. `INPUT_FIFO_DEPTH` and
`OUTPUT_FIFO_DEPTH` are independent powers of two, at least two, and both default
to 16. The input FIFO stores `DATA_WIDTH` bits; the output FIFO stores
`OUTPUT_WIDTH+1` bits, default 17. Both are non-bypassing FIFOs.

| Port | Contract |
| --- | --- |
| `clk`, `resetn` | Shared rising-edge clock and synchronous active-low reset |
| `s_data`, `s_valid`, `s_ready` | Signed input; advance source only on a handshake |
| `m_data`, `m_valid`, `m_ready` | Signed output; hold both data and flag until accepted |
| `m_saturated` | Clipping metadata for the current valid output; not a sticky flag |
| `enable` | Gate new external input acceptance; internal and output drain remain active |
| `coefficients` | Packed signed tap words, tap zero in the low word |
| `history_clear` | Request accepted only while disabled and globally idle |
| `history_clear_accepted` | Combinational qualification of the request at the active edge |
| `idle` | Both FIFOs empty and both FIR valid stages empty; history may be nonzero |
| `input_occupancy`, `output_occupancy` | FIFO sample counts, excluding FIR pipeline stages |
| `result_saturated` | Event when a clipped FIR result enters the output FIFO |

## Control and Timing

Disabling stops only new external handshakes. Samples already queued at the
input continue through the FIR and output FIFO. A source word offered while
disabled remains unaccepted and must stay valid and stable until re-enabled
and accepted, unless hardware reset cancels it.

Change coefficients only while disabled and globally idle, together with an
accepted history clear. This direct-port block does not reject or buffer illegal
coefficient writes; the register bank enforces those rules in the complete top.
Disable/re-enable without an accepted clear preserves filter history.

An enabled or busy clear pulse is ignored. A request held while disabled allows
all old work to drain, then clears history at an idle edge. Global idle includes
the output FIFO: FIR idle alone does not permit reconfiguration. A held request
can be accepted on multiple consecutive idle edges; use a one-cycle request for
a single command. Clear preserves coefficients and never discards accepted work.

Hardware reset invalidates both FIFOs and FIR stages and zeroes sample history.
External coefficients survive this block's reset; the register bank owns
resetting coefficient registers. FIFO memory and invalid output payloads need
not be zero. Interpret data and `m_saturated` only when `m_valid` is asserted.

`result_saturated` is asserted for each clipped FIR-to-output-FIFO handshake,
which can precede external consumption by many cycles. A blocked FIR result
does not repeatedly generate this event. The register bank's sticky `SATURATED`
state connects to this event in `dsp_accelerator` and clears on hardware reset
or a legal soft clear.

Without stalls, external handshake latency is four clocks: one input FIFO clock,
two FIR clocks and one output FIFO clock. Steady throughput is one result per
clock. Total capacity is `INPUT_FIFO_DEPTH + OUTPUT_FIFO_DEPTH + 2` accepted but
unconsumed samples, default 34. Backpressure can extend latency indefinitely;
draining requires the receiver eventually to assert ready.

## Reproduction

Run from the repository root, adapting tool locations to your installation:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ./scripts/run_datapath.ps1 -VivadoBin 'E:/2026.1/Vivado/bin' -Python 'H:/2025.1/tps/win64/python-3.13.0/python.exe'
```

Default traffic is 20 seeds of 10,000 accepted random samples for the default
configuration, plus seeds 1, 7 and 42 of 1,000 samples for seven smoke cases.
`-Seeds`, `-Samples`, `-SmokeSamples` and `-SkipSmoke` select a shorter run.
Generated logs, event exports, Python summaries and source hashes are under
`build/datapath_sim/`. The runner requires both a testbench PASS and successful
Python comparison with matching configurations and transaction counts.

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

Each run checks signed arithmetic, negative floor shifting, zero coefficients,
impulse ordering across gaps, both clipping directions where representable,
data/flag stability under backpressure and a 1,050-cycle continuous output burst.
It fills both FIFOs and both FIR stages, disables with an unaccepted input held,
drains while disabled, rejects busy/enabled clears, accepts a held disabled clear
after global drain, reconfigures coefficients and resets all full buffers.

The scoreboard checks every external result and every FIR production against
64-bit integer arithmetic, with a startup guard against oracle overflow. It also
checks global idle and conservation against both FIFO occupancies plus the two
FIR valid bits. Assertions enforce stable source/output payloads while blocked.
Python independently replays the external `P/C/I/O/R/H` trace using `FirModel`.

## Recorded Results

Vivado 2026.1 build 6511674 passed all 41 final simulations on 2026-11-15:

- 221,000 accepted random inputs, plus directed traffic.
- 271,559 total accepted inputs; 270,633 outputs and their flags matched Python.
- 926 pending samples were intentionally discarded by full-buffer hardware resets.
- Every run produced 1,050 consecutive outputs and checked four-clock latency
  during the no-stall phase.
- Every configuration reached its full FIFO-plus-pipeline capacity; the default
  configuration held 34 pending samples.

Retained evidence is the [regression record](../reports/datapath/regression_results.json)
and [summary with source hashes](../reports/datapath/summary.json). Generated
per-run traces/logs remain under `build/datapath_sim/` and can be reproduced.

Default out-of-context synthesis for `xc7a35tcpg236-1` used 319 LUTs, 45 flip-flops,
8 DSPs and no BRAM. The LUT count includes 24 distributed-memory LUTs for the
FIFOs. Setup WNS is +0.937 ns, setup TNS is zero and hold slack is +0.166 ns at
the 10 ns internal clock target. Retained [timing](../reports/datapath/timing_synth.rpt)
and [utilization](../reports/datapath/utilization_synth.rpt) reports describe the
default configuration only.

The wrapper preserves the FIR instance hierarchy with `keep_hierarchy="yes"`
so synthesis retains its independently optimized arithmetic structure. This does
not add registers or change cycle behavior; the final annotated RTL, including
this attribute, was used in all 41 recorded simulation runs.

The timing report has zero unconstrained internal endpoints, but 149 input ports
and 32 output ports have no external delays. Vivado also reports `Timing 38-242`
because an OOC clock-buffer source location is unspecified. These are explicit
scope limitations of the internal estimate. AXI4-Lite integration is verified
in the complete top. Its [separate physical result](implementation.md) supplies
interface budgets and routed module acceptance under a stated parent context.

## Vivado GUI and Synthesis

In the open Vivado project's Tcl Console:

```tcl
source {E:/DSP Accelerator AXI Interface/scripts/configure_datapath_project.tcl}
```

Design top becomes `dsp_datapath`; simulation top becomes `tb_dsp_datapath`.
Launch behavioral simulation, then Run All. GUI simulation alone does not invoke
the independent Python replay; use the PowerShell runner for the complete check.

For the isolated synthesis check:

```powershell
New-Item -ItemType Directory -Force build/datapath_synth | Out-Null
& 'E:/2026.1/Vivado/bin/vivado.bat' -mode batch -nojournal -source ./scripts/synth_datapath.tcl -log ./build/datapath_synth/synth.log
```

The reused clock XDC sets a 10 ns target on `clk`. No external I/O timing is
defined at this stage, and placement/routing have not been run. Synthesized
internal slack is an estimate, not full-system timing acceptance or proven Fmax.
