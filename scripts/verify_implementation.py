"""Validate and optionally archive the complete accelerator's OOC implementation."""

import argparse
import csv
import hashlib
import json
import math
import re
import shutil
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REPORTS = (
    "acceptance.tsv", "inputs.tsv", "path_classes.tsv", "boundary_ports.tsv",
    "identity_buffers.tsv", "hold_repairs.tsv", "iterations.tsv",
    "timing_post_route.rpt", "check_timing.rpt", "utilization_post_route.rpt",
    "route_status.rpt", "drc_post_route.rpt", "methodology.rpt", "clocks.rpt",
    "clock_interaction.rpt", "exceptions.rpt", "implemented_constraints.xdc",
)


def rows(path):
    with path.open(encoding="utf-8-sig", newline="") as stream:
        return list(csv.DictReader(stream, delimiter="\t"))


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest().upper()


def verify(build):
    for name in REPORTS:
        require((build / name).is_file(), f"Missing implementation evidence: {name}")
    acceptance = dict(line.split("\t", 1) for line in
                      (build / "acceptance.tsv").read_text().splitlines() if "\t" in line)
    require(acceptance.get("status") == "passed", "Vivado implementation has not passed")
    zero_checks = (
        "no_clock", "constant_clock", "pulse_width_clock", "unconstrained_internal_endpoints",
        "no_input_delay", "no_output_delay", "multiple_clock", "generated_clocks", "loops",
        "latch_loops", "partial_input_delay", "partial_output_delay", "severe_drc",
        "severe_methodology", "missing_boundary_ports", "missing_boundary_anchors", "unexpected_route_nets",
    )
    for name in zero_checks:
        require(acceptance.get(name) == "0", f"Acceptance check failed or absent: {name}")
    for name in ("setup_wns_ns", "hold_slack_ns", "pulse_width_slack_ns"):
        value = float(acceptance[name])
        require(math.isfinite(value) and value >= 0, f"Invalid slack: {name}={value}")

    # Refuse stale reports after an incidental edit to any input used by Vivado.
    # The manifest is captured before synthesis; SHA-256 is recorded for review.
    hashes = {}
    for row in rows(build / "inputs.tsv"):
        path = (ROOT / row["path"]).resolve()
        require(path.is_relative_to(ROOT), "Input manifest path escapes the repository")
        stat = path.stat()
        require(stat.st_size == int(row["size"]) and int(stat.st_mtime) == int(row["mtime"]),
                f"Implementation input changed after run started: {row['path']}")
        hashes[row["path"]] = digest(path)
    require(len(hashes) == 9, "Incomplete implementation input manifest")
    regression = json.loads((ROOT / "reports/accelerator/regression_results.json").read_text(encoding="utf-8-sig"))
    require(regression["status"] == "passed", "Complete-top RTL regression is not passed")
    for key, name in (("fifo_sha256", "axis_fifo.v"), ("core_sha256", "fir_core.v"),
                      ("datapath_sha256", "dsp_datapath.v"), ("regs_sha256", "axi_lite_regs.v"),
                      ("rtl_sha256", "dsp_accelerator.v")):
        relative = "fpga_streaming_dsp/fpga_streaming_dsp.srcs/sources_1/new/" + name
        require(hashes[relative] == regression[key], f"Implemented RTL differs from verified RTL: {name}")

    classes = rows(build / "path_classes.tsv")
    expected_classes = {(name, kind) for name in ("register_to_register", "input_to_register",
                        "register_to_output", "input_to_output") for kind in ("max", "min")}
    require({(row["class"], row["check"]) for row in classes} == expected_classes,
            "Missing internal or interface path class")
    for row in classes:
        value = float(row["slack_ns"])
        require(math.isfinite(value) and value >= 0, f"Failing path class: {row}")
    timing_values = None
    for line in (build / "timing_post_route.rpt").read_text().splitlines():
        fields = line.split()
        if len(fields) == 12 and all(re.fullmatch(r"-?\d+(?:\.\d+)?", field) for field in fields):
            timing_values = [float(field) for field in fields]
            break
    require(timing_values is not None, "Missing complete Design Timing Summary")
    require(all(timing_values[index] == 0 for index in (1, 2, 5, 6, 9, 10)),
            "Nonzero setup/hold/pulse violation totals or endpoints")
    boundary = rows(build / "boundary_ports.tsv")
    functional = [row for row in boundary if row["functional"] == "1"]
    require(len(functional) == int(acceptance["functional_ports"]) > 0, "Missing functional boundary evidence")
    require(all(row["partition_pin"] and row["anchor_in_route"] == "1" for row in functional),
            "A functional port does not reach its declared physical partition node")
    identities = rows(build / "identity_buffers.tsv")
    require(len(identities) == int(acceptance["identity_buffers"]), "Identity buffer count mismatch")
    require(len({row["cell"] for row in identities}) == len(identities), "Duplicate hold cell")
    require(all(row["init"].lower() in ("2'h2", "2'b10", "2'd2", "0x2", "2") and
                row["input_net"] and row["output_net"] for row in identities), "Non-identity/disconnected hold cell")
    repairs = rows(build / "hold_repairs.tsv")
    require(sum(int(row["identity_luts"]) for row in repairs) == len(identities), "Repair/audit totals disagree")

    log = (build / "implementation.log").read_text(errors="replace")
    require("PASS: dsp_accelerator routed implementation" in log, "Missing final Vivado PASS marker")
    messages = re.findall(r"^(WARNING|CRITICAL WARNING|ERROR): \[([^\]]+)\]\s*(.*)", log, re.MULTILINE)
    for severity, identifier, message in messages:
        require(severity != "ERROR", f"Vivado error: {identifier}: {message}")
        require(severity != "CRITICAL WARNING" or identifier == "Route 35-39",
                f"Unreviewed critical warning: {identifier}: {message}")
    # Route 35-39 may occur during a repair attempt; final positive margins and
    # complete module routing are mandatory before it is considered resolved.
    effective = (build / "implemented_constraints.xdc").read_text()
    require(not re.search(r"^\s*(set_false_path|set_multicycle_path|set_disable_timing|set_case_analysis)\b",
                          effective, re.MULTILINE), "Unexpected timing exception in effective XDC")
    util = (build / "utilization_post_route.rpt").read_text()

    def used(label):
        match = re.search(r"\|\s*" + label + r"\s*\|\s*(\d+)", util)
        require(match is not None, f"Missing utilization field: {label}")
        return int(match.group(1))

    timing_xdc = (ROOT / "constraints/dsp_accelerator_timing.xdc").read_text()
    require("-period 10.000" in timing_xdc, "100 MHz contract changed")
    summary = {
        "status": "passed", "date": "2026-11-16", "device": "xc7a35tcpg236-1",
        "tool": "Vivado 2026.1 build 6511674",
        "scope": "routed OOC module under documented virtual-interface and physical parent context; not board/assembled-parent acceptance",
        "clock_period_ns": 10.0, "input_delay_ns": {"min": 0.5, "max": 2.0},
        "output_delay_ns": {"min": -0.5, "max": 2.0},
        "user_uncertainty_ns": {"setup": 0.1, "hold": 0.05},
        "acceptance": acceptance, "path_classes": classes,
        "luts": used(r"Slice LUTs\*?"), "flip_flops": used("Slice Registers"),
        "dsps": used("DSPs"), "bram_tiles": used("Block RAM Tile"),
        "hold_repair_iterations": rows(build / "iterations.tsv"),
        "setup_tns_ns": timing_values[1], "setup_failing_endpoints": int(timing_values[2]),
        "hold_total_negative_slack_ns": timing_values[5], "hold_failing_endpoints": int(timing_values[6]),
        "pulse_width_failing_endpoints": int(timing_values[10]),
        "identity_buffers": len(identities),
        "routing_note": "Raw whole-design routing status includes intentional OOC boundary ANTENNAS. Each accepted stub is tied to a declared module port, has at most one logical driver, and reaches its assigned physical node; no unexpected internal route errors are accepted.",
        "resolved_intermediate_route_timing_warnings": sum(s == "CRITICAL WARNING" and i == "Route 35-39"
                                                          for s, i, _ in messages),
        "warning_counts": dict(Counter(identifier for _, identifier, _ in messages)),
        "warning_examples": {identifier: message for _, identifier, message in reversed(messages)},
        "warning_review": {
            "Synth 8-7129 / Vivado 12-2274": "Ignored AXI PROT bits and reserved lanes have no surviving functional net; they are not missing timed endpoints.",
            "DRC 23-814": "OOC mode does not run every whole-design connectivity DRC; this is not board or assembled-parent acceptance.",
            "Timing 38-164": "One hardware and one virtual reference clock are intentionally related and timed; no clock group or path exclusion is added.",
            "Route 35-328 / Route 35-39": "Intermediate hold repair attempts failed timing; final setup/hold/pulse and all four path-class checks pass.",
            "Vivado_Tcl 2-1291 / 2-1511": "Named reports in batch mode have no GUI tab; violation objects remain available to the acceptance checks.",
            "Constraints 18-8777": "Retained unresolved warning during OOC router initialization: Unable to split tiles. All required files are not available. Cause not confirmed. Physical partition-node connectivity and internal routing are audited independently; revalidate the tool/context before parent reuse.",
            "DRC advisory rules": "CFGBVS-1 lacks board configuration voltage (no board assumed). DPIP-1/DPOP-1/DPOP-2 recommend DSP pipelining; no latency change is made to silence these advisories.",
        },
        "source_sha256": hashes, "report_sha256": {name: digest(build / name) for name in REPORTS},
        "verification_source_sha256": {name: digest(ROOT / name) for name in
                                        ("scripts/verify_implementation.py", "scripts/run_implementation.ps1")},
        "routed_checkpoint": str((build / "dsp_accelerator_routed.dcp").relative_to(ROOT)),
        "routed_checkpoint_sha256": digest(build / "dsp_accelerator_routed.dcp"),
    }
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build", type=Path, default=ROOT / "build/accelerator_impl")
    parser.add_argument("--archive", type=Path)
    args = parser.parse_args()
    try:
        summary = verify(args.build.resolve())
        text = json.dumps(summary, indent=2) + "\n"
        (args.build / "summary.json").write_text(text, encoding="utf-8")
        if args.archive:
            args.archive.mkdir(parents=True, exist_ok=True)
            for name in REPORTS:
                shutil.copyfile(args.build / name, args.archive / name)
            (args.archive / "summary.json").write_text(text, encoding="utf-8")
        acceptance = summary["acceptance"]
        print(f"PASS: routed OOC module setup={acceptance['setup_wns_ns']} ns "
              f"hold={acceptance['hold_slack_ns']} ns pulse={acceptance['pulse_width_slack_ns']} ns; "
              f"{acceptance['functional_ports']} physical interface anchors verified")
    except (OSError, ValueError, KeyError) as error:
        parser.exit(1, f"Implementation verification failed: {error}\n")


if __name__ == "__main__":
    main()
