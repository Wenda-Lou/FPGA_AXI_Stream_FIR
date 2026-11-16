"""Independently replay accepted FIR transactions through the Python model."""

import argparse
import json
import sys
from collections import deque
from dataclasses import asdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from model.fir import FirConfig, FirModel


# Event protocol (signed decimal values):
# P taps input_width coeff_width output_width input_frac coeff_frac output_frac
# C tap coefficient; I accepted_input; O accepted_output saturation_bit
# R reset edge; H accepted history clear. Idle/stall clocks are not exported.
# The trace checks numerical behavior and transaction accounting; timing and
# ready/valid stability are checked by the SystemVerilog testbench instead.
def compare(events_path):
    model = FirModel()
    # Queue complete FirResult objects, preserving value and saturation together.
    # No knowledge of the RTL's register layout or two-stage pipeline is needed.
    pending = deque()
    inputs = outputs = discarded = resets = clears = saturation_checks = 0
    seen_event = header_seen = False
    for line_number, line in enumerate(events_path.read_text(encoding="utf-8").splitlines(), 1):
        fields = line.split()
        if not fields or fields[0].startswith("#"):
            continue
        try:
            if fields[0] == "P" and len(fields) == 8:
                if seen_event:
                    raise ValueError("parameter header must be the first event")
                # Configure arithmetic from the actual simulation export, rather
                # than assuming the default Q1.15 format for every regression run.
                taps, iw, cw, ow, inf, cf, of = map(int, fields[1:])
                model = FirModel(FirConfig(taps=taps, input_width=iw, coeff_width=cw,
                                          output_width=ow, input_frac=inf,
                                          coeff_frac=cf, output_frac=of))
                header_seen = True
            elif fields == ["R"]:
                # Coefficients are external core inputs and survive core reset.
                model.clear_history()
                # Reset can abandon accepted but unconsumed results. Account for
                # those explicitly so loss cannot be mistaken for a valid drain.
                discarded += len(pending)
                pending.clear()
                resets += 1
            elif fields == ["H"]:
                # History clear is legal only at idle and never discards results.
                # A busy clear request is not an H event until actually accepted.
                if pending:
                    raise ValueError("history cleared with pending results")
                model.clear_history()
                clears += 1
            elif fields[0] == "C" and len(fields) == 3:
                if pending:
                    raise ValueError("coefficient changed with pending results")
                model.write_coefficient(int(fields[1]), int(fields[2]))
            elif fields[0] == "I" and len(fields) == 2:
                # Processing an accepted sample advances model history exactly
                # once. Source retries and empty clock cycles do not reach here.
                pending.append(model.process(int(fields[1])))
                inputs += 1
            elif fields[0] == "O" and len(fields) in (2, 3):
                # Older traces without a P header may omit the flag. All current
                # parameterized traces must include it, even when no sample clips.
                if header_seen and len(fields) != 3:
                    raise ValueError("parameterized export is missing saturation status")
                if not pending:
                    raise ValueError("unexpected/duplicate output")
                # FIFO ordering detects dropped, reordered and duplicate outputs.
                wanted = pending.popleft()
                actual = int(fields[1])
                if actual != wanted.value:
                    raise ValueError(f"output {outputs}: expected {wanted.value}, got {actual}")
                if len(fields) == 3:
                    actual_saturated = int(fields[2])
                    if actual_saturated not in (0, 1) or bool(actual_saturated) != wanted.saturated:
                        raise ValueError(f"output {outputs}: saturation status mismatch")
                    saturation_checks += 1
                outputs += 1
            else:
                raise ValueError("unrecognized event")
            seen_event = True
        except ValueError as error:
            # Include the physical trace line to make a simulator failure easy
            # to locate even when thousands of transactions preceded it.
            raise ValueError(f"line {line_number}: {error}") from error
    # Reject empty evidence, unfinished pipelines and unexplained transaction loss.
    if pending or not inputs or not outputs or inputs != outputs + discarded:
        raise ValueError("incomplete or inconsistent input/output accounting")
    return {"status": "passed", "inputs": inputs, "outputs": outputs,
            "reset_discarded": discarded, "reset_edges": resets,
            "history_clears": clears, "saturation_checks": saturation_checks,
            "config": asdict(model.config)}


# Emit a machine-readable summary consumed by run_fir.ps1. Any malformed trace,
# file error or numerical mismatch produces a nonzero command-line exit status.
def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--events", required=True, type=Path)
    parser.add_argument("--summary", type=Path)
    args = parser.parse_args()
    try:
        result = compare(args.events)
        text = json.dumps(result, indent=2) + "\n"
        if args.summary:
            args.summary.write_text(text, encoding="utf-8")
        print(text, end="")
    except (OSError, ValueError) as error:
        parser.exit(1, f"Python FIR comparison failed: {error}\n")


if __name__ == "__main__":
    main()
