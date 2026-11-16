# Delivery and Reproduction

The delivered scope is the documented parameterized accelerator, verification
environment, routed module acceptance and controlled physical optimization
comparison. Physical-board validation and acceptance in a different parent
design are outside the original first-version scope.

## Complete Acceptance Entry Point

From a checkout/export with no generated `build/` directory:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ./scripts/run_release.ps1 -VivadoBin 'E:/2026.1/Vivado/bin' -Python 'H:/2025.1/tps/win64/python-3.13.0/python.exe'
```

Use a working Python 3.10+ and a Vivado 2026.1 installation with Artix-7 device
support. Tested executables are shown; adapt paths for another workstation.
No third-party Python packages or development board are required. Vivado can
write its normal per-user caches outside the checkout; generated project data
stays in `build/`.

The default acceptance budget is:

| Phase | Required runs |
| --- | ---: |
| Python model/vector/event tests | 27 tests |
| FIFO | 32 HDL runs |
| FIR | 38 HDL runs |
| Buffered datapath | 41 HDL runs |
| AXI4-Lite registers | 32 HDL runs |
| Complete accelerator | 47 HDL runs |
| Baseline / optimized integrated comparison | 47 + 47 HDL runs |
| Supplemental waveform capture | 1 HDL run |
| Total HDL simulations, including repeated comparison verification | 285 |

Two module implementations run during the comparison. They use the identical
Tcl/XDC flow. Baseline setup failure is an expected *failed baseline result*,
not a passing implementation; hold, timing coverage and internal routing still
must pass. The optimized build must meet the 100 MHz module timing contract.

The runner freezes code/constraint hashes before starting, captures each phase's
exit status and logs, and stops on failure. The final verifier checks unchanged
sources, all matrix sizes, actual simulator PASS evidence, accepted-data
conservation, integrated Python comparison, both physical builds, and waveform
source/artifact hashes. It archives results only after every required check.

## Clean Export Procedure

For the delivery check, the candidate Git tree is exported into a new directory
under the ignored `build/release_validation/` tree. It has no `.git`, `build/`,
simulator snapshots or checkpoints. A `clean_export.json` marker records the
exported Git tree and confirms that generated artifacts were initially absent.
The complete entry point is then run inside that export. This tests dependence
on checked-in files rather than previous workspace products; it does not claim
a second workstation or a different tool installation.

The resulting `reports/release/summary.json` records the executed source hashes,
285 simulations, physical margins, phase exit codes and the clean-export tree.
The main checkout retains the exported run's release evidence under
`reports/release/`; reproduction commands generate independent evidence for a
new run. The final documentation/report additions can follow the tested source
tree; source hashes identify the exact code that was exercised.

Sources and reports contain byte-level hashes. `.gitattributes` preserves their
exact existing bytes, including LF/CRLF endings, so Git cannot silently alter
tested inputs or archived evidence. New files are authored with UTF-8/LF.
Historical reports remain historical; they are not rewritten with new timing
or functional metrics.

## Handoff Checklist

- Results-first README with default configuration, numerical rules, register map,
  measured performance, reproduction commands and explicit scope.
- Architecture SVG plus real-VCD streaming, backpressure and control examples.
- Full RTL/bench/Python sources and versioned XDC/Tcl/PowerShell flows.
- Recorded directed/random matrices, reset-discard accounting, Python comparisons,
  and baseline/optimized post-route timing/resource evidence.
- Clean-export acceptance report with exact input hashes and phase logs.

The retained `Constraints 18-8777` warning has an unconfirmed cause. Raw OOC
parent-boundary routes remain incomplete by construction, although every
functional partition anchor and internal route is audited. Read
[implementation scope and warnings](implementation.md) before reuse.
Neither a gate-level timing simulation nor a frequency sweep was performed.
