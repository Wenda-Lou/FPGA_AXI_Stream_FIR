"""Independent event-replay checks for FIR reset, clear and clipping status."""

import tempfile
import unittest
from pathlib import Path

from scripts.compare_fir_events import compare


class FirEventTests(unittest.TestCase):
    def replay(self, text):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "events.txt"
            path.write_text(text, encoding="utf-8")
            return compare(path)

    def test_legacy_fixed_format(self):
        result = self.replay("C 0 16384\nR\nI 10000\nO 5000\n")
        self.assertEqual(result["outputs"], 1)

    def test_parameterized_signed_zero_shift_and_wide_output(self):
        result = self.replay("P 1 4 4 12 0 0 0\nC 0 -3\nR\nI 7\nO -21 0\nH\nI -8\nO 24 0\n")
        self.assertEqual(result["config"]["output_width"], 12)
        self.assertEqual(result["history_clears"], 1)
        self.assertEqual(result["saturation_checks"], 2)

    def test_clear_keeps_coefficients_and_discards_history_only(self):
        result = self.replay("P 4 16 16 16 15 15 15\nC 1 16384\nR\nI 10000\nO 0 0\nH\nI 0\nO 0 0\nI 10000\nO 0 0\nI 0\nO 5000 0\n")
        self.assertEqual(result["outputs"], 4)

    def test_reset_discards_pending_result(self):
        result = self.replay("P 1 16 16 16 15 15 15\nC 0 16384\nI 10000\nR\nI 200\nO 100 0\n")
        self.assertEqual(result["reset_discarded"], 1)

    def test_natural_rail_and_clipped_rail_have_different_flags(self):
        result = self.replay("P 1 16 16 16 15 15 15\nC 0 -32768\nI -32767\nO 32767 0\nI -32768\nO 32767 1\n")
        self.assertEqual(result["saturation_checks"], 2)

    def test_rejects_bad_flag_missing_flag_and_busy_clear(self):
        cases = [
            "P 1 16 16 16 15 15 15\nC 0 -32768\nI -32768\nO 32767 0\n",
            "P 1 16 16 16 15 15 15\nC 0 16384\nI 10000\nO 5000\n",
            "P 1 16 16 16 15 15 15\nI 100\nH\n",
        ]
        for events in cases:
            with self.subTest(events=events), self.assertRaises(ValueError):
                self.replay(events)


if __name__ == "__main__":
    unittest.main()
