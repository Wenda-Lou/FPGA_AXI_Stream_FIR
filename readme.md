# Project Proposal  
## FPGA Streaming DSP Accelerator with AXI Interfaces and SystemVerilog Verification

**Project Duration:** December 19, 2026 – January 15, 2027  
**Project Type:** Independent Digital Design / FPGA Project  
**Development Environment:** Xilinx Vivado, SystemVerilog, Verilog, Python  
**Target Roles:** FPGA Engineer, RTL Design Intern, Digital IC Design/Verification Intern, Hardware Validation Intern

**Project Status:** Phase 1 in progress. The integer Python reference flow and parameterized Verilog FIFO are implemented. FIFO verification passes 32 runs in Vivado 2026.1, including 20 seeds of 10,000 accepted random inputs for the required configuration and width/depth smoke tests. The default FIFO also passes out-of-context synthesis for `xc7a35tcpg236-1`. See [FIFO design and results](docs/axis_fifo.md). FIR RTL, integrated verification, implementation, and performance optimization remain pending. The specifications below define the target requirements.

### Getting Started

Run the reference-model tests and generate simulation vectors with Python 3.10 or newer; no third-party Python packages are required:

```powershell
python -m unittest discover -s tests -v
python scripts/generate_vectors.py --seed 1 --count 10000
```

See [development instructions](docs/development.md) for the Python wrapper, FIFO simulation command and results, local tool status, and generated file formats, and [architecture and module contracts](docs/architecture.md) for the RTL boundaries. Generated files are written to `build/` and excluded from Git. The commands above validate the Python reference flow; the FIFO has a separate HDL regression.

---

## 1. Project Background

My current project experience includes high-speed ADC calibration, Python-based feedback control, hardware validation, and FPGA-related system debugging. However, my experience in complete RTL design, protocol-based interfaces, formalized verification, synthesis, and timing optimization is comparatively limited.

The purpose of this project is to strengthen these areas by completing an end-to-end digital design workflow entirely in simulation and FPGA development tools, without requiring a physical development board.

The project will focus on the design of a parameterized streaming DSP accelerator with AXI interfaces, followed by systematic SystemVerilog verification, FPGA synthesis, timing analysis, and performance optimization.

---

## 2. Project Objective

The primary goal is to design and verify a reusable FPGA-based streaming accelerator that processes input samples through a pipelined DSP datapath.

The initial processing function will be a configurable FIR filter.

The project will demonstrate practical skills in:

- SystemVerilog RTL design
- AXI4-Stream protocol
- AXI4-Lite register interface
- Pipelined datapath design
- FIFO and flow-control logic
- Ready/valid handshaking
- Self-checking verification
- SystemVerilog assertions
- Randomized and corner-case testing
- Python golden-reference modeling
- Vivado synthesis and implementation
- Timing analysis
- FPGA resource analysis
- RTL performance optimization

---

## 3. Proposed System Architecture

The proposed system architecture is:

**AXI4-Stream Input  
→ Input Buffer / FIFO  
→ Pipelined FIR Processing Core  
→ Output Buffer  
→ AXI4-Stream Output**

A separate control path will be implemented using:

**AXI4-Lite  
→ Configuration and Status Registers  
→ DSP Core Control**

### 3.1 First-Version Scope

The first version will use one clock domain for the datapath and both AXI interfaces. It will process one continuous sequence of signed samples, with no packet boundaries or clock-domain crossing.

| Item | First-version requirement |
| --- | --- |
| FIR taps | 8, with 8 parallel multipliers |
| Input / coefficient format | Signed 16-bit two's complement, with 15 fractional bits |
| Output format | Signed 16-bit two's complement, with 15 fractional bits |
| Input FIFO / output FIFO | 16 samples each |
| Stream payload | One sample per 16-bit `TDATA` transfer |
| Stream signals | `TDATA`, `TVALID`, `TREADY`; no `TLAST`, `TKEEP`, or other optional sidebands |
| Control interface | AXI4-Lite, 32-bit data, 8-bit byte address |
| Clock target | 100 MHz (10 ns period) |
| Throughput target | One accepted input and one output transfer per cycle in steady state without backpressure |
| Latency | Fixed for a given build without stalls; measure and document core and top-level latency separately |
| Hardware reset | Active-low synchronous reset, shared by all modules |

