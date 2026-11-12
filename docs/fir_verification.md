# FIR Core Verification

The self-checking testbench targets the current fixed 8-tap, 16-bit signed FIR. RTL is
Verilog and the testbench is SystemVerilog. The DUT has no width/tap parameters;
its eight coefficients are packed into one 128-bit input, with tap 0 in bits
15:0. Coefficients are held constant during processing and changed while reset
is asserted between test cases.

## Files and Execution

- [fir_core.v](../fpga_streaming_dsp/fpga_streaming_dsp.srcs/sources_1/new/fir_core.v): current user-authored RTL.
- [tb_fir_core.sv](../fpga_streaming_dsp/fpga_streaming_dsp.srcs/sim_1/tb_fir_core.sv): directed tests, assertions and randomized traffic.
- [run_fir.ps1](../scripts/run_fir.ps1): compilation, simulation and Python comparison.
- [compare_fir_events.py](../scripts/compare_fir_events.py): independent replay through the existing Python reference model.

From the repository root, run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ./scripts/run_fir.ps1 -VivadoBin 'E:/2026.1/Vivado/bin' -Python 'H:/2025.1/tps/win64/python-3.13.0/python.exe'
```

Use the paths of your own Vivado installation and Python interpreter if different.
Defaults are seeds 1, 7 and 42, each with 10,000 accepted random inputs. `-Seeds`
and `-Samples` allow shorter runs. Generated logs, event exports, Python summaries
and the aggregate `results.json` are placed under `build/fir_sim/`.

The runner rejects tool errors, fatal/error messages, missing PASS markers and
disagreement between SystemVerilog and Python transfer counts. SHA-256 hashes
identify the tested RTL, testbench and Python model.

## Verification Method

The driver changes inputs on falling clock edges and preserves valid/data while
blocked. A scoreboard observes rising-edge handshakes and computes expected
results using a behavioral 64-bit signed model. No DUT internal registers are
read by the scoreboard. Assertions check input/output stability under stalls.

The DUT's products have 30 fractional bits; an arithmetic shift of 15 gives the
output's 15 fractional bits, rounding toward negative infinity. Saturation is
applied before narrowing the result to 16 bits. Directed hand-calculated cases
check these rules in addition to the scoreboard.

The event file records external coefficient values (`C index signed_value`),
accepted inputs (`I signed_value`), accepted outputs (`O signed_value`) and core
reset edges (`R`). Python independently rebuilds the expected sequence with
`FirModel`. A reset clears sample history and pending expectations while retaining
the external coefficient inputs. This is the core-level reset boundary; the
future AXI4-Lite coefficient registers have their own reset behavior.

After traffic stops, the test drains the pipeline and checks for delayed duplicate
outputs. Final accounting requires accepted inputs to equal accepted outputs plus
results explicitly discarded by reset.

## Passed Cases and Results

Vivado Simulator 2026.1 passed all three seeds:

| Seed | Accepted random inputs | Total inputs | Matched outputs | Reset-discarded results | Longest consecutive output transfers |
| --- | --- | --- | --- | --- | --- |
| 1 | 10,000 | 11,169 | 11,167 | 2 | 1,050 |
| 7 | 10,000 | 11,169 | 11,167 | 2 | 1,050 |
| 42 | 10,000 | 11,169 | 11,167 | 2 | 1,050 |

All 33,501 outputs also matched the Python reference. Counts include directed
tests; the randomized phase contributes 30,000 accepted inputs in total.

Required directed cases cover:

- Half-gain coefficient: raw input 10,000 produces raw output 5,000.
- Negative fractional shifting, signed extrema, and zero coefficients.
- All eight impulse-response taps, with gaps that preserve sample history.
- Positive/negative saturation and an accumulator sum exceeding 32 bits.
- Continuous streaming at one output per cycle and two-cycle handshake latency.
- Reset while both pipeline stages contain data and a further input is blocked.
- Cleared history after reset and no stale pre-reset output.
- Seeded full-range coefficients/samples, input gaps, random output readiness and
  periodic long output stalls.

In the no-stall latency test, an output handshake occurs on the second rising
edge after the corresponding input handshake. One result becomes available per
cycle after pipeline fill. A separate negative check modified an exported output
and confirmed that the Python comparator rejected it.

The retained [run results](../reports/fir_core/regression_results.json) contain
per-seed counts and source hashes. The FIR remains fixed at eight taps and 16-bit
formats. Parameterization, idle/history-clear/clipping-status interfaces, FIR
synthesis and FIFO integration remain separate milestones.

## Vivado GUI

The project file selects `fir_core` for design and `tb_fir_core` for simulation.
If the GUI was already open while sources changed, run this in its Tcl Console:

```tcl
source {E:/DSP Accelerator AXI Interface/scripts/configure_fir_project.tcl}
```

Then launch behavioral simulation and use Run All. GUI defaults run seed 1 with
10,000 accepted random inputs. Event output is written in the GUI simulator's
working directory. The command-line runner performs the additional independent
Python comparison.
