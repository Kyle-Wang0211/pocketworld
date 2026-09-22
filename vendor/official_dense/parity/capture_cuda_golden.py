#!/usr/bin/env python3
"""Run an audited collector twice or more and record the official CUDA golden."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import pathlib
import subprocess
import sys
from typing import Any

from contract import (
    ARTIFACT_CONTRACT_PATH,
    ContractError,
    DEFAULT_PARAMETERS_PATH,
    fail,
    sha256_file,
    validate_run_structure,
    write_json_atomic,
)
from measure_noise_floor import measure
from preflight import collect_preflight


def _utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat()


def _json_sha256(value: dict[str, Any]) -> str:
    canonical = json.dumps(
        value, ensure_ascii=False, separators=(",", ":"), sort_keys=True
    ).encode("utf-8")
    return hashlib.sha256(canonical).hexdigest()


def _prepare_output(path: pathlib.Path) -> None:
    if path.exists() and any(path.iterdir()):
        fail(f"output directory is not empty; refusing to overwrite: {path}")
    path.mkdir(parents=True, exist_ok=True)


def capture(args: argparse.Namespace) -> dict[str, Any]:
    repeat_count = args.repeat_count
    if repeat_count < 2:
        fail("repeat_count < 2: an official noise floor requires repeated baselines")
    output_dir = pathlib.Path(args.output).expanduser().resolve()
    _prepare_output(output_dir)

    preflight = collect_preflight(args)
    write_json_atomic(output_dir / "preflight.json", preflight)
    baseline_identity_sha256 = _json_sha256(preflight)
    artifact_contract_sha256 = sha256_file(ARTIFACT_CONTRACT_PATH)
    input_manifest_sha256 = preflight["input_manifest"]["sha256"]
    state: dict[str, Any] = {
        "schema_version": 1,
        "status": "running",
        "started_at_utc": _utc_now(),
        "repeat_count": repeat_count,
        "completed_runs": [],
    }
    write_json_atomic(output_dir / "capture_state.json", state)

    run_dirs: list[pathlib.Path] = []
    collector = pathlib.Path(preflight["collector"]["path"])
    for run_index in range(repeat_count):
        run_id = f"official_cuda_repeat_{run_index:03d}"
        run_dir = output_dir / run_id
        run_dir.mkdir(parents=False, exist_ok=False)
        request = {
            "schema_version": 1,
            "purpose": "COLMAP 4.1.1 official CUDA stage capture; no algorithm changes",
            "run_id": run_id,
            "run_index": run_index,
            "output_dir": str(run_dir),
            "artifact_contract": str(ARTIFACT_CONTRACT_PATH),
            "artifact_contract_sha256": artifact_contract_sha256,
            "input_manifest": preflight["input_manifest"],
            "default_parameters": preflight["default_parameters"],
            "cuda": {
                "ptx_arch": preflight["cuda"]["ptx_arch"],
                "ptx_jit_required": True,
            },
        }
        request_path = run_dir / "collector_request.json"
        write_json_atomic(request_path, request)
        state["active_run"] = run_id
        write_json_atomic(output_dir / "capture_state.json", state)

        with (run_dir / "collector.stdout.log").open(
            "w", encoding="utf-8"
        ) as stdout, (run_dir / "collector.stderr.log").open(
            "w", encoding="utf-8"
        ) as stderr:
            result = subprocess.run(
                [str(collector), "--request-json", str(request_path)],
                check=False,
                stdout=stdout,
                stderr=stderr,
                text=True,
            )
        if result.returncode != 0:
            state["status"] = "failed"
            state["failed_run"] = run_id
            state["collector_exit_code"] = result.returncode
            state["finished_at_utc"] = _utc_now()
            write_json_atomic(output_dir / "capture_state.json", state)
            fail(
                f"collector failed for {run_id} with exit code {result.returncode}; "
                "failed artifacts and logs were preserved"
            )

        validate_run_structure(run_dir)
        run_manifest = {
            "schema_version": 1,
            "backend": "official_colmap_cuda",
            "run_id": run_id,
            "run_index": run_index,
            "repeat_count": repeat_count,
            "artifact_contract_sha256": artifact_contract_sha256,
            "input_manifest_sha256": input_manifest_sha256,
            "default_parameters_sha256": preflight["default_parameters_sha256"],
            "baseline_identity_sha256": baseline_identity_sha256,
            "collector_request_sha256": sha256_file(request_path),
            "collector_sha256": preflight["collector"]["sha256"],
            "colmap_commit": preflight["colmap"]["commit"],
            "cuda": preflight["cuda"],
            "finished_at_utc": _utc_now(),
        }
        write_json_atomic(run_dir / "run_manifest.json", run_manifest)
        run_dirs.append(run_dir)
        state["completed_runs"].append(run_id)
        state.pop("active_run", None)
        write_json_atomic(output_dir / "capture_state.json", state)

    noise_floor = measure(run_dirs)
    write_json_atomic(output_dir / "noise_floor.json", noise_floor)
    state["status"] = "complete"
    state["finished_at_utc"] = _utc_now()
    state["noise_floor_sha256"] = sha256_file(output_dir / "noise_floor.json")
    write_json_atomic(output_dir / "capture_state.json", state)
    return state


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Capture repeated official COLMAP CUDA goldens. The collector must "
            "implement the checked-in request/artifact protocol."
        )
    )
    parser.add_argument("--colmap-source")
    parser.add_argument("--colmap-bin")
    parser.add_argument("--collector-bin")
    parser.add_argument("--collector-sha256")
    parser.add_argument("--input-manifest")
    parser.add_argument("--input-manifest-sha256")
    parser.add_argument(
        "--default-parameters", default=str(DEFAULT_PARAMETERS_PATH)
    )
    parser.add_argument("--build-metadata")
    parser.add_argument("--expected-gpu-name", default="NVIDIA GeForce RTX 5090")
    parser.add_argument("--repeat-count", type=int, default=2)
    parser.add_argument("--output", required=True)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    output = pathlib.Path(args.output).expanduser().resolve()
    try:
        result = capture(args)
        print(json.dumps(result, indent=2, sort_keys=True))
        return 0
    except ContractError as exc:
        if output.is_dir():
            state_path = output / "capture_state.json"
            if state_path.exists():
                try:
                    state = json.loads(state_path.read_text(encoding="utf-8"))
                    state["status"] = "failed"
                    state["failure"] = str(exc)
                    state["finished_at_utc"] = _utc_now()
                    write_json_atomic(state_path, state)
                except (OSError, json.JSONDecodeError):
                    pass
        print(f"FAIL-CLOSED: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
