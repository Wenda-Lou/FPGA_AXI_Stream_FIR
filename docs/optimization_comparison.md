# Full-Top Physical Optimization Comparison

This comparison measures the complete `dsp_accelerator`, including both FIFOs,
the FIR and AXI4-Lite register bank. It uses post-route reports for both builds;
the earlier standalone FIR synthesis comparison remains historical evidence.

## Controlled Variants

The baseline reconstructs the full-precision linear accumulation loop from
`reports/fir_core/baseline_rtl.txt` inside the current FIR shell. The optimized
variant is the canonical FIR with its balanced fabric adder tree. Baseline
adders retain the original freedom to map into DSP or fabric; no artificial
`KEEP` or `DONT_TOUCH` attribute is added to degrade the baseline.

Only the sum structure and the optimized tree's `use_dsp="no"` mapping hint
differ. Both variants retain the same history-depth correction, parameter
guards, registered products, output register, scaling, saturation, valid/ready,
clear and reset logic. This is a controlled reconstruction, not a claim that
the baseline is a byte-identical historical checkout. Full source snapshots
and SHA-256 manifests are retained with the comparison.

The other four RTL modules, testbench, Python oracle, regression runner,
implementation Tcl and both XDC files are byte-identical. Canonical RTL and
the previous accepted implementation reports are not overwritten.

## Common Build Conditions

- Part: `xc7a35tcpg236-1`; default eight taps, signed 16-bit Q1.15 data and
  coefficients, 16-bit output, two 16-deep FIFOs.
- One 10 ns clock and aligned 10 ns virtual interface clock; input arrival
  0.5–2.0 ns, output delay -0.5–2.0 ns, setup/hold uncertainty 0.100/0.050 ns.
- The same OOC physical context: `BUFGCTRL_X0Y0`, partition region
  `SLICE_X0Y0:SLICE_X65Y99`, whole-device contained Pblock.
- Identical synthesis, optimization, placement and routing Tcl; two tool
  threads, no placement-seed override, the same Vivado defaults/directives.
- The same adaptive input-hold repair rule: up to five iterations, identity
  LUT1 cells only, with fresh placement/routing and measured timing each time.
  Different repair counts are reported rather than forced to be equal.
- One physical run per variant. This establishes this build's comparison,
  without claiming a distribution across placement seeds or a measured Fmax.

The timing contract and OOC boundary interpretation are documented in
[implementation.md](implementation.md).

## Measured Result

Vivado 2026.1 build 6511674, recorded on 2026-11-16. Both measurements are from
saved routed checkpoints reopened by the same implementation script.

| Metric | Linear accumulation baseline | Balanced fabric tree |
| --- | ---: | ---: |
| Target clock period | 10 ns | 10 ns |
| 100 MHz module timing | Fails setup | Passes setup and hold |
| Post-route setup WNS | -5.595 ns | +0.273 ns |
| Setup TNS | -435.890 ns | 0 ns |
| Setup failing endpoints | 389 | 0 |
| Worst hold slack | +0.034 ns | +0.031 ns |
| Hold failing endpoints | 0 | 0 |
| Worst pulse-width slack | +3.750 ns | +3.750 ns |
| Slice LUTs | 724 | 1,043 |
| Slice flip-flops | 383 | 463 |
| DSP48E1 blocks | 8 | 8 |
| BRAM tiles | 0 | 0 |
| Audited hold-repair LUT1 cells, included above | 709 | 722 |
| Missing clocks/I/O delays/unconstrained internal endpoints | 0 | 0 |
| Audited functional physical interface anchors | 115/115 | 115/115 |
| Unexpected internal routing errors | 0 | 0 |
| Functional regression runs | 47 passed | 47 passed |
| Consecutive no-stall outputs, minimum per run | 1,050 | 1,050 |
| Core / full-top no-stall latency | 2 / 4 clocks | 2 / 4 clocks |
| Steady-state functional throughput | 1 output/clock | 1 output/clock |

Setup slack improves by **5.868 ns** at a cost of **319 LUTs (+44.1%)** and
**80 slice flip-flops**. DSP use, pipeline latency and functional throughput
remain unchanged. The baseline's one-output-per-clock simulation result does
not establish operation at 100 MHz: its physical timing fails at that frequency.

