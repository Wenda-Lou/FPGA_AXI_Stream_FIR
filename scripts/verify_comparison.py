"""Verify and archive a controlled, full-top post-route optimization comparison.

The baseline may fail SETUP timing. That outcome is measured evidence, never a
passing implementation. Both builds must pass functional, hold, coverage and
module-boundary routing checks; the optimized build must also pass setup.
"""

import argparse
import csv
import json
import math
import re
import shutil
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

from prepare_comparison import ROOT, BUILD, FILES, RTL, CORE, baseline_core, digest
from verify_implementation import REPORTS

ARCHIVE = ROOT / "reports/implementation_comparison"
ZERO_CHECKS = (
    "no_clock", "constant_clock", "pulse_width_clock", "unconstrained_internal_endpoints",
    "no_input_delay", "no_output_delay", "multiple_clock", "generated_clocks", "loops",
    "latch_loops", "partial_input_delay", "partial_output_delay", "severe_drc",
    "severe_methodology", "missing_boundary_ports", "missing_boundary_anchors", "unexpected_route_nets",
)
HASH_KEYS = {
    "fifo_sha256": RTL + "axis_fifo.v", "core_sha256": CORE,
    "datapath_sha256": RTL + "dsp_datapath.v", "regs_sha256": RTL + "axi_lite_regs.v",
    "rtl_sha256": RTL + "dsp_accelerator.v",
    "testbench_sha256": "fpga_streaming_dsp/fpga_streaming_dsp.srcs/sim_1/tb_dsp_accelerator.sv",
    "model_sha256": "model/fir.py", "comparator_sha256": "scripts/compare_fir_events.py",
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def table(path):
    with path.open(encoding="utf-8-sig", newline="") as stream:
        return list(csv.DictReader(stream, delimiter="\t"))


def text(path):
    return path.read_text(encoding="utf-8-sig", errors="replace")


def sha(path):
    return digest(path.read_bytes())


def finite(value):
    number = float(value)
    require(math.isfinite(number), f"Non-finite result: {value}")
    return number


def config(run):
    return tuple(run[key] for key in ("taps", "input_width", "coeff_width", "output_width",
                 "input_frac", "coeff_frac", "output_frac", "input_depth", "output_depth", "seed"))


def verify_regression(root, expected):
    sim = root / "build/accelerator_sim"
    result = json.loads(text(sim / "results.json"))
    require(result["status"] == "passed" and len(result["runs"]) == 47, "Incomplete 47-run regression")
    for key, name in HASH_KEYS.items():
        require(result[key] == expected[name], f"Simulation source differs: {name}")
    required = {(8,16,16,16,15,15,15,16,16,seed): 10000 for seed in range(1, 21)}
    for dims in ((8,16,16,16,15,15,15,2,2), (8,16,16,16,15,15,15,2,16),
                 (8,16,16,16,15,15,15,16,2), (1,16,16,16,15,15,15,2,4),
                 (4,8,8,8,7,7,7,4,2), (4,12,10,14,9,8,10,4,8),
                 (1,4,4,12,0,0,0,2,2), (32,16,16,16,15,15,15,4,4),
                 (4,8,32,32,0,0,0,4,4)):
        for seed in (1, 7, 42):
            required[dims + (seed,)] = 1000
    require({config(run) for run in result["runs"]} == set(required), "Wrong regression configuration/seed matrix")
    records = []
    for run in result["runs"]:
        require(run["random_samples"] >= required[config(run)], "Insufficient random sample count")
        require(run["python_status"] == "passed" and run["max_streak"] >= 1024, "Numerical/throughput failure")
        require(run["writes"] == run["reads"] + run["reset_discarded"], "Unexplained data loss")
        log_path = sim / run["log"]
        log = text(log_path)
        require(not re.search(r"^\s*(fatal|error)\s*:", log, re.I | re.M), "Simulator error/fatal")
        require("PASS: dsp_accelerator " in log and "PASS directed: AXI-programmed arithmetic and continuous streaming" in log,
                "Missing functional/latency test PASS")
        summary_path = sim / (Path(run["events"]).name.removesuffix(".events.txt") + ".python.json")
        python = json.loads(text(summary_path))
        require(python["status"] == "passed" and python["inputs"] == run["writes"] and
                python["outputs"] == python["saturation_checks"] == run["reads"] and
                python["reset_discarded"] == run["reset_discarded"], "Python/HDL accounting disagreement")
        event_path = sim / run["events"]
        records.append({"configuration_and_seed": config(run), "events_sha256": sha(event_path),
                        "log_sha256": sha(log_path), "python_summary_sha256": sha(summary_path)})
    summary = {
        "status": "passed", "runs": 47,
        "random_accepted_inputs": sum(run["random_samples"] for run in result["runs"]),
        "accepted_inputs": sum(run["writes"] for run in result["runs"]),
        "matched_outputs_and_flags": sum(run["reads"] for run in result["runs"]),
        "reset_discarded": sum(run["reset_discarded"] for run in result["runs"]),
        "minimum_continuous_outputs": min(run["max_streak"] for run in result["runs"]),
        "top_latency_cycles": 4, "core_latency_cycles": 2,
        "throughput_samples_per_clock": 1,
        "latency_evidence": "Unchanged bench asserts every no-stall continuous output is exactly four edges after its input; the two FIR valid stages are unchanged",
        "regression_sha256": sha(sim / "results.json"), "runs_evidence": records,
    }
    return result, summary


def verify_physical(root, expected, baseline):
    build = root / "build/accelerator_impl"
    for name in REPORTS + ("dsp_accelerator_routed.dcp", "implementation.log", "process_exit_code.txt"):
        require((build / name).is_file(), f"Missing completed physical evidence: {name}")
    acceptance = dict(line.split("\t", 1) for line in text(build / "acceptance.tsv").splitlines() if "\t" in line)
    for key in ZERO_CHECKS:
        require(acceptance.get(key) == "0", f"Non-setup acceptance failure: {key}={acceptance.get(key)}")
    setup = finite(acceptance["setup_wns_ns"])
    hold = finite(acceptance["hold_slack_ns"])
    pulse = finite(acceptance["pulse_width_slack_ns"])
    require(hold >= 0 and pulse >= 0, "Hold/pulse violations are never allowed in this comparison")
    setup_failed = setup < 0
    require(baseline or not setup_failed, "Optimized design fails setup")
    require(acceptance["status"] == ("failed" if setup_failed else "passed"), "Incorrect physical acceptance status")
    failures = acceptance["failures"].split("; ") if acceptance["failures"] else []
    require(all(reason.startswith("negative setup/hold slack:") or
                reason in {"timing summary violations at column 0", "timing summary violations at column 1",
                           "timing summary violations at column 2"} for reason in failures),
            f"Unexpected baseline physical failure: {failures}")
    if setup_failed:
        require(any(reason.startswith("negative setup/hold slack:") for reason in failures), "Missing baseline setup-failure reason")
    else:
        require(not failures, "Passing physical design has failure reasons")
    timing = text(build / "timing_post_route.rpt")
    values = None
    for line in timing.splitlines():
        fields = line.split()
        if len(fields) == 12 and all(re.fullmatch(r"-?\d+(?:\.\d+)?", field) for field in fields):
            values = [finite(field) for field in fields]
            break
    require(values is not None and values[0] == setup and values[4] == hold and values[8] == pulse,
            "Acceptance/timing summary disagree")
    require(all(values[index] == 0 for index in (5, 6, 9, 10)), "Hold/pulse negative totals or failing endpoints")
    require(setup_failed or values[1] == values[2] == 0, "Nonzero setup violation totals in a passing design")
    require(not setup_failed or (values[1] < 0 and values[2] > 0), "Baseline setup failure lacks negative totals/endpoints")
    for key in ZERO_CHECKS[:12]:
        match = re.search(r"checking\s+" + key + r"\s+\((\d+)\)", timing)
        require(match is not None and match[1] == "0", f"Timing report coverage failure: {key}")

    inputs = table(build / "inputs.tsv")
    physical_inputs = {RTL + name for name in
                       ("axis_fifo.v", "fir_core.v", "dsp_datapath.v", "axi_lite_regs.v", "dsp_accelerator.v")} | {
                       "scripts/implement_accelerator.tcl", "scripts/implementation_utils.tcl",
                       "constraints/dsp_accelerator_timing.xdc", "constraints/dsp_accelerator_ooc.xdc"}
    require(len(inputs) == 9 and {row["path"] for row in inputs} == physical_inputs, "Incomplete physical source manifest")
    for row in inputs:
        require(row["path"] in expected, "Unexpected implementation input")
        path = root / row["path"]
        require(path.stat().st_size == int(row["size"]) and int(path.stat().st_mtime) == int(row["mtime"]),
                "Implementation input edited after start")
        require(sha(path) == expected[row["path"]], "Physical source differs from snapshot")
    classes = table(build / "path_classes.tsv")
    pairs = {(name, kind) for name in ("register_to_register", "input_to_register", "register_to_output", "input_to_output")
             for kind in ("max", "min")}
    require({(row["class"], row["check"]) for row in classes} == pairs and len(classes) == 8, "Missing path class")
    require(all(finite(row["slack_ns"]) >= 0 or (baseline and row["check"] == "max") for row in classes),
            "Failing path class beyond baseline setup")
    boundaries = [row for row in table(build / "boundary_ports.tsv") if row["functional"] == "1"]
    require(len(boundaries) == int(acceptance["functional_ports"]) == 115 and
            all(row["partition_pin"] and row["anchor_in_route"] == "1" for row in boundaries), "Missing physical anchor")
    identities = table(build / "identity_buffers.tsv")
    require(len(identities) == int(acceptance["identity_buffers"]) and
            len({row["cell"] for row in identities}) == len(identities), "Hold repair count disagreement")
    require(all(row["init"].lower() in ("2'h2", "2'b10", "2'd2", "0x2", "2") and row["input_net"] and row["output_net"]
                for row in identities), "Non-identity/disconnected repair cell")
    require(sum(int(row["identity_luts"]) for row in table(build / "hold_repairs.tsv")) == len(identities), "Repair totals mismatch")
    iterations = table(build / "iterations.tsv")
    require(iterations and len(iterations) <= 6 and
            [int(row["iteration"]) for row in iterations] == list(range(len(iterations))) and
            sum(int(row["added_identity_luts"]) for row in iterations) == len(identities) and
            finite(iterations[-1]["setup_wns_ns"]) == setup and finite(iterations[-1]["hold_slack_ns"]) == hold,
            "Repair iteration/final checkpoint mismatch")
    effective = text(build / "implemented_constraints.xdc")
    require(not re.search(r"^\s*(set_false_path|set_multicycle_path|set_disable_timing|set_case_analysis)\b", effective, re.M),
            "Undeclared timing exception")
    timing_commands = [line.strip() for line in effective.splitlines() if
                       re.match(r"^\s*(create_clock|set_clock_uncertainty|set_input_delay|set_output_delay)\b", line)]
    clocks = text(build / "clocks.rpt")
    for clock in ("clk", "interface_clk"):
        require(re.search(r"^" + clock + r"\s+10\.000\s+\{0\.000 5\.000\}", clocks, re.M), "Clock period/waveform changed")
    for command in (
        "set_input_delay -clock [get_clocks interface_clk] -min 0.500",
        "set_input_delay -clock [get_clocks interface_clk] -max 2.000",
        "set_output_delay -clock [get_clocks interface_clk] -min -0.500",
        "set_output_delay -clock [get_clocks interface_clk] -max 2.000",
    ):
        require(any(line.startswith(command + " ") for line in timing_commands), "I/O timing budget changed")
    log = text(build / "implementation.log")
    exit_code = int(text(build / "process_exit_code.txt").strip())
    if setup_failed:
        require(exit_code != 0 and "Accelerator implementation acceptance failed:" in log, "Baseline setup failure not reported")
    else:
        require(exit_code == 0 and "PASS: dsp_accelerator routed implementation" in log, "Missing successful physical completion")
    messages = re.findall(r"^(WARNING|CRITICAL WARNING|ERROR): \[([^\]]+)\]\s*(.*)", log, re.M)
    for severity, identifier, message in messages:
        require(severity != "CRITICAL WARNING" or identifier == "Route 35-39", f"Unexpected critical warning: {identifier}")
        require(severity != "ERROR" or (setup_failed and "Accelerator implementation acceptance failed:" in message),
                f"Unexpected tool error: {identifier}: {message}")
    util = text(build / "utilization_post_route.rpt")
    require(re.search(r"Device\s*:\s*xc7a35tcpg236-1\b", util), "Implementation part changed")

    def used(label):
        match = re.search(r"\|\s*" + label + r"\s*\|\s*(\d+)", util)
        require(match is not None, f"Missing utilization: {label}")
        return int(match[1])

    tool = re.search(r"Tool Version\s*:\s*(.+)", timing)
    require(tool is not None, "Missing tool identity")
    source = re.search(r"^\s*Source:\s*(\S+)", timing, re.M)
    destination = re.search(r"^\s*Destination:\s*(\S+)", timing, re.M)
    path_delay = re.search(r"Data Path Delay:\s*([\d.]+)ns", timing)
    levels = re.search(r"Logic Levels:\s*(\d+)\s*\(([^\n]+)\)", timing)
    require(all((source, destination, path_delay, levels)), "Missing worst setup-path evidence")
    return {
        "implementation_status": "fails_100mhz_setup" if setup_failed else "passes_100mhz_module_context",
        "tool": tool[1].strip(), "setup_wns_ns": setup, "setup_tns_ns": values[1],
        "setup_failing_endpoints": int(values[2]), "hold_slack_ns": hold,
        "hold_total_negative_slack_ns": values[5], "hold_failing_endpoints": int(values[6]),
        "pulse_width_slack_ns": pulse,
        "luts": used(r"Slice LUTs\*?"), "flip_flops": used("Slice Registers"),
        "dsps": used("DSPs"), "bram_tiles": used("Block RAM Tile"), "identity_buffers": len(identities),
        "acceptance": acceptance, "path_classes": classes, "iterations": iterations,
        "timing_commands": timing_commands,
        "worst_setup_path": {"source": source[1], "destination": destination[1],
                             "data_path_delay_ns": finite(path_delay[1]), "logic_levels": int(levels[1]),
                             "logic_composition": levels[2]},
        "warning_counts": dict(Counter(identifier for _, identifier, _ in messages)),
        "warning_examples": {identifier: message for _, identifier, message in reversed(messages)},
        "process_exit_code": exit_code,
        "report_sha256": {name: sha(build / name) for name in REPORTS},
        "implementation_log_sha256": sha(build / "implementation.log"),
        "routed_checkpoint_sha256": sha(build / "dsp_accelerator_routed.dcp"),
        "source_sha256": expected,
    }


def verify():
    manifest = json.loads(text(BUILD / "sources.json"))
    require(set(manifest["inputs"]) == set(FILES), "Incomplete frozen source set")
    for name, expected in manifest["inputs"].items():
        require(sha(ROOT / name) == expected, f"Canonical comparison input changed: {name}")
    require(sha(ROOT / manifest["historical_linear_reference"]) == manifest["historical_linear_reference_sha256"],
            "Historical baseline reference changed")
    original = (ROOT / CORE).read_text(encoding="utf-8")
    require((BUILD / "baseline" / CORE).read_text(encoding="utf-8") == baseline_core(original), "Unexpected baseline transformation")
    records, regressions = {}, {}
    for variant in ("baseline", "optimized"):
        root = BUILD / variant
        hashes = manifest["variants"][variant]
        require(set(hashes) == set(FILES), "Incomplete variant source set")
        for name, expected in hashes.items():
            require(sha(root / name) == expected, f"Frozen variant input changed: {variant}/{name}")
            if variant == "optimized" or name != CORE:
                require(expected == manifest["inputs"][name], "Unexpected difference beyond baseline FIR")
        regression, functional = verify_regression(root, hashes)
        physical = verify_physical(root, hashes, baseline=variant == "baseline")
        physical["functional"] = functional
        records[variant], regressions[variant] = physical, regression
    base, opt = records["baseline"], records["optimized"]
    require(base["tool"] == opt["tool"], "Tool versions differ")
    require(base["timing_commands"] == opt["timing_commands"], "Effective timing constraints differ")
    for key in ("clock_source_site", "boundary_range", "functional_ports"):
        require(base["acceptance"][key] == opt["acceptance"][key], f"Physical contract differs: {key}")
    # Numerical traces are cycle-free handshakes, including configuration/reset
    # events. Equality confirms the same randomized workload and completed data.
    base_runs = base["functional"]["runs_evidence"]
    opt_runs = opt["functional"]["runs_evidence"]
    require([(run["configuration_and_seed"], run["events_sha256"]) for run in base_runs] ==
            [(run["configuration_and_seed"], run["events_sha256"]) for run in opt_runs], "Workload/result event traces differ")
    improvement = round(opt["setup_wns_ns"] - base["setup_wns_ns"], 3)
    require(improvement > 0 or opt["luts"] < base["luts"], "No measured timing/resource optimization")
    summary = {
        "status": "verified_comparison", "recorded_at_utc": datetime.now(timezone.utc).isoformat(),
        "scope": "Full dsp_accelerator OOC module, identical declared interface and parent context; not board or assembled-parent acceptance",
        "baseline_definition": manifest["description"], "device": "xc7a35tcpg236-1",
        "clock_period_ns": 10.0, "input_delay_ns": {"min": 0.5, "max": 2.0},
        "output_delay_ns": {"min": -0.5, "max": 2.0}, "uncertainty_ns": {"setup": 0.1, "hold": 0.05},
        "strategy": "Byte-identical synth/opt/place/physopt/route Tcl, general.maxThreads=2, same <=5-iteration measured input-hold-repair rule",
        "seed_policy": "No placement-seed override is set; same Vivado defaults and directives. One physical run per variant, not a statistical study.",
        "same_47_handshake_event_traces": True,
        "setup_slack_improvement_ns": improvement,
        "resource_delta_optimized_minus_baseline": {key: opt[key] - base[key] for key in
                                                  ("luts", "flip_flops", "dsps", "bram_tiles", "identity_buffers")},
        "baseline": base, "optimized": opt,
        "limitations": [
            "No frequency sweep: 100 MHz pass/fail and slack only, not Fmax.",
            "No gate-level timing simulation; RTL regression and identity-LUT audits support functional preservation.",
            "Adaptive hold repairs follow the same policy but can use different LUT counts and iteration counts; costs are reported.",
            "Raw whole-design routing retains intentional parent-boundary ANTENNAS; all 115 functional physical anchors and internal routes are audited.",
            "Constraints 18-8777, if present, remains an unresolved OOC tool/context warning; parent reuse requires revalidation.",
        ],
        "sources_manifest_sha256": sha(BUILD / "sources.json"),
        "workflow_sha256": {name: sha(ROOT / name) for name in
                            ("scripts/prepare_comparison.py", "scripts/run_comparison.ps1", "scripts/verify_comparison.py",
                             "scripts/verify_implementation.py")},
    }
    return manifest, summary


def archive(manifest, summary):
    # Publish only after every check on BOTH builds passes. Never replace the
    # separate historical implementation or synthesis evidence.
    for variant in ("baseline", "optimized"):
        root = BUILD / variant
        destination = ARCHIVE / variant
        destination.mkdir(parents=True, exist_ok=True)
        for name in REPORTS + ("process_exit_code.txt",):
            shutil.copyfile(root / "build/accelerator_impl" / name, destination / name)
        shutil.copyfile(root / "build/accelerator_impl/implementation.log", destination / "implementation_log.txt")
        shutil.copyfile(root / "build/accelerator_sim/results.json", destination / "regression_results.json")
        # Logs and Python summaries are small; raw event files and DCPs stay
        # generated under build/, identified by SHA-256 in the summary.
        sim = root / "build/accelerator_sim"
        for run in json.loads(text(sim / "results.json"))["runs"]:
            evidence = destination / "simulation"
            evidence.mkdir(exist_ok=True)
            for name in (run["log"], Path(run["events"]).name.removesuffix(".events.txt") + ".python.json"):
                archived_name = name.removesuffix(".log") + ".txt" if name.endswith(".log") else name
                shutil.copyfile(sim / name, evidence / archived_name)
        for name in FILES:
            target = destination / "sources" / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(root / name, target)
    shutil.copyfile(BUILD / "sources.json", ARCHIVE / "sources.json")
    output = json.dumps(summary, indent=2) + "\n"
    (BUILD / "summary.json").write_text(output, encoding="utf-8")
    (ARCHIVE / "summary.json").write_text(output, encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.parse_args()
    try:
        manifest, summary = verify()
        archive(manifest, summary)
        for variant in ("baseline", "optimized"):
            record = summary[variant]
            print(f"{variant}: 47 functional runs passed; {record['implementation_status']}; "
                  f"setup={record['setup_wns_ns']:+.3f} ns hold={record['hold_slack_ns']:+.3f} ns; "
                  f"LUT={record['luts']} FF={record['flip_flops']} DSP={record['dsps']}")
        print(f"PASS: verified comparison; setup slack improvement={summary['setup_slack_improvement_ns']:.3f} ns")
    except (OSError, ValueError, KeyError) as error:
        parser.exit(1, f"Comparison verification failed: {error}\n")


if __name__ == "__main__":
    main()
