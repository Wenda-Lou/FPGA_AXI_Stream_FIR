# AXI4-Lite Configuration and Status Registers

The standalone register bank is implemented and verified. It owns coefficients,
enable, transfer counters and sticky clipping status. It is also connected to
`dsp_datapath` in the verified [complete accelerator](accelerator.md). Results
on this page remain unit verification with testbench-driven datapath events.

## Sources and Integration Boundary

- [axi_lite_regs.v](../fpga_streaming_dsp/fpga_streaming_dsp.srcs/sources_1/new/axi_lite_regs.v): Verilog register bank with independent AXI channels.
- [tb_axi_lite_regs.sv](../fpga_streaming_dsp/fpga_streaming_dsp.srcs/sim_1/tb_axi_lite_regs.sv): bus drivers, register-map model, assertions and directed/random cases.
- [run_axi_regs.ps1](../scripts/run_axi_regs.ps1): simulation matrix and per-channel accounting checks.
- [configure_axi_regs_project.tcl](../scripts/configure_axi_regs_project.tcl): source sets and simulation top.
- [synth_axi_regs.tcl](../scripts/synth_axi_regs.tcl): default out-of-context synthesis and constrained internal setup/hold checks.

The slave uses 8-bit byte addresses, 32-bit data and four byte strobes. AWPROT and
ARPROT are accepted but do not change access policy. `TAPS` is a power of two
from 1 through 32, and `COEFF_WIDTH` is 2 through 32 bits; defaults are 8 and 16.
All state shares a rising-edge clock and active-low synchronous reset.

| Non-AXI port | Connection in the complete top |
| --- | --- |
| `datapath_idle` | Global `dsp_datapath.idle`, including both FIFOs |
| `input_transfer` | External stream input `valid && ready`, once per accepted sample |
| `output_transfer` | External stream output `valid && ready`, including drain while disabled |
| `saturation_event` | `dsp_datapath.result_saturated`, not stalled valid or external output consumption |
| `enable` | Datapath external-input acceptance gate |
| `coefficients` | Packed coefficients, tap zero in the least-significant word |
| `history_clear` | Datapath history-clear request, qualified on the write commit edge |
| `soft_clear` | Qualified soft-clear command strobe; counters/status clear inside this bank |

The caller supplies event pulses that already represent real handshakes. This
bank does not reconstruct FIFO occupancy or qualify arbitrary raw valid levels.

## Register Map and Access Rules

| Byte offset | Register | Behavior |
| --- | --- | --- |
| `0x00` | CONTROL | RW bit 0 ENABLE; write-one command bit 1 SOFT_CLEAR, reads zero |
| `0x04` | STATUS | RO bit 0 IDLE, bit 1 BUSY, bit 2 sticky SATURATED |
| `0x08` | INPUT_COUNT | RO accepted input events modulo 2^32 |
| `0x0C` | OUTPUT_COUNT | RO accepted output events modulo 2^32 |
| `0x20+4*k` | COEFF[k] | RW signed low `COEFF_WIDTH` bits; reads sign-extend to 32 bits |

Hardware reset clears coefficients, enable, counters, sticky status and all AXI
transaction slots/responses. STATUS reflects external idle rather than storing
its own busy state; it reads `1` after reset when the reset datapath is idle.
Read reserved fields return zero, except the specified coefficient sign extension.

CONTROL uses only byte lane zero. Other strobed lanes are successful no-ops.
Reserved write bits are ignored. Coefficient writes merge only strobed bits
inside the configured field. For example, a 10-bit coefficient uses byte zero
and bits 9:8 of byte one; byte lanes two and three have no effect.

An effective coefficient write requires the CURRENT enable to be zero and global
idle to be one. It emits a history clear even if the selected bits already hold
the requested value. A mapped writable access with no overlapping strobes is an
OKAY no-op, even while busy or enabled, and does not clear history.

A soft-clear command requires current enable zero, global idle one and requested
enable zero. It clears history, both counters and sticky status, preserves all
coefficients and leaves AXI response handling intact. A combined ENABLE=1 and
SOFT_CLEAR=1 command is rejected as a whole. To disable and clear an enabled
device, first write ENABLE=0, wait for global idle, then issue SOFT_CLEAR.

Unmapped or unaligned accesses and writes to read-only registers return SLVERR.
These errors take precedence over zero-strobe no-op handling. Invalid reads
return zero data with SLVERR. Illegal effective coefficient/clear writes also
return SLVERR without register side effects; independent event counters may
still advance from genuine datapath events on that clock.

## Channel and Event Timing

AW and W are captured independently. Address-first, data-first and same-edge
arrival are supported. A write commits on the first rising edge after both
buffered halves are present. It then produces one registered B response. Until
that response is consumed, neither half of another write is accepted. This
simple design deliberately allows bubbles between transactions.

