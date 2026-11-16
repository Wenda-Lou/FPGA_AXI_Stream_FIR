# v1.0.0 Acceptance Evidence

Validated source commit: [`31d1718`](https://github.com/Wenda-Lou/fpga-axi-stream-fir/commit/31d1718d40261cf46c5afcbd03642b19dc3e41bc).
Validated Git tree: `b3869e1d00e805d7d379c498c34a0b8b89cf62dc`. The final handoff commit adds documentation and
frozen evidence without changing the executed sources.

The source tree was exported without `.git`, `build/`, simulator snapshots or
checkpoints, then passed 27 Python tests and 285 HDL simulations, including two
physical module builds and supplemental waveform capture. This is one clean
export on the same workstation/tool installation, not a second-machine test.

- [Complete acceptance and phase timings](release/summary.json).
- [Both physical builds, source/report hashes and explicit baseline failure](physical_comparison/summary.json).
- [Waveform provenance](waveforms/summary.json), [raw VCD](waveforms/accelerator.vcd)
  and [accepted-event trace](waveforms/waveform.events.txt).
- [Clean export marker](clean_export.json) and [exact archive hashes](manifest.json).
- [Project overview and reproduction](../../../readme.md).

The optimized module passes setup +0.273 ns and hold +0.031 ns at the declared
100 MHz OOC interface/parent context. Baseline setup remains a failed result.
Parent-boundary routes and the unresolved `Constraints 18-8777` warning retain
the limitations described in the implementation documentation. No board,
assembled-parent, gate-level timing, formal-proof or measured-Fmax claim is made.