Each functional suite accepted 227,000 random inputs plus directed traffic,
284,800 inputs in total. All 281,842 completed outputs and saturation flags
matched Python; 2,958 inputs were deliberately discarded by reset fixtures.
All 47 accepted-event traces are byte-identical between variants, including
configuration, clear and reset events. The unchanged bench checks four-clock
external latency during continuous traffic; no new pipeline cycle is added.

The baseline's worst path runs from `datapath/core/scaled0/CLK` to
`datapath/core/out_data_reg[10]/D` through a long DSP48E1 cascade, with a
15.349 ns data-path delay. The optimized build's worst setup path has a
9.489 ns data-path delay through fabric arithmetic. Its endpoints and mapped
logic are retained in the summary and detailed timing reports. Vivado counts
11 mapped logic levels for the baseline path and 17 for the optimized path:
these mix different primitive types and are not interchangeable delay units.
The timing improvement is established by measured delay/slack, not a claim
that the mapped primitive count decreases.

Both builds needed two hold-repair iterations. The baseline's initial/final
setup WNS is -5.709/-5.595 ns; the optimized build's is +0.041/+0.273 ns.
The common repair policy produces 709 versus 722 identity LUTs. Resource totals
include these cells and tool-driven mapping/replication, so the entire 319-LUT
difference must not be attributed solely to the FIR tree. Slice register counts
also exclude registers absorbed into DSP primitives.

Evidence:

- [Machine-readable comparison and exact hashes](../reports/implementation_comparison/summary.json).
- Baseline [timing](../reports/implementation_comparison/baseline/timing_post_route.rpt),
  [utilization](../reports/implementation_comparison/baseline/utilization_post_route.rpt),
  [failed setup acceptance](../reports/implementation_comparison/baseline/acceptance.tsv)
  and [47-run regression](../reports/implementation_comparison/baseline/regression_results.json).
- Optimized [timing](../reports/implementation_comparison/optimized/timing_post_route.rpt),
  [utilization](../reports/implementation_comparison/optimized/utilization_post_route.rpt),
  [passing acceptance](../reports/implementation_comparison/optimized/acceptance.tsv)
  and [47-run regression](../reports/implementation_comparison/optimized/regression_results.json).

## Reproduction and Acceptance

From the repository root, adapting executable paths if needed:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ./scripts/run_comparison.ps1 -VivadoBin 'E:/2026.1/Vivado/bin' -Python 'H:/2025.1/tps/win64/python-3.13.0/python.exe'
```

The runner freezes isolated source trees under
`build/implementation_comparison/{baseline,optimized}`, runs the full 47-test
integrated regression separately in each, and executes the identical physical
flow. Each regression includes the 20 default seeds of 10,000 accepted random
samples and the same parameter smoke matrix, directed protocol/arithmetic tests,
stalls, reset-discard accounting and Python output/flag comparisons.

The verifier requires both functional suites, all timing coverage checks,
hold/pulse checks, 115 physical interface anchors and internal routing audits
to pass. A baseline setup failure is retained as an explicit failure, including
the original Vivado exit status and failed acceptance report. It is never
converted into a passing implementation. The optimized build must pass setup.
Both builds' cycle-free accepted-event traces must match for all 47 runs.

To recheck existing generated artifacts without rerunning the tools:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ./scripts/run_comparison.ps1 -Python 'H:/2025.1/tps/win64/python-3.13.0/python.exe' -VerifyOnly
```

Only after both builds satisfy these comparison checks does verification archive
the text reports, logs, functional results, source snapshots and manifest under
`reports/implementation_comparison/`. Raw event traces and routed checkpoints
remain generated files under `build/`; their hashes are retained.
Archived tool/simulator logs use `.txt` extensions to remain tracked under the
repository's generated-log ignore rules.

## Interpretation Limits

This result covers the declared OOC module context. The absent parent-side
connections remain intentional boundary `ANTENNAS`; each functional interface
must reach its assigned physical node, and unexpected internal routing faults
are rejected. It is not board or assembled-parent acceptance.

`Constraints 18-8777`, if present, remains an unresolved tool/context warning,
not an accepted explanation of its cause. Revalidate before parent reuse.
RTL regression and identity-cell audits provide functional evidence; no separate
gate-level timing simulation or frequency sweep is claimed.