These values define the required configuration for final verification and implementation reports. They are design targets, not measured results.

### 3.2 Compile-Time Parameters and Runtime Configuration

Input width, coefficient width, output width, fractional-bit counts, tap count, and FIFO depth will be compile-time parameters. The required build uses the values above. Additional smoke tests will cover tap counts of 1 and 4 and FIFO depths of 2 and 4; other parameter combinations are outside the first-version acceptance scope. Supported tap counts and FIFO depths will be positive powers of two, with FIFO depth at least 2.

Filter coefficients and enable control will be runtime registers. Pipeline placement will be an RTL implementation choice, documented for each build, rather than an arbitrary runtime setting.

Multi-clock operation, coefficient changes during active processing, packet processing, a processor subsystem, UVM, and physical-board validation are stretch goals outside the four-week deliverables.

---

## 4. RTL Design

### 4.1 AXI4-Stream Interface

The input and output interfaces will implement the AXI4-Stream signal subset defined in Section 3.1. A sample transfers only on a rising clock edge where both `TVALID` and `TREADY` are high.

The implementation must correctly support:

- Continuous data streaming
- Input stalls
- Output backpressure
- Pipeline stalls
- Reset conditions
- Transaction ordering
- Data stability while stalled

FIR sample history will advance only when the core accepts an input sample. Gaps in traffic will not insert zero-valued samples. Every accepted input will produce exactly one output unless a hardware reset explicitly discards pending data. No additional outputs will be generated to flush the FIR tail.

Output `TVALID` and `TDATA` will remain stable during a stall until the transfer completes or hardware reset is asserted. Buffer occupancy and pipeline capacity will determine input readiness; backpressure must not overwrite an unconsumed result.

---

### 4.2 FIFO / Buffering

A parameterized synchronous FIFO will be implemented to decouple the AXI interface from the processing core.

The FIFO will include:

- Read/write control
- Full/empty detection
- Occupancy tracking
- Overflow/underflow protection

FIFO occupancy will change only on accepted reads and writes. Verification will cover pointer wraparound and simultaneous reads and writes at empty, full, and intermediate occupancy. A full FIFO may conservatively reject a write during a simultaneous read; the required continuous-throughput measurement will be made after startup at an occupancy that permits both operations.

---

### 4.3 FIR Processing Core

The DSP core will implement a parameterized finite impulse response filter.

The design will use a multiply-accumulate datapath and will be pipelined to increase throughput and maximum clock frequency.

The initial implementation will prioritize correctness, followed by optimization based on synthesis and timing results.

#### 4.3.1 Numerical Specification

For accepted sample index `n`, the filter will compute:

```text
acc[n] = sum(coeff[k] * sample[n-k], k = 0 .. NUM_TAPS-1)
```

`coeff[0]` multiplies the newest sample. Samples preceding the first accepted input after history clear are zero.

- Each signed product will retain all `INPUT_WIDTH + COEFF_WIDTH` bits.
- The signed accumulator will use `INPUT_WIDTH + COEFF_WIDTH + clog2(NUM_TAPS)` bits: 35 bits for the required 8-tap build. Products will be sign-extended before addition.
- The required build's product and accumulator have 30 fractional bits. An arithmetic right shift by 15 will return the result to 15 fractional bits. This discards low bits and rounds toward negative infinity; there is no round-to-nearest step.
- The shifted result will saturate to the signed output range, `-32768` through `32767`, before narrowing to 16 bits. Intermediate additions will not saturate or wrap.
- Parameterized builds must use a nonnegative shift of `INPUT_FRAC_BITS + COEFF_FRAC_BITS - OUTPUT_FRAC_BITS` and valid fractional-bit counts for their widths.

The Python model and RTL scoreboard will use these exact integer rules. Functional acceptance requires bit-for-bit equality, including negative values and saturation cases.

---

### 4.4 AXI4-Lite Control Interface

An AXI4-Lite-compatible register interface will provide software-style configuration and status access.

