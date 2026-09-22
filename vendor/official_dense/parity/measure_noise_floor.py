#!/usr/bin/env python3
"""Measure (never guess) limits from repeated official CUDA baseline runs."""

from __future__ import annotations

import argparse
import json
import math
import pathlib
import sys
from typing import Any

from contract import (
    ARTIFACT_CONTRACT_PATH,
    ContractError,
    artifact_identity,
    fail,
    load_json,
    same_structure,
    sha256_file,
    validate_run_structure,
    write_json_atomic,
)
from metrics import compare_artifact_files


def _run_identity(run_dir: pathlib.Path) -> tuple[str, str, str]:
    manifest = load_json(run_dir / "run_manifest.json")
    contract_sha = manifest.get("artifact_contract_sha256")
    input_sha = manifest.get("input_manifest_sha256")
    baseline_sha = manifest.get("baseline_identity_sha256")
    if not all(isinstance(value, str) for value in (contract_sha, input_sha, baseline_sha)):
        fail(f"run manifest identity is incomplete: {run_dir}")
    return contract_sha, input_sha, baseline_sha


def measure(run_dirs: list[pathlib.Path]) -> dict[str, Any]:
    if len(run_dirs) < 2:
        fail("noise floor requires at least two repeated official CUDA baselines")
    manifests = [validate_run_structure(path) for path in run_dirs]
    identities = [_run_identity(path) for path in run_dirs]
    if len(set(identities)) != 1:
        fail("repeated baselines do not share one immutable baseline identity")
    contract_sha, input_sha, baseline_sha = identities[0]
    if contract_sha != sha256_file(ARTIFACT_CONTRACT_PATH):
        fail("run artifact contract does not match the checked-in contract")

    reference_dir = run_dirs[0]
    reference_manifest = manifests[0]
    limits: dict[str, dict[str, float]] = {}
    comparisons = 0
    for candidate_dir, candidate_manifest in zip(run_dirs[1:], manifests[1:]):
        pairs = same_structure(reference_manifest, candidate_manifest)
        for left_entry, right_entry in pairs:
            kind = str(left_entry["kind"])
            left_path = reference_dir / left_entry["path"]
            right_path = candidate_dir / right_entry["path"]
            delta = compare_artifact_files(left_path, right_path, left_entry["dtype"])
            current = limits.setdefault(
                kind,
                {
                    "byte_mismatch_fraction_max": 0.0,
                },
            )
            current["byte_mismatch_fraction_max"] = max(
                current["byte_mismatch_fraction_max"],
                float(delta["byte_mismatch_fraction"]),
            )
            if "max_abs" in delta:
                if not math.isfinite(float(delta["max_abs"])):
                    fail(
                        f"non-finite float delta in repeated baseline artifact {kind}"
                    )
                current["max_abs_max"] = max(
                    current.get("max_abs_max", 0.0), float(delta["max_abs"])
                )
            comparisons += 1
    return {
        "schema_version": 1,
        "derived_from_repeat_baselines": len(run_dirs),
        "derivation": "observed maxima only; no multiplier or guessed tolerance",
        "artifact_contract_sha256": contract_sha,
        "input_manifest_sha256": input_sha,
        "baseline_identity_sha256": baseline_sha,
        "baseline_runs": [str(path.resolve()) for path in run_dirs],
        "artifact_comparisons": comparisons,
        "limits_by_kind": limits,
    }


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Derive measured parity limits from repeated CUDA baselines."
    )
    parser.add_argument("--run", action="append", default=[])
    parser.add_argument("--output", required=True)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        payload = measure([pathlib.Path(value).resolve() for value in args.run])
        write_json_atomic(pathlib.Path(args.output).resolve(), payload)
        print(json.dumps(payload, indent=2, sort_keys=True))
        return 0
    except ContractError as exc:
        print(f"FAIL-CLOSED: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
