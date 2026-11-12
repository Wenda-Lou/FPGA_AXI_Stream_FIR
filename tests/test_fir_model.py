"""Hand-calculated cases protect the oracle used for subsequent RTL tests."""

import unittest

from model.fir import FirConfig, FirModel, decode_signed, encode_signed


def configured(coefficients, config=None):
    model = FirModel(config)
    for index, coefficient in enumerate(coefficients):
        model.write_coefficient(index, coefficient)
    return model


class FirModelTests(unittest.TestCase):
    def test_default_accumulator_width(self):
        self.assertEqual(FirConfig().accumulator_width, 35)
        self.assertEqual(FirConfig(taps=1).accumulator_width, 32)

    def test_signed_bus_boundaries(self):
        for word, value in [(0x0000, 0), (0x7FFF, 32767), (0x8000, -32768), (0xFFFF, -1)]:
            with self.subTest(word=word):
                self.assertEqual(decode_signed(word, 16), value)
                self.assertEqual(encode_signed(value, 16), word)

    def test_rejects_out_of_range_values(self):
        for value in [-32769, 32768]:
            with self.assertRaises(ValueError):
                encode_signed(value, 16)
        for word in [-1, 65536]:
            with self.assertRaises(ValueError):
                decode_signed(word, 16)

    def test_zero_coefficients(self):
        model = FirModel()
        self.assertEqual([model.process(x).value for x in [32767, -32768, -1, 0]], [0] * 4)

    def test_impulse_tap_order(self):
        model = configured([16384, -8192, 4096, -2048, 1024, -512, 256, -128])
        outputs = [model.process(x).value for x in [16384] + [0] * 8]
        self.assertEqual(outputs, [8192, -4096, 2048, -1024, 512, -256, 128, -64, 0])

    def test_negative_shift_floors(self):
        model = configured([16384])
        self.assertEqual([model.process(x).value for x in [1, -1, 3, -3]], [0, -1, 1, -2])

    def test_positive_saturation(self):
        model = configured([32767, 32767])
        first = model.process(32767)
        second = model.process(32767)
        self.assertEqual((first.value, first.saturated), (32766, False))
        self.assertEqual((second.value, second.saturated), (32767, True))

    def test_negative_saturation(self):
        model = configured([32767, 32767])
        first = model.process(-32768)
        second = model.process(-32768)
        self.assertEqual((first.value, first.saturated), (-32767, False))
        self.assertEqual((second.value, second.saturated), (-32768, True))

    def test_minimum_times_minimum_clips_positive(self):
        result = configured([-32768]).process(-32768)
        self.assertEqual((result.accumulator, result.value, result.saturated), (1073741824, 32767, True))

    def test_accumulator_retains_full_precision(self):
        model = configured([-32768] * 8)
        results = [model.process(-32768) for _ in range(8)]
        self.assertEqual(results[-1].accumulator, 8589934592)
        self.assertTrue(results[-1].saturated)

    def test_history_clear_preserves_coefficients(self):
        model = configured([0, 16384])
        model.process(200)
        model.clear_history()
        self.assertEqual(model.coefficients[1], 16384)
        self.assertEqual(model.process(0).value, 0)

    def test_coefficient_write_clears_history(self):
        model = configured([0, 16384])
        model.process(200)
        model.write_coefficient(0, 0)
        self.assertEqual(model.process(0).value, 0)

    def test_hardware_reset_clears_coefficients(self):
        model = configured([16384])
        model.process(200)
        model.hardware_reset()
        self.assertEqual(model.coefficients, (0,) * 8)
        self.assertEqual(model.process(200).value, 0)

    def test_one_and_four_taps(self):
        for taps in [1, 4]:
            model = configured([16384], FirConfig(taps=taps))
            self.assertEqual([model.process(x).value for x in [100, -100]], [50, -50])

    def test_zero_shift_format(self):
        config = FirConfig(taps=1, input_width=4, coeff_width=4, output_width=8,
                           input_frac=0, coeff_frac=0, output_frac=0)
        self.assertEqual(configured([-3], config).process(7).value, -21)

    def test_configuration_validation(self):
        for args in [dict(taps=0), dict(taps=3), dict(taps=64), dict(coeff_width=33),
                     dict(input_frac=16), dict(output_frac=-1),
                     dict(input_frac=0, coeff_frac=0, output_frac=1)]:
            with self.subTest(args=args), self.assertRaises(ValueError):
                FirConfig(**args)

    def test_coefficient_and_sample_validation(self):
        model = FirModel()
        for index, value in [(-1, 0), (8, 0), (0, 32768)]:
            with self.assertRaises(ValueError):
                model.write_coefficient(index, value)
        with self.assertRaises(ValueError):
            model.process(-32769)


if __name__ == "__main__":
    unittest.main()
