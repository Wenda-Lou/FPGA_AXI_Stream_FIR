"""Bit-exact FIR arithmetic for accepted samples; no cycle timing is modeled."""

from dataclasses import dataclass


def decode_signed(word: int, width: int) -> int:
    """Decode an unsigned bus word without silently accepting out-of-range bits."""
    if width < 1 or not 0 <= word < (1 << width):
        raise ValueError("word must fit the unsigned bus width")
    return word - (1 << width) if word & (1 << (width - 1)) else word


def encode_signed(value: int, width: int) -> int:
    """Encode a signed value as an unsigned bus word."""
    if width < 1 or not -(1 << (width - 1)) <= value < (1 << (width - 1)):
        raise ValueError("value must fit the signed bus width")
    return value & ((1 << width) - 1)


@dataclass(frozen=True)
class FirConfig:
    taps: int = 8
    input_width: int = 16
    coeff_width: int = 16
    output_width: int = 16
    input_frac: int = 15
    coeff_frac: int = 15
    output_frac: int = 15

    def __post_init__(self):
        if self.taps < 1 or self.taps & (self.taps - 1):
            raise ValueError("taps must be a positive power of two")
        if self.taps > 32:
            raise ValueError("coefficient registers must fit the 8-bit address map")
        for width, frac in (
            (self.input_width, self.input_frac),
            (self.coeff_width, self.coeff_frac),
            (self.output_width, self.output_frac),
        ):
            if width < 2 or not 0 <= frac < width:
                raise ValueError("fractional bits must be in [0, width-1]")
        if self.coeff_width > 32:
            raise ValueError("coefficient width must fit an AXI4-Lite register")
        if self.shift < 0:
            raise ValueError("output format requires an unsupported left shift")

    @property
    def shift(self):
        return self.input_frac + self.coeff_frac - self.output_frac

    @property
    def accumulator_width(self):
        return self.input_width + self.coeff_width + (self.taps - 1).bit_length()


@dataclass(frozen=True)
class FirResult:
    value: int
    accumulator: int
    saturated: bool


class FirModel:
    """Caller supplies accepted inputs and legal, drained configuration events.

    AXI enable, FIFO occupancy, counters and response timing belong to the RTL
    control model/testbench. Calling process() means one sample was accepted.
    """

    def __init__(self, config=None):
        self.config = config if config is not None else FirConfig()
        self.hardware_reset()

    @property
    def coefficients(self):
        return tuple(self._coefficients)

    def hardware_reset(self):
        self._coefficients = [0] * self.config.taps
        self.clear_history()

    def clear_history(self):
        """Also models a legal soft clear; coefficients are preserved."""
        self._history = [0] * self.config.taps

    def write_coefficient(self, index, value):
        if not 0 <= index < self.config.taps:
            raise ValueError("coefficient index out of range")
        encode_signed(value, self.config.coeff_width)
        self._coefficients[index] = value
        self.clear_history()

    def process(self, sample):
        encode_signed(sample, self.config.input_width)
        self._history = [sample] + self._history[:-1]
        accumulator = sum(c * x for c, x in zip(self._coefficients, self._history))
        shifted = accumulator >> self.config.shift
        lower = -(1 << (self.config.output_width - 1))
        upper = (1 << (self.config.output_width - 1)) - 1
        value = min(upper, max(lower, shifted))
        return FirResult(value, accumulator, shifted != value)
