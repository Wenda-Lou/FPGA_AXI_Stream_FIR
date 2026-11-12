# Development and Validation

## Current Implementation

- Integer FIR reference model: implemented.
- Model tests and deterministic vector-file generation: implemented.
- Parameterized Verilog FIFO and SystemVerilog self-checking testbench: implemented.
- FIFO regression: 32 runs passed in Vivado 2026.1; default out-of-context synthesis passed.
- Fixed 8-tap, 16-bit FIR RTL and self-checking testbench: three seeds passed, with independent Python comparison of 33,501 outputs.
- FIR parameterization/control extensions, AXI4-Lite integration, full implementation and timing closure: pending.

The proposal's full-project success criteria remain future milestones.

## Run the Reference Flow

Use Python 3.10 or newer. No third-party Python packages are required. Run these
commands from the repository root:

```powershell
python -m unittest discover -s tests -v
python scripts/generate_vectors.py --seed 1 --count 10000
```

The PowerShell wrapper runs both steps, stops on failure, and accepts an explicit
Python executable:

```powershell
./scripts/run_reference.ps1 -Python python -Seed 1 -Count 10000
```

On the initial development machine, the working interpreter discovered on
November 11, 2026 was `H:/2025.1/tps/win64/python-3.13.0/python.exe` (Python
3.13.0). The WindowsApps `python` and `py` aliases could not start an interpreter.
For that machine:

```powershell
./scripts/run_reference.ps1 -Python 'H:/2025.1/tps/win64/python-3.13.0/python.exe'
```

The initial machine's PowerShell execution policy blocks direct `.ps1` execution.
Use the direct Python commands above with the interpreter's full path, or run
the checked-in wrapper in a child process with a process-only execution policy:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ./scripts/run_reference.ps1 -Python 'H:/2025.1/tps/win64/python-3.13.0/python.exe'
```

This command leaves the user's persistent execution-policy settings unchanged.
The initial reference run passed all 21 tests and generated the five scenarios
with seed 1 and 10,000 random samples. This records Python-flow validation only.

Vivado 2026.1 is now installed at `E:/2026.1/Vivado`; its simulator has been
verified with the FIFO regression below. The earlier AMD installation at
`H:/2025.1` supplies the Python interpreter. Full accelerator synthesis,
implementation and timing validation for `xc7a35tcpg236-1` remain pending.

## Run the FIFO Simulation

The DUT is the user-authored Verilog file at
`fpga_streaming_dsp/fpga_streaming_dsp.srcs/sources_1/new/axis_fifo.v`.
The single authoritative SystemVerilog testbench is
[tb_axis_fifo.sv](../fpga_streaming_dsp/fpga_streaming_dsp.srcs/sim_1/tb_axis_fifo.sv).
From the repository root, run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ./scripts/run_fifo.ps1 -VivadoBin 'E:/2026.1/Vivado/bin'
```

Use the `bin` directory of your own Vivado installation if different. The runner
compiles Verilog and SystemVerilog separately and elaborates each configuration.
The required 16-bit/depth-16 build runs seeds 1 through 20 with 10,000 accepted
random inputs per seed. Four additional configurations each run seeds 1, 7 and
42 with 1,000 accepted random inputs. It returns failure on tool errors,
fatal/error messages, a missing PASS marker, or mismatched result parameters. Logs,
waveform databases and simulation executables are generated under
`build/fifo_sim/`, which is excluded from Git. `results.json` records the run
metrics and SHA-256 hashes of the exact RTL and testbench tested. The script's
`-Samples`, `-Seeds`, `-SmokeSamples` and `-SkipSmoke` options allow shorter runs;
the default invocation runs the complete FIFO regression.

The scoreboard queues only accepted inputs and compares only accepted outputs.
It checks occupancy, ready/valid behavior, full and empty boundaries, output
stability under backpressure, repeated pointer wraparound, simultaneous reads
and writes, and reset with queued data. Input stimuli hold valid and data stable
while blocked. Reset deliberately discards queued expectations. SystemVerilog
assertions check source/output stability and legal occupancy. A directed case
requires 1,024 consecutive simultaneous input/output transfers.

