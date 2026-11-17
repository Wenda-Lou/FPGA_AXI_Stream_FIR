"""Negative evidence-parser tests; these are not claims of real RTL execution."""

import tempfile
import unittest
from pathlib import Path
from webapp.rtl_runner import parse_results, RtlError


class RtlEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory()
        self.folder=Path(self.temp.name)
        (self.folder/'rtl_inputs.txt').write_text('0 16384\n1 -16384\n')
        (self.folder/'rtl_outputs.txt').write_text('0 8192 0\n1 -8192 0\n')
        (self.folder/'rtl_summary.txt').write_text('2 2 60\n')

    def tearDown(self): self.temp.cleanup()
    def parse(self): return parse_results(self.folder,[16384,-16384],[16384]+[0]*7)

    def test_numerical_and_flag_mismatch_fail(self):
        for text in ('0 8193 0\n1 -8192 0\n','0 8192 1\n1 -8192 0\n'):
            (self.folder/'rtl_outputs.txt').write_text(text)
            with self.assertRaises(RtlError) as error:self.parse()
            self.assertEqual(error.exception.code,'RTL_MISMATCH')

    def test_accepted_inputs_must_be_exact_request(self):
        (self.folder/'rtl_inputs.txt').write_text('0 1\n1 -16384\n')
        with self.assertRaises(RtlError) as error:self.parse()
        self.assertEqual(error.exception.code,'RTL_PROTOCOL_ERROR')

    def test_missing_or_duplicate_output_fails(self):
        for text in ('0 8192 0\n','0 8192 0\n0 -8192 0\n'):
            (self.folder/'rtl_outputs.txt').write_text(text)
            with self.assertRaises(RtlError):self.parse()

    def test_valid_fixture_preserves_actual_values(self):
        result=self.parse()
        self.assertEqual(result['outputs'],[8192,-8192])
        self.assertEqual(result['rtl_cycles'],60)
        self.assertEqual(result['verification']['mismatches'],0)
