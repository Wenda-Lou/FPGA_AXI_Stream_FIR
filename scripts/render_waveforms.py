"""Render real XSim VCD values sampled immediately BEFORE each rising edge.

These are discrete sampled waveforms, not GUI screenshots or an analog timing
analysis. The pre-edge convention matches ready/valid acceptance in the bench.
"""

import hashlib
import json
import re
import shutil
from html import escape
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "build/waveforms"
ASSETS = ROOT / "docs/assets"
REPORT = ROOT / "reports/waveforms"


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest().upper()


def require(condition, message):
    if not condition:
        raise ValueError(message)


def samples_from_vcd(path):
    lines = path.read_text(encoding="utf-8").splitlines()
    names, widths, state, samples = {}, {}, {}, []
    scale = re.search(r"\$timescale\s+(\d+)\s*(ps|ns)\s+\$end", "\n".join(lines))
    require(scale is not None, "Unsupported/missing VCD timescale")
    ns_per_tick = int(scale[1]) * (0.001 if scale[2] == "ps" else 1)
    for line in lines:
        if line.startswith("$var "):
            fields = line.split()
            widths[fields[4]], names[fields[3]] = int(fields[2]), fields[4]
    require("clk" in names.values(), "Clock not captured")
    clock_id = next(key for key, value in names.items() if value == "clk")
    time, changes = 0, {}

    def flush():
        if state.get("clk") == "0" and changes.get(clock_id) == "1":
            sample = dict(state)
            sample["time_ns"] = round(time * ns_per_tick, 6)
            sample["edge"] = len(samples)
            sample["input_transfer"] = int(all(sample.get(key) == "1" for key in
                                                     ("resetn", "s_axis_tvalid", "s_axis_tready")))
            sample["output_transfer"] = int(all(sample.get(key) == "1" for key in
                                                      ("resetn", "m_axis_tvalid", "m_axis_tready")))
            samples.append(sample)
        for identifier, value in changes.items():
            if identifier in names:
                state[names[identifier]] = value

    for line in lines:
        if line.startswith("#"):
            flush()
            time, changes = int(line[1:]), {}
        elif line.startswith(("b", "B")):
            value, identifier = line[1:].split()
            changes[identifier] = value.lower()
        elif line and line[0].lower() in "01xz":
            changes[line[1:]] = line[0].lower()
    flush()
    require(len(samples) > 1000, "Incomplete VCD")
    require(all(abs(b["time_ns"] - a["time_ns"] - 10) < 0.001 for a, b in zip(samples, samples[1:])),
            "Captured clock is not 100 MHz")
    return samples, widths


