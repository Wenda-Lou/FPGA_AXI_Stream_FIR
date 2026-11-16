# Constrained Module Implementation

This flow implements the default `dsp_accelerator` as a routed out-of-context
(OOC) module on `xc7a35tcpg236-1`. It models a synchronous parent interface,
including physical partition-pin endpoints. It does not build a board bitstream
or prove timing for an unspecified processor, board or assembled parent design.

## Timing Contract

[dsp_accelerator_timing.xdc](../constraints/dsp_accelerator_timing.xdc) defines the
100 MHz clock and all interface budgets. Inputs and outputs use a 10 ns virtual
reference clock aligned with the hardware clock at the context boundary. This
reference creates no second hardware clock domain. All relationships are timed.

| Assumption | Value |
| --- | --- |
| Hardware `clk` period / duty cycle | 10 ns / 50% |
| Virtual `interface_clk` period / phase offset | 10 ns / 0 ns |
| Input arrival, minimum / maximum | 0.5 ns / 2.0 ns after launch edge |
| Output delay, minimum / maximum | -0.5 ns / 2.0 ns |
| External receiver hold / setup budget | 0.5 ns / 2.0 ns |
| Additional user setup / hold uncertainty | 0.100 ns / 0.050 ns |

These are declared integration budgets, not measured board values. Input delay
covers upstream logic and interconnect. Output max reserves downstream setup
and logic time; output min is the negative receiver hold requirement. Vivado's
device jitter analysis is additional to the user uncertainty. The use and signs
of these constraints follow [AMD UG903](https://docs.amd.com/r/en-US/ug903-vivado-using-constraints/Constraining-Input-or-Output-Logic)
and [AMD UG949 output-delay guidance](https://docs.amd.com/r/2026.1-English/ug949-vivado-design-methodology/Defining-Output-Delays).

Every non-clock input is covered, including AXI ready/valid, addresses, write data,
strobes, PROT and `resetn`. Every output is covered. Reset is synchronous and
receives ordinary setup/hold analysis. No false paths, asynchronous clock groups,
multicycle paths, case analysis or disabled timing arcs are introduced by this flow.
Reserved/ignored signals can be optimized away; their absence of a functional
timing path is recorded rather than counted as an unconstrained endpoint.

## Physical Parent Context

[dsp_accelerator_ooc.xdc](../constraints/dsp_accelerator_ooc.xdc) is read after
synthesis and only applies to OOC implementation. It declares a parent global
clock source at `BUFGCTRL_X0Y0` and a boundary-pin placement region
`SLICE_X0Y0:SLICE_X65Y99`. The script validates that the named resources exist.
These are fabric resources, not package pin assignments or an external oscillator.

A whole-device Pblock establishes the module routing context, with hard placement
and contained routing. Individual interface partition nodes are selected within
the declared region. Reuse in another parent requires revalidating these physical
assumptions and the timing budgets. Physical context properties and partition
constraints follow [AMD UG905](https://docs.amd.com/r/en-US/ug905-vivado-hierarchical-design/Context-Constraints).

OOC interface nets terminate at partition nodes because the parent-side net is
absent. Vivado can label these intentional boundary subnets `ANTENNAS` and report
whole-design `ROUTED_FULLY=0`. That flag alone is not the acceptance criterion
for this module flow. The audit requires every functional port's assigned node
to be present in its actual routed node tree. It accepts a boundary stub only
when connected to a declared module port with at most one logical driver, and
rejects internal antennas, gaps, conflicts, unplaced or multiply driven nets.
Raw route status and the boundary audit are both retained, without hiding this
distinction. Full parent-side routing is outside the result's scope.

## Hold Closure and Functional Preservation

The initial routed module can meet setup while failing input hold: fast data
paths arrive before the delayed internal clock's hold window ends. The flow
preserves the original 0.5/2.0 ns interface budget instead of relaxing constraints.

If input hold still fails after router exploration, the script inserts identity
`LUT1` chains on the violating input paths. Each cell has `INIT=2'h2`, so its
truth table is exactly `y=x`, with `DONT_TOUCH` preserving the physical delay
elements. The input port is split from its existing net; all existing internal
loads remain connected through the new chain. No register, clock edge or protocol
state is added. FIR arithmetic and the four-clock handshake latency are unchanged.

The stage-count heuristic plans repairs, not device delay. Placement, physical
optimization and routing rerun after every repair, and real setup/hold results
decide acceptance. At most five repair iterations are permitted. A post-route
audit checks each inserted cell's truth table, protection and connectivity.
There is a resource cost, recorded in `identity_buffers.tsv` and utilization.

The default RTL remains byte-identical to the five modules used by the existing
47-run integrated regression. The verifier cross-checks those SHA-256 hashes.
The RTL regression and identity-cell audit are functional evidence; this flow
does not claim a separate gate-level timing simulation.

## Reproduction

From the repository root, adapting tool locations if necessary:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ./scripts/run_implementation.ps1 -VivadoBin 'E:/2026.1/Vivado/bin' -Python 'H:/2025.1/tps/win64/python-3.13.0/python.exe'
```

The runner launches Vivado from `build/accelerator_impl/`, keeping physical-tool
diagnostics out of the source tree. The [Tcl flow](../scripts/implement_accelerator.tcl)
uses two threads, default numerical parameters, Default placement/initial routing,
then Explore placement/routing and `ExploreWithAggressiveHoldFix` for repair
iterations. It reloads the saved routed checkpoint before final verification so
results describe the restorable artifact rather than transient hierarchy caches.

The [verifier](../scripts/verify_implementation.py) checks:

- Nonnegative setup, hold and pulse-width slack, and zero failing endpoints.
- Complete timing coverage, including missing/partial I/O delays, clocks and loops.
- Both max and min analysis for register-to-register, input-to-register,
  register-to-output and input-to-output paths.
- Physical partition-node connectivity for all functional interface ports and
  no unexpected internal routing errors.
- No severe DRC or methodology violations, and no unreviewed critical warnings.
- Source sizes/timestamps captured before synthesis, exact source hashes,
  unchanged regressed RTL and valid identity-buffer repair accounting.

An intermediate `Route 35-39` message can occur while hold is still being repaired.
It is treated as resolved only after final timing and routing audits pass. XDC
loading errors or other critical warning types are rejected. No message severity
is downgraded. Timing coverage uses
[AMD's documented check commands](https://docs.amd.com/r/en-US/ug835-vivado-tcl-commands/check_timing).

Successful verification archives text evidence under
`reports/accelerator/implementation/`. The large routed checkpoint remains under
`build/accelerator_impl/dsp_accelerator_routed.dcp`, with its SHA-256 in the summary.
To verify an existing build without rerunning placement/routing:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ./scripts/run_implementation.ps1 -Python 'H:/2025.1/tps/win64/python-3.13.0/python.exe' -VerifyOnly
```

Verification rejects incomplete builds, changed inputs, failing timing or missing
physical evidence before publishing a passing summary.

## Vivado Project and Inspection

The full-top project uses the two accelerator XDC files. Its configuration helper
disables the historical clock-only constraints; standalone helpers restore their
own profile, preventing duplicate clocks when switching tests. The historical
XDC and synthesis-only reports remain unchanged on disk.

Use the provided implementation runner for physical acceptance: the ordinary
project Run Implementation button does not include this custom OOC hold-repair
and boundary-audit flow. To inspect the final placement/routing, open the routed
checkpoint in a separate Vivado session:

```tcl
open_checkpoint {E:/DSP Accelerator AXI Interface/build/accelerator_impl/dsp_accelerator_routed.dcp}
report_timing_summary -delay_type min_max -report_unconstrained
```

This establishes a passing 100 MHz module only under the published interface and
parent context. It does not measure Fmax, board behavior or timing after reuse
with different clock, partition-pin, I/O or floorplan assumptions.

A [separate controlled full-top comparison](optimization_comparison.md) reruns
this byte-identical physical flow for a reconstructed linear-accumulation
baseline and the canonical balanced-tree FIR. It records a 5.868 ns setup-slack
improvement and the corresponding resource cost; both variants pass the same
47-run functional matrix. Those reports do not replace this earlier result.

## Recorded Result and Retained Limitations

The reproducible run on 2026-11-16 passed the module acceptance checks with
Vivado 2026.1 build 6511674. The saved checkpoint was reloaded and independently
verified before archiving [the summary](../reports/accelerator/implementation/summary.json),
[timing](../reports/accelerator/implementation/timing_post_route.rpt),
[routing](../reports/accelerator/implementation/route_status.rpt) and
[port-node audit](../reports/accelerator/implementation/boundary_ports.tsv).

| Result | Measured value |
| --- | --- |
| Target | 100 MHz, 10 ns |
| Worst setup slack / TNS | +0.273 ns / 0 ns |
| Worst hold slack / total negative hold slack | +0.031 ns / 0 ns |
| Worst pulse-width slack | +3.750 ns |
| Failing setup / hold / pulse-width endpoints | 0 / 0 / 0 |
| Missing clocks, missing/partial I/O delays, unconstrained internal endpoints | All 0 |
| Functional interface ports with routed physical anchors | 115 of 115 |
| Expected OOC parent-boundary stubs / unexpected internal routing errors | 111 / 0 |
| Severe DRC / methodology violations | 0 / 0 |
| Slice LUTs / flip-flops / DSPs / BRAM tiles | 1,043 / 463 / 8 / 0 |
| Audited identity LUT1 cells | 722 |

The path-class audit reports setup/hold margins of +0.273/+0.031 ns internally,
+0.421/+1.028 ns from input to register, +3.568/+0.303 ns from register to output,
and +0.896/+2.033 ns for combinational input-to-output paths. Actual endpoints
are in [path_classes.tsv](../reports/accelerator/implementation/path_classes.tsv).

The first routed attempt had +0.041 ns setup but -1.293 ns hold. Two repair
iterations inserted 713 then 9 identity LUTs and reached the final positive
margins. The [iteration record](../reports/accelerator/implementation/iterations.tsv)
and [cell audit](../reports/accelerator/implementation/identity_buffers.tsv)
retain this tradeoff. Physical optimization also changes mapping/replication;
do not compare routed resource counts to the earlier synthesis-only counts as
if implementation had added only the manually inserted cells.

Regular warnings remain visible and are reviewed in `summary.json`:

- Ignored AXI PROT and reserved inputs can have no surviving net.
- OOC connectivity DRC coverage excludes portions of a whole assembled design.
- The virtual reference clock is intentionally related to the hardware clock.
- Two intermediate router timing critical warnings are resolved by final positive
  margins. No other critical warning type is accepted or downgraded.
- Named reports in batch mode create data without a GUI tab.
- CFGBVS-1 has no board configuration-voltage assignment; DSP pipeline advisory
  rules do not justify changing the specified latency to silence a warning.
- **Constraints 18-8777 remains unresolved:** router initialization reports
  `Unable to split tiles. All required files are not available.` Its cause has
  not been confirmed. The flow separately verifies all physical boundary nodes
  and internal routing. This warning is retained as a tool/context limitation,
  and requires revalidation before reuse in a parent design.

The raw whole-design routing report intentionally remains partially routed at
the absent parent boundary. No bitstream or board-level acceptance is claimed.
The verifier also rejects a failed run marker or a missing physical anchor;
both negative checks were exercised on copies without modifying the real results.