#### 4.4.1 Proposed Register Map

All addresses are byte offsets from the peripheral base address. Reset values are zero except `STATUS.IDLE`, which is one after reset.

| Offset | Register | Access | Definition |
| --- | --- | --- | --- |
| `0x00` | `CONTROL` | RW / command | Bit 0: `ENABLE`; bit 1: self-clearing `SOFT_CLEAR` command; remaining bits reserved |
| `0x04` | `STATUS` | RO | Bit 0: `IDLE`; bit 1: `BUSY`; bit 2: sticky `SATURATED`; remaining bits read zero |
| `0x08` | `INPUT_COUNT` | RO | Accepted input transfers, modulo 2^32 |
| `0x0C` | `OUTPUT_COUNT` | RO | Accepted output transfers, modulo 2^32 |
| `0x20 + 4*k` | `COEFF[k]` | RW | Signed coefficient in the low `COEFF_WIDTH` bits; upper read bits are sign-extended |

For the required build, coefficient registers occupy `0x20` through `0x3C`. Parameterized builds must keep coefficient width at most 32 bits and all coefficient addresses within the 8-bit address space.

#### 4.4.2 Configuration and Control Behavior

- Hardware reset will clear coefficients, sample history, FIFO contents, pipeline valid bits, counters, sticky status, and pending AXI4-Lite transactions. `ENABLE` will reset to zero. Pre-reset transactions will be discarded.
- Setting `ENABLE` will allow new input transfers. Clearing it will stop new input transfers from the following cycle; a transfer on the control-write commit edge still belongs to the old enabled state. Already accepted samples will continue through the core and output interface.
- `IDLE` will mean that both FIFOs and all pipeline valid stages are empty; `BUSY` is its inverse. Nonzero FIR sample history alone does not make the accelerator busy. Output backpressure can delay reaching `IDLE` indefinitely.
- Coefficient writes will be accepted only when the current state has `ENABLE = 0` and `IDLE = 1`. Each successful coefficient write will also clear FIR sample history. Software must program the complete intended coefficient set before re-enabling; no processing can occur during programming.
- Disabling and re-enabling without coefficient writes or `SOFT_CLEAR` will preserve FIR sample history. This resumes the same sample sequence.
- A `SOFT_CLEAR` command will be accepted only when the current state is disabled and idle and the requested `ENABLE` value is zero. It will clear FIR history, counters, and sticky status while preserving coefficients and AXI4-Lite transaction handling. Bit 1 always reads zero.
- `SATURATED` will be set when a newly produced FIR result is clipped. Hardware reset or `SOFT_CLEAR` will clear it.

#### 4.4.3 AXI4-Lite Transaction Requirements

The slave will accept write address and write data independently, including address-first, data-first, and same-cycle arrival. It will buffer at most one write address and one write payload and commit the write once both have been received. It will not accept the next write transaction until the prior write response has transferred. One read may be outstanding independently of a write.

`BVALID` and `BRESP`, and `RVALID`, `RDATA`, and `RRESP`, will remain stable while their response channel is stalled. Read data will be captured when the read address is accepted; a same-cycle register write or counter update will be visible to subsequent reads.

`WSTRB` will select writable byte lanes. For `CONTROL`, only lane 0 affects defined bits. For coefficients, only strobed bytes overlapping the coefficient field will change. Writes to mapped writable registers with no effective byte lanes are successful no-ops. Reserved write bits are ignored, and reserved read bits return zero.

Successful accesses will return `OKAY`. Unmapped or unaligned accesses, writes to read-only registers, and effective coefficient or clear-command writes that violate the control rules will return `SLVERR` with no register side effects. Any invalid combined `CONTROL` write will be rejected as a whole. Protocol handling will be verified separately from FIR arithmetic.

---

## 5. Verification Plan

Verification will be treated as a major component of the project.

A self-checking SystemVerilog testbench will be developed rather than relying only on waveform inspection.

Verification scenarios will include:

- Reset behavior
- Single-sample transactions
- Continuous streaming
- Randomized input values
- Maximum/minimum numerical values
- Input stalls
- Random output backpressure
- Repeated enable/disable operations
- FIFO full/empty conditions
- AXI4-Lite register reads
- AXI4-Lite register writes
- Long randomized regression tests