def windows(samples):
    start = next(i for i, row in enumerate(samples) if row.get("check_latency") == "1" and row["input_transfer"])
    require(all(row["input_transfer"] for row in samples[start:start+16]), "Missing continuous inputs")
    require(not any(row["output_transfer"] for row in samples[start:start+4]), "Unexpected early output")
    require(all(row["output_transfer"] for row in samples[start+4:start+20]), "Missing continuous outputs")
    continuous = samples[start-2:start+18]
    stall = None
    i = 0
    while i < len(samples):
        if samples[i].get("resetn") == "1" and samples[i].get("m_axis_tvalid") == "1" and samples[i].get("m_axis_tready") == "0":
            end = i
            while end < len(samples) and samples[end].get("resetn") == "1" and samples[end].get("m_axis_tvalid") == "1" and samples[end].get("m_axis_tready") == "0":
                end += 1
            if end-i >= 8 and end+5 < len(samples) and samples[end]["output_transfer"]:
                require(len({row["m_axis_tdata"] for row in samples[i:end+1]}) == 1, "Output changed under backpressure")
                stall = (i, end)
                break
            i = end
        else:
            i += 1
    require(stall is not None, "No bounded backpressure example")
    first, end = stall
    enable = next(i for i in range(1, len(samples)) if samples[i-1].get("enable") == "0" and
                  samples[i].get("enable") == "1" and samples[i].get("resetn") == "1")
    control = samples[enable-7:enable+7]
    require(any(row.get("s_axi_awvalid") == row.get("s_axi_awready") == "1" and
                int(row["s_axi_awaddr"], 2) == 0 for row in control), "Enable address handshake not visible")
    require(any(row.get("s_axi_wvalid") == row.get("s_axi_wready") == "1" and
                int(row["s_axi_wdata"], 2) & 1 for row in control), "Enable data handshake not visible")
    require(any(row.get("s_axi_bvalid") == row.get("s_axi_bready") == "1" and
                int(row["s_axi_bresp"], 2) == 0 for row in control), "Enable OKAY response not visible")
    return {
        "continuous": {"title": "Continuous streaming: four-clock external latency",
                       "note": "First input edge to first output edge: 4 clocks; steady state accepts one input and one output per clock.",
                       "rows": continuous, "latency_clocks": 4,
                       "signals": ["resetn", "enable", "s_axis_tvalid", "s_axis_tready", "input_transfer", "s_axis_tdata",
                                   "m_axis_tvalid", "m_axis_tready", "output_transfer", "m_axis_tdata"]},
        "backpressure": {"title": "Output backpressure: payload held until acceptance",
                         "note": f"Observed stall: {end-first} clocks. Output data and valid remain stable through the accepting edge.",
                         "rows": samples[end-8:end+6], "observed_stall_clocks": end-first,
                         "signals": ["resetn", "s_axis_tvalid", "s_axis_tready", "s_axis_tdata", "m_axis_tvalid",
                                     "m_axis_tready", "output_transfer", "m_axis_tdata"]},
        "axi_enable": {"title": "AXI4-Lite CONTROL.ENABLE write",
                       "note": "Independent AW/W handshakes, an OKAY B response, and the resulting enable transition.",
                       "rows": control,
                       "signals": ["resetn", "s_axi_awaddr", "s_axi_awvalid", "s_axi_awready", "s_axi_wdata",
                                   "s_axi_wstrb", "s_axi_wvalid", "s_axi_wready", "s_axi_bresp",
                                   "s_axi_bvalid", "s_axi_bready", "enable"]},
    }


def svg(window, widths):
    rows, signals = window["rows"], window["signals"]
    left, step, top, gap = 190, 56, 134, 42
    width, height = left + len(rows)*step + 26, top + len(signals)*gap + 58
    parts = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">',
             f'<title>{escape(window["title"])}</title>',
             '<style>text{font-family:Consolas,monospace;fill:#172b42;font-size:12px}.label{font-size:13px}.small{font-size:11px;fill:#52677d}</style>',
             f'<rect width="{width}" height="{height}" fill="#fff"/>',
             f'<text x="24" y="30" style="font-family:Arial,sans-serif;font-size:20px;font-weight:bold">{escape(window["title"])}</text>',
             f'<text x="24" y="55" class="small">{escape(window["note"])}</text>',
             '<text x="24" y="77" class="small">Actual XSim VCD, seed 1. Values sampled immediately before each rising edge; buses shown in hexadecimal.</text>',
             '<text x="24" y="106" class="small">Rising-edge time (ns)</text>']
    for column, row in enumerate(rows):
        x = left + column*step
        parts += [f'<line x1="{x}" y1="118" x2="{x}" y2="{height-46}" stroke="#dde5ef"/>',
                  f'<text x="{x+step/2}" y="106" text-anchor="middle" class="small">{row["time_ns"]:g}</text>']
    for index, signal in enumerate(signals):
        y = top + index*gap
        parts.append(f'<text x="18" y="{y+18}" class="label">{escape(signal)}</text>')
        digital = widths.get(signal, 1) == 1
        for column, row in enumerate(rows):
            value, x = row.get(signal, "x"), left + column*step
            if isinstance(value, int):
                value = str(value)
            if digital and value in ("0", "1"):
                level = y + (5 if value == "1" else 28)
                color = "#137b5a" if "transfer" in signal else "#2163b5"
                parts.append(f'<path d="M{x},{level} H{x+step}" fill="none" stroke="{color}" stroke-width="2"/>')
                if column:
                    previous = str(rows[column-1].get(signal, "x"))
                    if previous in ("0", "1") and previous != value:
                        old_level = y + (5 if previous == "1" else 28)
                        parts.append(f'<path d="M{x},{old_level} V{level}" stroke="{color}" stroke-width="2"/>')
                if "transfer" in signal and value == "1":
                    parts.append(f'<circle cx="{x+step/2}" cy="{level}" r="3" fill="{color}"/>')
            else:
                label = value.upper() if re.search(r"[xz]", value, re.I) else f'{int(value,2):0{(widths.get(signal,1)+3)//4}X}'
                parts += [f'<path d="M{x},{y+16} L{x+4},{y+4} H{x+step-4} L{x+step},{y+16} L{x+step-4},{y+29} H{x+4} Z" fill="#f0f5fc" stroke="#6690bb"/>',
                          f'<text x="{x+step/2}" y="{y+21}" text-anchor="middle" style="font-size:{10 if len(label)>6 else 12}px">{escape(label)}</text>']
    parts += [f'<text x="24" y="{height-18}" class="small">Transfer markers = resetn &amp; valid &amp; ready. This sampled display does not prove analog setup/hold timing.</text>', '</svg>']
    return "\n".join(parts) + "\n"


