"""Check files consumed by the future RTL scoreboard, not just model internals."""

import json
import tempfile
import unittest
from pathlib import Path

from scripts.generate_vectors import generate


class VectorTests(unittest.TestCase):
    def test_impulse_files_and_manifest(self):
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp)
            manifest = generate(folder, seed=1, count=20)
            outputs = (folder / "impulse/expected.mem").read_text().splitlines()
            self.assertEqual(outputs[:9], ["2000", "f000", "0800", "fc00", "0200", "ff00", "0080", "ffc0", "0000"])
            self.assertEqual(json.loads((folder / "manifest.json").read_text()), manifest)
            for name, info in manifest["scenarios"].items():
                for filename in ["input.mem", "expected.mem", "saturated.mem"]:
                    self.assertEqual(len((folder / name / filename).read_text().splitlines()), info["samples"])
                self.assertEqual(len((folder / name / "coefficients.mem").read_text().splitlines()), 8)
            self.assertEqual(manifest["scenarios"]["positive_saturation"]["saturations"], 31)
            self.assertEqual(manifest["scenarios"]["negative_saturation"]["saturations"], 31)

    def test_seed_reproduces_all_files(self):
        with tempfile.TemporaryDirectory() as temp:
            first, second = Path(temp) / "first", Path(temp) / "second"
            generate(first, seed=7, count=128)
            generate(second, seed=7, count=128)
            for path in first.rglob("*"):
                if path.is_file():
                    self.assertEqual(path.read_bytes(), (second / path.relative_to(first)).read_bytes())

    def test_seed_changes_random_stimulus(self):
        with tempfile.TemporaryDirectory() as temp:
            first, second = Path(temp) / "first", Path(temp) / "second"
            generate(first, seed=1, count=128)
            generate(second, seed=2, count=128)
            self.assertNotEqual((first / "random/input.mem").read_bytes(), (second / "random/input.mem").read_bytes())

    def test_rejects_empty_random_run(self):
        with tempfile.TemporaryDirectory() as temp:
            with self.assertRaises(ValueError):
                generate(Path(temp), seed=1, count=0)


if __name__ == "__main__":
    unittest.main()
