#!/usr/bin/env python3
"""Compare a candidate run with CUDA only under a measured noise floor."""

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
)
from metrics import compare_artifact_files


def _manifest_identity(run_dir: pathlib.Path) -> dict[str, str]:
    manifest = load_json(run_dir / "run_manifest.json")
    result: dict[str, str] = {}
    for key in ("artifact_contract_sha256", "input_manifest_sha256"):
        value = manifest.get(key)
        if not isinstance(value, str):
            fail(f"run manifest is missing {key}: {run_dir}")
        result[key] = value
    baseline = manifest.get("baseline_identity_sha256")
    if isinstance(baseline, str):
        result["baseline_identity_sha256"] = baseline
    return result


def compare(
    reference_dir: pathlib.Path,
    candidate_dir: pathlib.Path,
    noise_floor_path: pathlib.Path,
) -> dict[str, Any]:
    if not noise_floor_path.is_file():
        fail(f"noise-floor file does not exist: {noise_floor_path}")
    noise_floor = load_json(noise_floor_path)
    if noise_floor.get("schema_version") != 1:
        fail("noise-floor schema is unsupported")
    repeat_count = noise_floor.get("derived_from_repeat_baselines")
    if not isinstance(repeat_count, int) or repeat_count < 2:
        fail("noise-floor was not measured from repeated baselines")
    limits = noise_floor.get("limits_by_kind")
    if not isinstance(limits, dict) or not limits:
        fail("noise-floor has no measured limits")

    reference_manifest = validate_run_structure(reference_dir)
    candidate_manifest = validate_run_structure(candidate_dir)
    reference_identity = _manifest_identity(reference_dir)
    candidate_identity = _manifest_identity(candidate_dir)
    checked_contract = sha256_file(ARTIFACT_CONTRACT_PATH)
    if reference_identity["artifact_contract_sha256"] != checked_contract:
        fail("reference run uses a different artifact contract")
    if candidate_identity["artifact_contract_sha256"] != checked_contract:
        fail("candidate run uses a different artifact contract")
    if noise_floor.get("artifact_contract_sha256") != checked_contract:
        fail("noise-floor uses a different artifact contract")
    input_sha = reference_identity["input_manifest_sha256"]
    if candidate_identity["input_manifest_sha256"] != input_sha:
        fail("candidate and reference use different input manifests")
    if noise_floor.get("input_manifest_sha256") != input_sha:
        fail("noise-floor and reference use different input manifests")
    if noise_floor.get("baseline_identity_sha256") != reference_identity.get(
        "baseline_identity_sha256"
    ):
        fail("noise-floor was not measured from this CUDA baseline identity")

    pairs = same_structure(reference_manifest, candidate_manifest)
    results: list[dict[str, Any]] = []
    passed = True
    for left_entry, right_entry in pairs:
        kind = str(left_entry["kind"])
        kind_limits = limits.get(kind)
        if not isinstance(kind_limits, dict):
            fail(f"noise-floor has no measured limit for artifact kind {kind}")
        byte_limit = kind_limits.get("byte_mismatch_fraction_max")
        if (
            not isinstance(byte_limit, (int, float))
            or not math.isfinite(float(byte_limit))
            or byte_limit < 0
        ):
            fail(f"noise-floor byte limit is invalid for {kind}")
        delta = compare_artifact_files(
            reference_dir / left_entry["path"],
            candidate_dir / right_entry["path"],
            left_entry["dtype"],
        )
        artifact_passed = delta["byte_mismatch_fraction"] <= byte_limit
        if "max_abs" in delta:
            absolute_limit = kind_limits.get("max_abs_max")
            if (
                not isinstance(absolute_limit, (int, float))
                or not math.isfinite(float(absolute_limit))
                or absolute_limit < 0
            ):
                fail(f"noise-floor absolute limit is invalid for {kind}")
            artifact_passed = artifact_passed and delta["max_abs"] <= absolute_limit
        passed = passed and artifact_passed
        results.append(
            {
                "identity": list(artifact_identity(left_entry)),
                "metrics": delta,
                "measured_limits": kind_limits,
                "passed": artifact_passed,
            }
        )
    return {
        "schema_version": 1,
        "verdict": "pass" if passed else "fail",
        "reference": str(reference_dir),
        "candidate": str(candidate_dir),
        "noise_floor": str(noise_floor_path),
        "results": results,
    }


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Compare one run to CUDA using only a measured noise-floor."
    )
    parser.add_argument("--reference", required=True)
    parser.add_argument("--candidate", required=True)
    parser.add_argument("--noise-floor", required=True)
    parser.add_argument("--output-json")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        result = compare(
            pathlib.Path(args.reference).resolve(),
            pathlib.Path(args.candidate).resolve(),
            pathlib.Path(args.noise_floor).resolve(),
        )
        payload = json.dumps(result, indent=2, sort_keys=True) + "\n"
        if args.output_json:
            pathlib.Path(args.output_json).write_text(payload, encoding="utf-8")
        print(payload, end="")
        return 0 if result["verdict"] == "pass" else 1
    except ContractError as exc:
        print(f"FAIL-CLOSED: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