The completed FIFO regression passed all 32 runs:

| Data width | Depth | Seeds | Accepted random inputs per seed |
| --- | --- | --- | --- |
| 16 | 16 | 1 through 20 | 10,000 |
| 16 | 2 | 1, 7, 42 | 1,000 |
| 16 | 4 | 1, 7, 42 | 1,000 |
| 8 | 4 | 1, 7, 42 | 1,000 |
| 32 | 16 | 1, 7, 42 | 1,000 |

This totals 212,000 accepted random inputs, in addition to directed traffic.
The run summaries' write/read totals also include directed tests and final drain.
All tested configurations sustain at least 1,024 consecutive simultaneous
transfers. The complete accelerator regression remains future work.

For an already-open Vivado GUI, run the following in its Tcl Console to synchronize
the file list, remove references to deleted sample exercises and select the
canonical testbench:

```tcl
source {E:/DSP Accelerator AXI Interface/scripts/configure_fifo_project.tcl}
```

Adjust the absolute path for a different checkout. This helper was verified in
an in-memory Vivado project. Then run behavioral simulation followed by Run All.
Default GUI simulation uses seed 1 and 10,000 accepted random inputs. Observe the
DUT ports and set the data/occupancy radix as appropriate. The duplicate
`tb/tb_axis_fifo.sv` has been removed.

## Run the FIFO Synthesis Check

From the repository root:

```powershell
New-Item -ItemType Directory -Force build/fifo_synth | Out-Null
& 'E:/2026.1/Vivado/bin/vivado.bat' -mode batch -nojournal -source ./scripts/synth_fifo.tcl -log ./build/fifo_synth/synth.log
```

This synthesizes the default FIFO out of context for `xc7a35tcpg236-1` and writes
resource/timing reports and a checkpoint under `build/fifo_synth/`. The measured
result uses 26 LUTs, 13 flip-flops, zero BRAM and zero DSP blocks. Standalone
synthesis and its clock-only timing estimate cover the FIFO; post-route timing
and top-level I/O constraints remain integration work.

See [FIFO design and results](axis_fifo.md) for the interface contract, test
coverage, timing-report limitations and retained evidence.

## Run the FIR Simulation

The self-checking FIR testbench and its Python comparison can be run with:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ./scripts/run_fir.ps1 -VivadoBin 'E:/2026.1/Vivado/bin' -Python 'H:/2025.1/tps/win64/python-3.13.0/python.exe'
```

The default suite runs seeds 1, 7 and 42 with 10,000 accepted random inputs each,
plus directed arithmetic, throughput, backpressure and mid-traffic reset tests.
See [FIR verification](fir_verification.md) for the fixed-core interface, event
format, measured results and Vivado GUI configuration.

## Generated Files

Generated outputs are ignored by Git and default to `build/vectors/`. Each run
writes `manifest.json` with numeric parameters, seed and per-scenario sample and
saturation counts. Each scenario has:

| File | Meaning |
| --- | --- |
| `coefficients.mem` | Eight coefficients in tap order, one 16-bit hexadecimal bus word per line |
| `input.mem` | Accepted input sequence, one 16-bit hexadecimal word per line |
| `expected.mem` | Expected output sequence in the same hexadecimal format |
| `saturated.mem` | One `0` or `1` per expected output, for checking the clipping flag |

The scenarios are impulse, signed extrema, positive saturation, negative
saturation, and seeded random traffic. `--count` controls only the random
scenario; directed scenarios retain fixed lengths. Every input has exactly one
expected output. No implicit zero padding or extra FIR-tail results are emitted.

These are sample sequences, not cycle schedules. Random cycle gaps, backpressure,
mid-traffic reset and configuration timing will be introduced by the HDL driver.
Generating 10,000 reference samples is not an RTL regression result.

The model tests use hand-calculated impulse, sign, shift, saturation and full-width
accumulation cases. Vector tests check hexadecimal output, file lengths,
manifest consistency and seed reproducibility.