### 5.1 Required Directed and Random Tests

Directed arithmetic tests will cover impulse response, all-zero coefficients, a single nonzero coefficient, positive and negative samples, signed extrema, alternating signs, negative shift behavior, and positive and negative saturation.

Traffic tests will include long output stalls sufficient to fill the accelerator, back-to-back transfers, FIFO pointer wraparound, disabling with data in flight, resuming with preserved history, and hardware reset while output or control responses are stalled. Hardware-reset tests will explicitly discard pre-reset scoreboard expectations.

AXI4-Lite tests will cover independent address/data ordering, response backpressure, partial-byte and zero-strobe writes, sign-extended coefficient reads, invalid addresses, read-only writes, illegal active coefficient updates, and legal idle reconfiguration. Control tests will check enable-transition edges, counter rollover, soft clear, and status behavior.

The SystemVerilog scoreboard will enqueue an expected result for each accepted input and compare it on each accepted output. It will use Python-generated expected results and maintain a queue of pending expectations under stalls. Each non-reset test must drain all expected outputs before passing.

### 5.2 Regression Acceptance

- All directed cases must pass with zero mismatches and zero assertion failures.
- The required build must pass at least 20 recorded random seeds, each with at least 10,000 accepted input samples and randomized input gaps and output backpressure.
- Each random run will finish with input disabled and output ready so that pending data can drain. A bounded timeout will fail a hung test; no liveness claim will assume progress while output readiness is held low forever.
- Parameter smoke tests will cover the additional configurations in Section 3.2.
- Test reports will record seed, configuration, accepted input/output counts, numerical comparisons, assertion failures, and observed scenario coverage. Directed tests must demonstrate both saturation signs, full/empty FIFO boundaries, each AXI write ordering, and control/reset cases.
- A separate continuous-stream test must demonstrate one output transfer per cycle for at least 1,024 consecutive cycles after startup, and report latency without stalls.

---

## 6. SystemVerilog Assertions

Assertions will be added to verify important protocol and design properties.

Examples include:

- Output data remains stable while `valid = 1` and `ready = 0`
- AXI4-Lite response payloads remain stable while stalled
- FIFO never accepts a read while empty
- FIFO never accepts a write without available capacity
- FIFO occupancy remains within its legal range
- Pipeline stages advance only when downstream capacity permits
- Reset places the design into a valid state

Transaction loss, duplication, ordering, and numerical correctness will be checked with the scoreboard and input/output accounting. Assertions will focus on local protocol and state invariants; assertions passing in simulation will not be described as a formal proof.

---

## 7. Python Golden Reference Model

A Python implementation of the FIR filter will serve as the golden reference model.

The proposed verification flow is:

**Python test-vector generation  
→ RTL simulation  
→ RTL result export  
→ Python reference comparison  
→ Pass/fail report**

Python will be used to:

- Generate randomized test vectors
- Generate coefficient sets
- Compute expected outputs
- Compare RTL and reference outputs
- Implement exact signed accumulation, arithmetic shifting, and output saturation
- Track history clearing and accepted-sample order across configuration changes
- Summarize regression results

The goal is to create a repeatable automated verification workflow rather than manually inspecting individual simulations.

The reference model will use integer arithmetic with explicit signed input decoding, rather than floating-point tolerances. Small hand-calculated vectors will first validate tap ordering, shifting, and saturation in the model itself. Simulation exports will contain only accepted input/output transfers, with reset/configuration events recorded so offline comparison can reconstruct each processing epoch.

The regression entry point will generate vectors, run simulation, compare outputs, and return a nonzero exit status on any mismatch, assertion failure, simulator error, or timeout. Tool versions, dependencies, commands, and random seeds will be documented once the scripts exist.

---

## 8. Synthesis and FPGA Implementation

The proposed implementation target is an Artix-7 `xc7a35tcpg236-1`, using a 100 MHz clock constraint. Phase 1 will confirm installed device support and record the exact Vivado version and simulator. If the proposed part is unavailable, a supported replacement will be selected and documented before baseline measurements.

