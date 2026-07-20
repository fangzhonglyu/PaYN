#!/usr/bin/env python3
"""Regression tests for SC and binary SAIF validation.

Methodology: correctness is established by the output-checking bench; the
validator gates on the *measurement* -- architectural-output X, transient X,
and clock period. Persistent X on a dead/internal net is benign by default and
only rejected under --strict-persistent-x.
"""

from __future__ import annotations

import subprocess
import tempfile
import unittest
from pathlib import Path


SWEEPS_DIR = Path(__file__).resolve().parent


def make_saif(*, output: str, floating_tx: int = 0, transient_tx: int = 0,
              output_tx: int = 0) -> str:
    floating = ""
    if floating_tx:
        floating = f"""
        (floating
          (T0 0) (T1 0) (TX {floating_tx})
          (TC 0)
        )"""
    transient = f"""
        (transient
          (T0 {1000000 - transient_tx}) (T1 0) (TX {transient_tx})
          (TC 2)
        )"""
    # The architectural output net; output_tx>0 makes it unknown (fully X when
    # output_tx == the duration, which exercises the acc/output-TX gate directly).
    out_t0 = 0 if output_tx >= 1000000 else 500000
    out_t1 = max(0, 500000 - output_tx)
    output_net = f"""
        ({output}\\[0\\]
          (T0 {out_t0}) (T1 {out_t1}) (TX {output_tx})
          (TC 200)
        )"""
    return f"""(SAIFILE
  (TIMESCALE 1 ps)
  (DURATION 1000000)
  (INSTANCE Top
    (INSTANCE dut
      (NET
        (clk
          (T0 500000) (T1 499999) (TX 1)
          (TC 800)
        )
        (a_bits_in\\[0\\]
          (T0 500000) (T1 500000) (TX 0)
          (TC 200)
        ){output_net}{transient}{floating}
      )
    )
  )
)
"""


class SaifXPolicyTest(unittest.TestCase):
    def run_validator(self, script: str, saif_text: str, *extra: str
                      ) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as temp_dir:
            saif = Path(temp_dir) / "dut.saif"
            saif.write_text(saif_text)
            return subprocess.run(
                ["python3", "-B", str(SWEEPS_DIR / script), str(saif), *extra],
                text=True,
                capture_output=True,
                check=False,
            )

    # ---- clean runs pass ----
    def test_clean_sc_passes(self) -> None:
        result = self.run_validator("validate_sc_power_saif.py", make_saif(output="acc_out"))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_clean_binary_passes(self) -> None:
        result = self.run_validator("validate_power_saif.py", make_saif(output="ofm"))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    # ---- dead-net persistent X is benign by default ----
    def test_dead_net_persistent_x_benign_sc(self) -> None:
        result = self.run_validator(
            "validate_sc_power_saif.py", make_saif(output="acc_out", floating_tx=1000000)
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("benign", result.stdout + result.stderr)

    def test_dead_net_persistent_x_benign_binary(self) -> None:
        result = self.run_validator(
            "validate_power_saif.py", make_saif(output="ofm", floating_tx=1000000)
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("benign", result.stdout + result.stderr)

    # ---- but --strict still rejects any persistent X ----
    def test_dead_net_persistent_x_strict_fails(self) -> None:
        result = self.run_validator(
            "validate_power_saif.py",
            make_saif(output="ofm", floating_tx=1000000),
            "--strict-persistent-x",
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("persistent-X signals=1", result.stdout + result.stderr)

    # ---- persistent X on the architectural OUTPUT always fails (broken execution),
    #      even though a persistent dead net is benign -- the dedicated output gate
    #      survives the persistent-X relaxation. ----
    def test_output_x_fails_sc(self) -> None:
        result = self.run_validator(
            "validate_sc_power_saif.py", make_saif(output="acc_out", output_tx=1000000)
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("accumulator", result.stdout + result.stderr)

    def test_output_x_fails_binary(self) -> None:
        result = self.run_validator(
            "validate_power_saif.py", make_saif(output="ofm", output_tx=1000000)
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("output TX", result.stdout + result.stderr)

    # ---- transient X beyond one reporter quantum fails ----
    def test_transient_sc_x_beyond_reporter_quantum_fails(self) -> None:
        result = self.run_validator(
            "validate_sc_power_saif.py", make_saif(output="acc_out", transient_tx=10)
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("exceeds one reporter quantum", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
