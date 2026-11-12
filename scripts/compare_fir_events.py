"""Independently replay accepted FIR transactions through the Python model."""

import argparse
import json
import sys
from collections import deque
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from model.fir import FirModel


def compare(events_path):
    model = FirModel()
    pending = deque()
    inputs = outputs = discarded = resets = 0
    for line_number, line in enumerate(events_path.read_text(encoding="utf-8").splitlines(), 1):
        fields = line.split()
        if not fields or fields[0].startswith("#"):
            continue
        try:
            if fields == ["R"]:
                # Coefficients are external core inputs and survive core reset.
                model.clear_history()
                discarded += len(pending)
                pending.clear()
                resets += 1
            elif fields[0] == "C" and len(fields) == 3:
                if pending:
                    raise ValueError("coefficient changed with pending results")
                model.write_coefficient(int(fields[1]), int(fields[2]))
            elif fields[0] == "I" and len(fields) == 2:
                pending.append(model.process(int(fields[1])).value)
                inputs += 1
            elif fields[0] == "O" and len(fields) == 2:
                if not pending:
                    raise ValueError("unexpected/duplicate output")
                wanted = pending.popleft()
                actual = int(fields[1])
                if actual != wanted:
                    raise ValueError(f"output {outputs}: expected {wanted}, got {actual}")
                outputs += 1
            else:
                raise ValueError("unrecognized event")
        except ValueError as error:
            raise ValueError(f"line {line_number}: {error}") from error
    if pending or not inputs or not outputs or inputs != outputs + discarded:
        raise ValueError("incomplete or inconsistent input/output accounting")
    return {"status": "passed", "inputs": inputs, "outputs": outputs,
            "reset_discarded": discarded, "reset_edges": resets}


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