An early synthesis check will run during RTL development to identify elaboration, inference, and resource issues. The fully integrated design will then be synthesized, placed, and routed after functional verification.

No physical board is required.

The following metrics will be collected:

- LUT utilization
- Flip-flop utilization
- DSP slice utilization
- BRAM utilization
- Post-route setup WNS and total negative slack (TNS)
- Post-route hold slack and timing violations
- Critical path endpoints and path type
- Throughput and latency under the documented traffic conditions
- Highest tested clock frequency that passes implementation timing, if a clock sweep is completed

These metrics will establish a baseline implementation.

Timing acceptance requires nonnegative setup and hold slack with no unwaived timing violations or unconstrained functional paths under the documented constraints. Clock and external input/output timing assumptions will be recorded explicitly. Critical warnings and timing exceptions will be reviewed and explained. A 100 MHz passing implementation demonstrates the constrained target; it does not establish the maximum achievable frequency or physical-board performance.

---

## 9. Performance Optimization

The initial design will be analyzed for timing bottlenecks.

Potential optimization techniques include:

- Increasing pipeline depth
- Registering intermediate arithmetic results
- Reducing combinational path depth
- Restructuring multiply-accumulate logic
- Register balancing
- Improving handshake logic
- Separating control and datapath logic

At least one measurable optimization should be completed. The initial implementation will use registered multipliers followed by a baseline accumulation stage. A pipelined balanced adder tree is the planned comparison, subject to the critical paths observed in implementation.

Both builds must preserve arithmetic behavior and steady-state throughput and pass the same regression suite. Additional pipeline cycles are allowed and must be reported.

Baseline and optimized runs will use the same FPGA part, numerical parameters, clock and I/O constraints, Vivado version, implementation strategy, and placement seed settings where available. Any unavoidable differences will be disclosed. Source revisions and build scripts will be retained.

| Metric | Baseline | Optimized |
| --- | --- | --- |
| Target clock period | 10 ns | 10 ns |
| Post-route setup WNS / TNS | Pending | Pending |
| Post-route hold slack | Pending | Pending |
| LUT / FF / DSP / BRAM use | Pending | Pending |
| Throughput without stalls | Pending | Pending |
| Core / top-level latency without stalls | Pending | Pending |
| Highest timing-passing frequency, if swept | Not measured | Not measured |

The final comparison must show a measured timing or resource improvement and explain its latency/resource tradeoffs. If a frequency sweep is performed, each reported passing frequency must have its own implementation timing evidence. No illustrative performance numbers will be presented as measured results.

---

## 10. Project Schedule

### Phase 1 — Architecture and RTL Development
**December 19 – December 24**

Tasks:

- Define system architecture
- Define module interfaces
- Define AXI4-Lite register map
- Freeze numerical, reset, enable, and coefficient-update rules
- Confirm Vivado, simulator, target-part support, and timing constraints
- Create the integer Python model and hand-calculated directed vectors
- Implement AXI4-Stream interface
- Implement FIFO
- Implement initial FIR datapath
- Run basic simulation tests
- Run an early synthesis check of the datapath

**Milestone:**  
Basic accelerator matches directed reference vectors in simulation; specifications and tool configuration are recorded, and the datapath passes an early synthesis check.

---

### Phase 2 — Verification Environment
**December 25 – December 31**

Tasks:

- Develop self-checking SystemVerilog testbench
- Implement monitors and scoreboards
- Add randomized transactions
- Add output backpressure testing
- Add boundary and reset tests
- Add SystemVerilog assertions
- Extend the Python reference model with randomized vectors and configuration events
- Automate RTL/reference comparison

**Milestone:**  
The streaming datapath passes automated regression under randomized traffic and backpressure; throughput and stall-free latency are measured.

---

### Phase 3 — AXI4-Lite Integration and Synthesis
**January 1 – January 7**

Tasks:

- Complete AXI4-Lite interface
- Verify register read/write behavior
- Integrate configuration registers with FIR core
- Verify configuration transitions and run the integrated regression suite
- Run Vivado synthesis
- Run FPGA implementation
- Analyze resource utilization
- Analyze timing report
- Identify critical paths

