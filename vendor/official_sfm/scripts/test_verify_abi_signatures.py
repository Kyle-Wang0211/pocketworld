#!/usr/bin/env python3
"""Regression coverage for the frozen self/official ABI parity verifier."""

from pathlib import Path
import importlib.util
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("verify_abi_signatures.py")
SPEC = importlib.util.spec_from_file_location("verify_abi_signatures", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
VERIFIER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERIFIER)


class CheckedInAbiParityTest(unittest.TestCase):
    def test_official_only_exports_do_not_break_shared_signature_parity(self) -> None:
        result = subprocess.run(
            [sys.executable, str(SCRIPT)],
            capture_output=True,
            text=True,
            check=False,
        )

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(
            "PASS: 26 shared pwsfm/pwofficial signatures; "
            "3 frozen official-only exports",
            result.stdout,
        )

    def test_official_surface_may_be_a_strict_superset(self) -> None:
        shared, official_only = VERIFIER.validate_surfaces(
            self_types={"run": "int (void)", "telemetry": "int (double *)"},
            official_types={
                "run": "int (void)",
                "telemetry": "int (double *)",
                "prefetch_frame": "int (void *)",
            },
            self_expected={"run", "telemetry"},
            official_expected={"run", "telemetry", "prefetch_frame"},
            official_only_expected={"prefetch_frame"},
        )

        self.assertEqual(shared, {"run", "telemetry"})
        self.assertEqual(official_only, {"prefetch_frame"})

    def test_shared_signature_mismatch_fails_closed(self) -> None:
        with self.assertRaisesRegex(ValueError, "ABI signature mismatch"):
            VERIFIER.validate_surfaces(
                self_types={"run": "int (void)"},
                official_types={"run": "void (void)"},
                self_expected={"run"},
                official_expected={"run"},
                official_only_expected=set(),
            )

    def test_manifest_drift_fails_closed_on_either_surface(self) -> None:
        with self.assertRaisesRegex(ValueError, "frozen self manifest"):
            VERIFIER.validate_surfaces(
                self_types={"run": "int (void)", "extra": "int (void)"},
                official_types={"run": "int (void)"},
                self_expected={"run"},
                official_expected={"run"},
                official_only_expected=set(),
            )
        with self.assertRaisesRegex(ValueError, "frozen official manifest"):
            VERIFIER.validate_surfaces(
                self_types={"run": "int (void)"},
                official_types={"run": "int (void)", "extra": "int (void)"},
                self_expected={"run"},
                official_expected={"run"},
                official_only_expected=set(),
            )

    def test_official_surface_must_cover_every_shared_symbol(self) -> None:
        with self.assertRaisesRegex(ValueError, "missing frozen self-parity"):
            VERIFIER.validate_surfaces(
                self_types={"run": "int (void)"},
                official_types={},
                self_expected={"run"},
                official_expected=set(),
                official_only_expected=set(),
            )

    def test_unclassified_official_only_export_fails_closed(self) -> None:
        with self.assertRaisesRegex(ValueError, "official-only manifest"):
            VERIFIER.validate_surfaces(
                self_types={"run": "int (void)"},
                official_types={
                    "run": "int (void)",
                    "new_export": "int (void)",
                },
                self_expected={"run"},
                official_expected={"run", "new_export"},
                official_only_expected=set(),
            )

    def test_manifest_prefix_and_aliases_are_explicit(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "symbols.txt"
            path.write_text("pwsfm_run\npw_telemetry\n")
            self.assertEqual(
                VERIFIER.manifest_suffixes(
                    path,
                    prefix="pwsfm_",
                    aliases={"pw_telemetry": "telemetry"},
                ),
                {"run", "telemetry"},
            )
            path.write_text("pwofficial_run\nwrong_prefix\n")
            with self.assertRaisesRegex(ValueError, "unexpected symbol"):
                VERIFIER.manifest_suffixes(path, prefix="pwofficial_")


if __name__ == "__main__":
    unittest.main()
