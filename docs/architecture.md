# First-Version Architecture and Module Contracts

Status: architecture contract for the initial RTL implementation. The Python
arithmetic model and vector generator exist. The parameterized Verilog `axis_fifo`
has passed directed/randomized simulation across five configurations and
out-of-context synthesis for the default configuration. The parameterized FIR,
idle/history-clear control and per-output clipping status pass 38 simulation
runs with independent Python comparison. Default standalone synthesis and a
measured adder-tree timing optimization are complete. System integration and
AXI4-Lite control remain planned. See [FIFO design and results](axis_fifo.md) and
[FIR verification](fir_verification.md).
The proposal and register map are in [readme.md](../readme.md).

```mermaid
flowchart LR
    IN[AXI4-Stream input] --> IFIFO[axis_fifo: 16 samples]
    IFIFO --> FIR[fir_core: 8 parallel products and accumulation]
    FIR --> OFIFO[axis_fifo: 16 samples]
    OFIFO --> OUT[AXI4-Stream output]
    AXIL[AXI4-Lite] --> REGS[axi_lite_regs]
    REGS -->|enable: gate new input only| IFIFO
    REGS -->|coefficients and history clear| FIR
    IFIFO -->|occupancy| STATUS[status and transfer counters]
    FIR -->|pipeline valid and saturation| STATUS
    OFIFO -->|occupancy| STATUS
    STATUS --> REGS
```

## Shared Timing Rules

All modules use `clk` and an active-low synchronous `resetn`. External reset
deassertion is assumed synchronous to `clk`. Hardware reset takes precedence over
transfers and configuration. Ready/valid transfers occur only on rising edges
outside reset. Sources must hold payload and valid until acceptance.

Backpressure must propagate through the FIFOs and core without changing a pending
output. The core may initially stall its complete pipeline together to simplify
correctness. A later optimization may change pipeline placement while preserving
sample order and arithmetic.

## Modules and Target Contracts

| Module | Main signals | Contract |
| --- | --- | --- |
| `axis_fifo` | `s_data`, `s_valid`, `s_ready`, `m_data`, `m_valid`, `m_ready`, `occupancy` | Implemented: parameterized width and power-of-two depth (at least 2), default 16 bits / 16 entries; combinational head read, no empty bypass; full FIFO rejects a write even during a same-cycle read |
| `fir_core` | Ready/valid data, packed parameter-width coefficients, `history_clear`, `idle`, `m_saturated` | Implemented and verified: parameterized signed arithmetic, idle-only history clear, no FIR-tail flush, one output per accepted sample; saturation travels with its output |
| `axi_lite_regs` | Five AXI4-Lite channels, control/coefficients, status/counters | Independent write-address/data capture, one write and one read outstanding, decoded register map and error responses |
| `dsp_accelerator` | External stream and AXI4-Lite ports, `clk`, `resetn` | Instantiates buffers, core and registers; owns input gating, global idle and transfer counters |

The core registers products, adds them with a full-width balanced fabric adder
tree, then shifts/saturates into the output register. Its coefficient array will
be supplied by `axi_lite_regs`. Top-level logic guarantees coefficients remain constant while
data is in flight. A successful coefficient update emits `history_clear` when
the complete accelerator is disabled and empty. `history_clear` is also emitted
by a legal soft-clear command.

`history_clear` suppresses input readiness. Busy pulses preserve pending results;
a request held through draining clears history once idle is reached. The output
FIFO must store the clipping flag together with data, requiring
`OUTPUT_WIDTH + 1` payload bits for `{m_saturated, m_data}`.

`idle` for each FIFO means zero occupancy. Core `idle` means all valid stages are
empty. Global `IDLE` is the conjunction of these conditions. History contents do
not affect idle status. The saturation flag travels with its output data through
the core; sticky `SATURATED` is set when the result transfers into the output
FIFO. This event occurs exactly once per generated result, including under stalls.

Clearing `ENABLE` gates external input acceptance from the following cycle and
leaves all internal drain paths active. The top level counts external input and
output handshakes, not cycles with valid asserted. A scoreboard tracks queued
expectations across all internal buffering.

## Reference Model Boundary

`FirModel.process(sample)` represents one accepted sample, regardless of cycle
gaps. It accepts signed Python integers. `decode_signed` and `encode_signed`
convert bus words at file/monitor boundaries. The model uses exact integer
products and accumulation, floor shifting and final saturation.

`write_coefficient` represents an already-authorized effective coefficient
update and clears history. `clear_history` represents a legal soft clear, and
`hardware_reset` clears both coefficients and history. The model intentionally
does not enforce AXI state, enable, register strobes or FIFO capacity. Those are
separate RTL control and scoreboard checks.

Each generated vector scenario starts with hardware reset, programming all eight
coefficients, then a sequence of accepted input samples. The RTL driver must
advance its input file index only on a handshake and keep data stable during
stalls. The monitor consumes one expected word per output handshake. At scenario
end, the driver disables new inputs, holds output ready, and checks that every
expected result has drained before resetting for the next scenario.

## Next Implementation Milestone

1. Connect both verified FIFOs and FIR, carrying data and clipping status together, and stress the complete streaming datapath with stalls.
2. Add AXI4-Lite control after the streaming datapath is verified.
3. Run integrated synthesis/implementation, close post-route timing and retain reproducible performance results.

FIFO simulation uses the installed Vivado 2026.1 simulator; see
[development instructions](development.md) for results and reproduction commands.
Standalone FIFO and FIR synthesis are complete; integrated synthesis and post-route timing
analysis remain pending. Python tests validate the reference flow and do not
establish RTL or timing acceptance.