**Milestone:**  
The integrated design passes control-interface tests and completes place and route; baseline timing and resource reports identify whether the 100 MHz target is met and where optimization is needed.

---

### Phase 4 — Optimization and Documentation
**January 8 – January 15**

Tasks:

- Optimize critical datapath
- Re-run synthesis and implementation
- Compare baseline and optimized designs
- Run final verification regression
- Capture representative waveforms
- Create system block diagram
- Document architecture and verification methodology
- Organize GitHub repository
- Write project README
- Prepare final resume bullets
- Record reproducible commands, tool versions, source revisions, and known limitations

**Milestone:**  
Complete, verified, synthesized, optimized, and documented portfolio project.

Required functionality and verification take priority over stretch goals. If timing closure or protocol correctness takes longer than expected, optional parameter expansion and frequency sweeps will be deferred. Any unmet required criterion will be documented as incomplete.

---

## 11. Final Deliverables

The final GitHub repository should contain:

### RTL

- AXI4-Stream interface modules
- AXI4-Lite interface module
- FIFO
- FIR processing core
- Top-level accelerator module

### Verification

- SystemVerilog testbench
- Assertions
- Randomized tests
- Regression scripts
- Python golden model
- Seeded pass/fail summaries and scenario-coverage results

### FPGA Results

- Synthesis report
- Timing report
- Resource utilization report
- Baseline vs. optimized comparison
- Reproducible Vivado Tcl scripts and timing constraints
- Tool versions, target part, build configuration, and source revisions

### Documentation

- README
- Block diagram
- Register map
- Architecture description
- Verification plan
- Simulation waveform examples
- Performance optimization results
- Numerical specification, control-state behavior, and known limitations

---

## 12. Success Criteria

The project will be considered complete when:

1. The required configuration passes all directed tests and at least 20 random seeds of 10,000 accepted samples each; the additional parameter smoke tests also pass.
2. Every accepted output matches the integer Python reference bit for bit; queues drain with no unexpected, missing, or duplicate outputs outside explicitly reset-discarded traffic.
3. AXI4-Stream handles randomized backpressure and demonstrates one output per cycle for at least 1,024 consecutive cycles without stalls after startup.
4. AXI4-Lite channel ordering, byte strobes, responses, invalid accesses, and configuration-state rules pass their tests.
5. All enabled assertions pass, and required scenario coverage is documented.
6. The final design completes synthesis, placement, and routing and meets the 100 MHz constraints with nonnegative setup and hold slack and no unwaived timing violations or unconstrained functional paths.
7. Resource utilization, clock/I/O constraints, measured throughput, and latency are documented with the exact tool and device configuration.
8. At least one measured optimization is demonstrated under comparable build conditions, with its latency and resource tradeoffs reported.
9. Simulation and implementation can be reproduced from documented commands and checked-in scripts.
10. The repository explains architecture, verification evidence, implementation limits, and results clearly enough to support a technical interview.

---

## 13. Expected Resume Entry

The following is a draft for use after the success criteria have been met. Final wording will reflect completed work and measured results.

**FPGA Streaming DSP Accelerator — Independent Project**  
*Dec. 2026 – Jan. 2027*

- Designed a parameterized pipelined DSP accelerator in SystemVerilog with AXI4-Stream data interfaces and AXI4-Lite configuration registers.
- Built a self-checking SystemVerilog verification environment with randomized traffic, backpressure, assertions, and corner-case testing.
- Developed a Python golden-reference model and automated regression workflow to validate RTL functionality and numerical correctness.
- Synthesized and implemented the design in Vivado, analyzed critical paths and FPGA resource utilization, and optimized the datapath to improve timing performance.

---

## 14. Expected Skill Development

Upon completion, the project should provide practical experience in:

**SystemVerilog · Verilog · RTL Design · AXI4-Stream · AXI4-Lite · FPGA Architecture · Digital Signal Processing · Pipelining · FIFO Design · SystemVerilog Assertions · RTL Verification · Python Automation · Vivado · Synthesis · Static Timing Analysis · FPGA Resource Optimization**
