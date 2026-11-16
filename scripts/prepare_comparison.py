"""Freeze isolated full-top builds differing only in FIR accumulation structure."""

import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "build/implementation_comparison"
RTL = "fpga_streaming_dsp/fpga_streaming_dsp.srcs/sources_1/new/"
CORE = RTL + "fir_core.v"
FILES = [RTL + name for name in (
    "axis_fifo.v", "fir_core.v", "dsp_datapath.v", "axi_lite_regs.v", "dsp_accelerator.v"
)] + [
    "fpga_streaming_dsp/fpga_streaming_dsp.srcs/sim_1/tb_dsp_accelerator.sv",
    "model/__init__.py", "model/fir.py", "scripts/compare_fir_events.py",
    "scripts/run_accelerator.ps1", "scripts/implement_accelerator.tcl",
    "scripts/implementation_utils.tcl", "constraints/dsp_accelerator_timing.xdc",
    "constraints/dsp_accelerator_ooc.xdc",
]


def digest(data):
    return hashlib.sha256(data).hexdigest().upper()


def baseline_core(source):
    """Restore the historical linear sum in the current, otherwise identical shell.

    Leave the corrected history depth, parameter guards, clears, valid stages,
    signed scaling and saturation identical. Do not constrain synthesis to use
    fabric for the baseline adders: the old implementation allowed DSP mapping.
    """
    old = "    wire signed [ACC_WIDTH-1:0] sum_tree [0:2*TAPS-2];\n    wire signed [ACC_WIDTH-1:0] acc_sum;"
    if source.count(old) != 1:
        raise ValueError("FIR tree declarations changed; review the comparison")
    source = source.replace(old, "    reg signed [ACC_WIDTH-1:0] acc_sum;")
    source = source.replace("    integer i, j;", "    integer i, j, t;")
    start = source.index("            if (GROWTH_BITS > 0) begin : extend_product")
    end = source.index("        if (TAPS > 1) begin : sample_history", start)
    source = source[:start] + "        end\n" + source[end:]
    old = "    assign acc_sum = sum_tree[0];"
    if source.count(old) != 1:
        raise ValueError("FIR tree root changed; review the comparison")
    source = source.replace(old, """    // Baseline: the historical full-precision, left-to-right accumulation.
    // Synthesis is free to choose its original DSP/fabric mapping. No keep or
    // dont_touch attribute is added to make this baseline artificially slower.
    always @(*) begin
        acc_sum = {ACC_WIDTH{1'b0}};
        for (t = 0; t < TAPS; t = t + 1)
            acc_sum = acc_sum + $signed({{GROWTH_BITS{products[t][PRODUCT_WIDTH-1]}}, products[t]});
    end""")
    if "sum_tree" in source or "use_dsp" in source:
        raise ValueError("Incomplete baseline reconstruction")
    return source


def prepare():
    manifest = {
        "description": "Controlled baseline reconstruction: only FIR sum structure/mapping hint differs; canonical RTL is untouched",
        "inputs": {name: digest((ROOT / name).read_bytes()) for name in FILES},
        "historical_linear_reference": "reports/fir_core/baseline_rtl.txt",
        "historical_linear_reference_sha256": digest((ROOT / "reports/fir_core/baseline_rtl.txt").read_bytes()),
        "variants": {},
    }
    for variant in ("baseline", "optimized"):
        hashes = {}
        for name in FILES:
            data = (ROOT / name).read_bytes()
            if variant == "baseline" and name == CORE:
                data = baseline_core(data.decode("utf-8").replace("\r\n", "\n")).encode("utf-8")
            path = BUILD / variant / name
            path.parent.mkdir(parents=True, exist_ok=True)
            # Preserve timestamps for an identical existing snapshot, so a
            # verification-only invocation cannot invalidate an implementation.
            if not path.exists() or path.read_bytes() != data:
                path.write_bytes(data)
            hashes[name] = digest(data)
        manifest["variants"][variant] = hashes
    BUILD.mkdir(parents=True, exist_ok=True)
    (BUILD / "sources.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(f"Prepared identical-context comparison snapshots: {BUILD}")


if __name__ == "__main__":
    prepare()