def main():
    comparison = json.loads((BUILD / "python.json").read_text(encoding="utf-8"))
    require(comparison["status"] == "passed" and comparison["outputs"] == comparison["saturation_checks"], "Waveform arithmetic comparison failed")
    samples, widths = samples_from_vcd(BUILD / "accelerator.vcd")
    selected = windows(samples)
    ASSETS.mkdir(parents=True, exist_ok=True)
    REPORT.mkdir(parents=True, exist_ok=True)
    for name, window in selected.items():
        (ASSETS / f"waveform_{name}.svg").write_text(svg(window, widths), encoding="utf-8")
    (REPORT / "sampled_windows.json").write_text(json.dumps(selected, indent=2) + "\n", encoding="utf-8")
    shutil.copyfile(BUILD / "waveform.log", REPORT / "simulation_log.txt")
    shutil.copyfile(BUILD / "python.json", REPORT / "python_comparison.json")
    source_paths = [*sorted((ROOT / "fpga_streaming_dsp/fpga_streaming_dsp.srcs/sources_1/new").glob("*.v")),
                    ROOT / "fpga_streaming_dsp/fpga_streaming_dsp.srcs/sim_1/tb_dsp_accelerator.sv",
                    ROOT / "scripts/capture_waveforms.tcl", ROOT / "scripts/run_waveforms.ps1", Path(__file__).resolve()]
    summary = {
        "status": "passed", "scope": "Supplemental behavioral simulation, default configuration, SEED=1 SAMPLES=1000; not part of the 47-run total",
        "sampling": "Values immediately before rising edges, matching bench handshake acceptance; not an analog timing plot",
        "source_sha256": {path.relative_to(ROOT).as_posix(): sha(path) for path in source_paths},
        "vcd_sha256": sha(BUILD / "accelerator.vcd"), "events_sha256": sha(BUILD / "waveform.events.txt"),
        "python_comparison": comparison, "captured_edges": len(samples), "clock_period_ns": 10,
        "windows": {name: {"first_edge_ns": window["rows"][0]["time_ns"], "last_edge_ns": window["rows"][-1]["time_ns"],
                           "samples": len(window["rows"])} for name, window in selected.items()},
        "artifact_sha256": {f"docs/assets/waveform_{name}.svg": sha(ASSETS / f"waveform_{name}.svg") for name in selected},
    }
    summary["artifact_sha256"].update({f"reports/waveforms/{name}": sha(REPORT / name) for name in
                                      ("sampled_windows.json", "simulation_log.txt", "python_comparison.json")})
    (REPORT / "summary.json").write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    print("PASS: real-VCD continuous/backpressure/AXI-enable waveforms; four-clock latency and stable stalled payload checked")


if __name__ == "__main__":
    main()