Reads have a separate single response slot and can proceed while B is stalled.
RDATA/RRESP snapshot the state on AR acceptance. A write commit, counter event or
sticky event on that same edge appears only in a later read. Once captured, the
entire read response remains stable while RREADY is low, even if status changes.
BRESP/BVALID likewise remain stable while BREADY is low.

`history_clear` and `soft_clear` are combinational qualifications of the buffered
write, sampled on the commit edge. Coefficients and enable update on that edge
via nonblocking assignments. No delayed clear can leak into a later enable
transaction. A stalled B response never reissues the command.

Disabling takes effect after the commit edge. A stream input handshake on that
edge still belongs to the old enabled state and must be counted. Output events
continue counting while disabled. Event update priority is hardware reset,
then a legal soft clear, then increments/sticky-set events. Coefficient writes
clear history only; they do not clear counters or sticky saturation status.

## Reproduction and Verification

From the repository root, adapting tool paths if necessary:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ./scripts/run_axi_regs.ps1 -VivadoBin 'E:/2026.1/Vivado/bin'
```

Default tests run seeds 1 through 20 with 2,000 concurrent random write/read pairs
on the default configuration. Four smoke configurations run seeds 1, 7 and 42
with 500 pairs. Use `-Seeds`, `-Transactions`, `-SmokeTransactions` and `-SkipSmoke`
for shorter runs. Logs and source hashes are in `build/axi_regs_sim/`.

| Taps | Coefficient width | Runs | Random pairs per run |
| --- | --- | --- | --- |
| 8 | 16 | 20 | 2,000 |
| 1 | 8 | 3 | 500 |
| 4 | 10 | 3 | 500 |
| 8 | 32 | 3 | 500 |
| 32 | 16 | 3 | 500 |

Directed tests cover all coefficient addresses, all 16 strobe patterns, narrow
and full-width sign extension, unused lanes, invalid accesses, enable/idle access
rules, whole-command rejection, counter events, sticky status and soft-clear
preservation of coefficients and outstanding responses. Same-edge read/commit
and read/event cases check pre-edge snapshots; a disable commit counts its final
input event. Counter-wrap tests seed the two counters to `0xFFFFFFFE` with a
test-only hierarchical deposit, then use real event pulses to cross the boundary.

The bench also holds new AW/W behind stalled B and new AR behind stalled R,
checks payload stability on all five channels, and resets AW-only, W-only,
stalled B and stalled R states separately. Its register-map model checks each
commit/response and compares all exposed coefficients and enable after each edge.
The runner verifies accepted-channel conservation, explicitly accounting for
partial requests or responses intentionally discarded by hardware reset.

On 2026-11-15, Vivado 2026.1 build 6511674 passed all 32 runs: 46,000 random pairs,
47,636 write commits, 47,604 consumed B responses and 48,382 consumed R responses.
The 32 committed writes without consumed B were intentionally reset with B
stalled. Another 32 captured R responses, 32 AW-only requests and 32 W-only
requests were deliberately discarded by reset. No unexplained channel loss or
register-model mismatch occurred.

Retained [regression results](../reports/axi_regs/regression_results.json) and
[summary/source hashes](../reports/axi_regs/summary.json) describe this exact RTL
and testbench. This unit test uses a register-map oracle; FIR arithmetic is checked
separately in the existing [datapath regression](datapath.md).

## Vivado GUI and Synthesis

In an open project's Tcl Console:

```tcl
source {E:/DSP Accelerator AXI Interface/scripts/configure_axi_regs_project.tcl}
```

Design top becomes `axi_lite_regs`, simulation top `tb_axi_lite_regs`. Launch
behavioral simulation, then Run All. The command-line runner covers the matrix.

```powershell
New-Item -ItemType Directory -Force build/axi_regs_synth | Out-Null
& 'E:/2026.1/Vivado/bin/vivado.bat' -mode batch -nojournal -source ./scripts/synth_axi_regs.tcl -log ./build/axi_regs_synth/synth.log
```

Default OOC synthesis for `xc7a35tcpg236-1` uses 130 LUTs, 258 flip-flops, no DSPs
and no BRAM. Internal setup WNS is +5.332 ns and hold slack +0.269 ns at the 10 ns
target. See [timing](../reports/axi_regs/timing_synth.rpt) and
[utilization](../reports/axi_regs/utilization_synth.rpt) reports.

There are zero unconstrained internal endpoints, but 44 input and 170 output
ports have no external delays. The OOC clock-source warning `Timing 38-242`
also remains because no top-level clock buffer location is defined. These are
clock-only post-synthesis estimates. Complete-top integration tests are documented
separately; [module implementation](implementation.md) supplies the complete top's
I/O budgets and routed result. A different parent or board requires revalidation.
