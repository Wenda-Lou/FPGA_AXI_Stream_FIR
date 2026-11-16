"""Freeze executed sources, then verify the complete release acceptance flow."""

import argparse
import hashlib
import json
import re
import shutil
from datetime import datetime, timezone
from pathlib import Path

from prepare_comparison import FILES, RTL
from verify_comparison import verify as verify_physical_comparison, verify_regression

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "build/release"
ARCHIVE = ROOT / "reports/release"
PHASES = ("reference", "fifo", "fir", "datapath", "axi_regs", "accelerator", "comparison", "waveforms")
COUNTS = {"fifo": 32, "fir": 38, "datapath": 41, "axi_regs": 32, "accelerator": 47}


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest().upper()


def read(path):
    return path.read_text(encoding="utf-8-sig", errors="replace")


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sources():
    paths = {ROOT / ".gitattributes"}
    for directory, patterns in (("scripts", ("*.py", "*.ps1", "*.tcl")), ("model", ("*.py",)),
                                 ("tests", ("*.py",)), ("constraints", ("*.xdc",)),
                                 ("fpga_streaming_dsp/fpga_streaming_dsp.srcs/sources_1/new", ("*.v",)),
                                 ("fpga_streaming_dsp/fpga_streaming_dsp.srcs/sim_1", ("*.sv",))):
        for pattern in patterns:
            paths.update((ROOT / directory).glob(pattern))
    return {path.relative_to(ROOT).as_posix(): sha(path) for path in sorted(paths)}


def freeze():
    BUILD.mkdir(parents=True, exist_ok=True)
    (BUILD / "inputs.json").write_text(json.dumps(sources(), indent=2) + "\n", encoding="utf-8")
    (BUILD / "steps.json").write_text('{"status":"incomplete","steps":[]}\n', encoding="utf-8")
    print("Frozen release code/constraint inputs; previous PASS markers invalidated")


def verify():
    inputs = json.loads(read(BUILD / "inputs.json"))
    require(inputs == sources(), "Executed source inputs changed during release acceptance")
    steps = json.loads(read(BUILD / "steps.json"))
    require(steps["status"] == "passed" and tuple(step["name"] for step in steps["steps"]) == PHASES and
            all(step["exit_code"] == 0 for step in steps["steps"]), "Incomplete/failing release phases")
    reference = read(BUILD / "reference.stdout.txt") + read(BUILD / "reference.stderr.txt")
    test_count = re.search(r"Ran (\d+) tests? in", reference)
    require(test_count is not None and int(test_count[1]) >= 27 and re.search(r"^OK\s*$", reference, re.M), "Python reference tests failed")
    artifacts, suites = {}, {}
    modules = {"fifo": "axis_fifo", "fir": "fir_core", "datapath": "dsp_datapath", "axi_regs": "axi_lite_regs", "accelerator": "dsp_accelerator"}
    for name, count in COUNTS.items():
        folder = ROOT / "build" / (name + "_sim")
        path = folder / "results.json"
        result = json.loads(read(path))
        require(result["status"] == "passed" and len(result["runs"]) == count, f"Incomplete {name} matrix")
        rtl = ROOT / RTL / (modules[name] + ".v")
        require(result["rtl_sha256"] == sha(rtl), f"{name}: wrong simulated RTL")
        bench = ROOT / "fpga_streaming_dsp/fpga_streaming_dsp.srcs/sim_1" / ("tb_" + modules[name] + ".sv")
        require(result["testbench_sha256"] == sha(bench), f"{name}: wrong simulated bench")
        for run in result["runs"]:
            log = read(folder / run["log"])
            require("PASS:" in log and not re.search(r"^\s*(fatal|error)\s*:", log, re.I | re.M), f"{name}: simulation failed")
            if name != "axi_regs":
                require(run["writes"] == run["reads"] + run["reset_discarded"], f"{name}: unexplained data loss")
            if "python_status" in run:
                require(run["python_status"] == "passed", f"{name}: Python comparison failed")
        suites[name] = {"status": "passed", "runs": count, "results_sha256": sha(path)}
        artifacts[name + "_results.json"] = path
    expected = {name: sha(ROOT / name) for name in FILES}
    _, integrated = verify_regression(ROOT, expected)
    _, comparison = verify_physical_comparison()
    wave = json.loads(read(ROOT / "reports/waveforms/summary.json"))
    require(wave["status"] == "passed", "Waveform evidence failed")
    for name, expected_sha in {**wave["source_sha256"], **wave["artifact_sha256"]}.items():
        require(sha(ROOT / name) == expected_sha, f"Waveform evidence changed: {name}")
    require(sha(ROOT / "build/waveforms/accelerator.vcd") == wave["vcd_sha256"], "Captured VCD changed")
    require(sha(ROOT / "build/waveforms/waveform.events.txt") == wave["events_sha256"], "Waveform event trace changed")
    summary = {
        "status": "passed", "recorded_at_utc": datetime.now(timezone.utc).isoformat(),
        "scope": "Complete software/RTL/module-context acceptance; not board, assembled-parent or gate-level timing acceptance",
        "python_tests": int(test_count[1]), "suites": suites,
        "canonical_hdl_runs": sum(COUNTS.values()), "comparison_hdl_runs": 94,
        "supplemental_waveform_runs": 1, "total_hdl_runs": sum(COUNTS.values()) + 95,
        "integrated_outputs_matched": integrated["matched_outputs_and_flags"],
        "four_clock_top_latency": True, "minimum_continuous_outputs": integrated["minimum_continuous_outputs"],
        "physical": {variant: {key: comparison[variant][key] for key in
                                ("implementation_status", "setup_wns_ns", "hold_slack_ns", "luts", "flip_flops", "dsps")}
                     for variant in ("baseline", "optimized")},
        "setup_slack_improvement_ns": comparison["setup_slack_improvement_ns"],
        "source_sha256": inputs, "steps": steps["steps"],
        "limitations": comparison["limitations"],
    }
    if (ROOT / "clean_export.json").is_file():
        summary["clean_export"] = json.loads(read(ROOT / "clean_export.json"))
        require(summary["clean_export"].get("build_directory_present_before_run") is False, "Export was not clean")
    ARCHIVE.mkdir(parents=True, exist_ok=True)
    for name, path in artifacts.items():
        shutil.copyfile(path, ARCHIVE / name)
    for name in ("inputs.json", "steps.json", *[phase + suffix for phase in PHASES for suffix in (".stdout.txt", ".stderr.txt")]):
        shutil.copyfile(BUILD / name, ARCHIVE / name)
    summary["artifact_sha256"] = {path.name: sha(path) for path in ARCHIVE.iterdir() if path.is_file() and path.name != "summary.json"}
    (ARCHIVE / "summary.json").write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    print(f"PASS: release acceptance: {summary['python_tests']} Python tests; {summary['total_hdl_runs']} HDL runs; "
          f"optimized setup={comparison['optimized']['setup_wns_ns']:+.3f} ns hold={comparison['optimized']['hold_slack_ns']:+.3f} ns")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--start", action="store_true")
    args = parser.parse_args()
    try:
        freeze() if args.start else verify()
    except (OSError, ValueError, KeyError) as error:
        parser.exit(1, f"Release acceptance failed: {error}\n")


if __name__ == "__main__":
    main()
