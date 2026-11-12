"""Generate reproducible $readmemh inputs and bit-exact expected FIR outputs."""

import argparse
import json
import random
import sys
from dataclasses import asdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from model.fir import FirConfig, FirModel, encode_signed


def write_words(path, values, width):
    digits = (width + 3) // 4
    path.write_text("".join(f"{encode_signed(x, width):0{digits}x}\n" for x in values), encoding="ascii")


def generate(destination, seed, count):
    if count < 1:
        raise ValueError("sample count must be positive")
    destination.mkdir(parents=True, exist_ok=True)
    config = FirConfig()
    rng = random.Random(seed)
    coefficients = [16384, -8192, 4096, -2048, 1024, -512, 256, -128]
    scenarios = {
        "impulse": (coefficients, [16384] + [0] * 15),
        "extremes": (coefficients, [32767, -32768, 0, -1, 1, 3, -3] * 8),
        "positive_saturation": ([32767] * 8, [32767] * 32),
        "negative_saturation": ([32767] * 8, [-32768] * 32),
        "random": (coefficients, [rng.randint(-32768, 32767) for _ in range(count)]),
    }
    manifest = {"config": asdict(config), "seed": seed, "scenarios": {}}
    for name, (coeffs, samples) in scenarios.items():
        model = FirModel(config)
        for index, value in enumerate(coeffs):
            model.write_coefficient(index, value)
        results = [model.process(sample) for sample in samples]
        folder = destination / name
        folder.mkdir(exist_ok=True)
        write_words(folder / "coefficients.mem", coeffs, config.coeff_width)
        write_words(folder / "input.mem", samples, config.input_width)
        write_words(folder / "expected.mem", [r.value for r in results], config.output_width)
        write_words(folder / "saturated.mem", [int(r.saturated) for r in results], 2)
        manifest["scenarios"][name] = {"samples": len(samples), "saturations": sum(r.saturated for r in results)}
    (destination / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=Path("build/vectors"))
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--count", type=int, default=10000)
    args = parser.parse_args()
    try:
        manifest = generate(args.output, args.seed, args.count)
    except (ValueError, OSError) as error:
        parser.exit(1, f"Vector generation failed: {error}\n")
    print(json.dumps(manifest, indent=2))


if __name__ == "__main__":
    main()
