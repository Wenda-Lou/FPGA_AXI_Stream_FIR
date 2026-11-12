# Development and Validation

## Current Implementation

- Integer FIR reference model: implemented.
- Model tests and deterministic vector-file generation: implemented.
- RTL, HDL simulation, AXI4-Lite integration and synthesis: pending.

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

Vivado and an HDL simulator were not found on PATH. The AMD installation at
`H:/2025.1` includes Vitis tools, but an HDL simulation/synthesis toolchain and
support for `xc7a35tcpg236-1` have not been confirmed. This does not prevent
running the Python reference flow.

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
