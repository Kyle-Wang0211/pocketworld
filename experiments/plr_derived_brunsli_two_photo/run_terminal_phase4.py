"""Measure the frozen JXL baseline once and issue the terminal two-photo verdict."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

import yaml

from pw_plr.terminal_baseline_diagnostic import classify_secondary_baseline
from pw_plr.terminal_accounting import decide_terminal_pair


PINNED_LIBJXL_COMMIT = "a7a9c787341cf703dede03c2009fa460cae5e5df"
PINNED_LEPTON_COMMIT = "90fdc27828676892fbb41777cfcc6bad1e470516"
PINNED_LEPTON_HOST_SHA256 = (
    "3173002ec9b63ea11de48c6c5c48a653d0060abb024100bf5865a7049c8a907e"
)


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while block := source.read(1024 * 1024):
            digest.update(block)
    return digest.hexdigest()


def _run(command: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, check=True, capture_output=True, text=True)


def _atomic_json(path: Path, value: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    os.replace(temporary, path)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--phase3", type=Path, required=True)
    parser.add_argument("--input-manifest", type=Path, required=True)
    parser.add_argument("--cjxl", type=Path, required=True)
    parser.add_argument("--djxl", type=Path, required=True)
    parser.add_argument("--jxl-build-manifest", type=Path, required=True)
    parser.add_argument("--lepton", type=Path, required=True)
    parser.add_argument("--work-directory", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()
    if arguments.output.exists():
        raise FileExistsError("terminal Phase 4 result exists; JXL rerun forbidden")
    started = time.monotonic()
    phase3 = json.loads(arguments.phase3.read_bytes())
    if (
        phase3.get("status") != "phase3_selected_model_exact_pair_complete"
        or phase3.get("jxl_measured") is not False
        or phase3.get("terminal_winner_declared") is not False
        or phase3.get("source_unchanged") is not True
    ):
        raise RuntimeError("Phase 3 exact terminal evidence gate failed")
    build = json.loads(arguments.jxl_build_manifest.read_bytes())
    if (
        build.get("schema") != "pw_plr_libjxl_host_build_v1"
        or build.get("revision") != PINNED_LIBJXL_COMMIT
        or build.get("version") != "0.12.0"
        or _sha256(arguments.cjxl) != build.get("cjxl_sha256")
        or _sha256(arguments.djxl) != build.get("djxl_sha256")
    ):
        raise RuntimeError("pinned libjxl host build identity mismatch")
    if (
        not arguments.lepton.is_file()
        or _sha256(arguments.lepton) != PINNED_LEPTON_HOST_SHA256
    ):
        raise RuntimeError("pinned Lepton 0.5.8 host binary identity mismatch")
    cjxl_version = _run([str(arguments.cjxl), "--version"]).stdout.strip()
    djxl_version = _run([str(arguments.djxl), "--version"]).stdout.strip()
    if "v0.12.0" not in cjxl_version or "v0.12.0" not in djxl_version:
        raise RuntimeError("terminal JXL binaries are not version 0.12.0")
    manifest = yaml.safe_load(arguments.input_manifest.read_bytes())
    inputs = {str(item["role"]): item for item in manifest["inputs"]}
    arguments.work_directory.mkdir(parents=True, exist_ok=True)
    roles: list[dict[str, object]] = []
    for role in ("A", "B"):
        item = inputs[role]
        source = Path(item["path"])
        if source.stat().st_size != item["bytes"] or _sha256(source) != item["sha256"]:
            raise RuntimeError(f"frozen JXL input identity changed: {role}")
        archive = arguments.work_directory / f"{role}.jxl"
        restored = arguments.work_directory / f"{role}.restored.jpg"
        lepton_archive = arguments.work_directory / f"{role}.lep"
        lepton_restored = arguments.work_directory / f"{role}.lepton.restored.jpg"
        with tempfile.TemporaryDirectory(
            prefix=f"jxl-{role}-", dir=arguments.work_directory
        ) as name:
            temporary_archive = Path(name) / f"{role}.jxl"
            temporary_restored = Path(name) / f"{role}.jpg"
            _run(
                [
                    str(arguments.cjxl),
                    "--lossless_jpeg=1",
                    "--effort=10",
                    str(source),
                    str(temporary_archive),
                ]
            )
            _run(
                [
                    str(arguments.djxl),
                    str(temporary_archive),
                    str(temporary_restored),
                ]
            )
            os.replace(temporary_archive, archive)
            os.replace(temporary_restored, restored)
        with tempfile.TemporaryDirectory(
            prefix=f"lepton-{role}-", dir=arguments.work_directory
        ) as name:
            temporary_archive = Path(name) / f"{role}.lep"
            temporary_restored = Path(name) / f"{role}.jpg"
            _run(
                [
                    str(arguments.lepton),
                    "--quiet",
                    "--overwrite",
                    str(source),
                    str(temporary_archive),
                ]
            )
            _run(
                [
                    str(arguments.lepton),
                    "--quiet",
                    "--overwrite",
                    str(temporary_archive),
                    str(temporary_restored),
                ]
            )
            os.replace(temporary_archive, lepton_archive)
            os.replace(temporary_restored, lepton_restored)
        byte_equal = restored.read_bytes() == source.read_bytes()
        sha_equal = _sha256(restored) == item["sha256"]
        lepton_byte_equal = lepton_restored.read_bytes() == source.read_bytes()
        lepton_sha_equal = _sha256(lepton_restored) == item["sha256"]
        if not byte_equal or not sha_equal or not lepton_byte_equal or not lepton_sha_equal:
            raise RuntimeError(f"exact-JPEG baseline failed: {role}")
        roles.append(
            {
                "role": role,
                "source_bytes": source.stat().st_size,
                "source_sha256": _sha256(source),
                "jxl_bytes": archive.stat().st_size,
                "jxl_sha256": _sha256(archive),
                "restored_bytes": restored.stat().st_size,
                "restored_sha256": _sha256(restored),
                "byte_equal": True,
                "sha256_equal": True,
                "lepton_bytes": lepton_archive.stat().st_size,
                "lepton_sha256": _sha256(lepton_archive),
                "lepton_restored_bytes": lepton_restored.stat().st_size,
                "lepton_restored_sha256": _sha256(lepton_restored),
                "lepton_byte_equal": True,
                "lepton_sha256_equal": True,
            }
        )
    jxl_pair_bytes = sum(int(item["jxl_bytes"]) for item in roles)
    lepton_pair_bytes = sum(int(item["lepton_bytes"]) for item in roles)
    decision = decide_terminal_pair(
        jxl_pair_bytes=jxl_pair_bytes,
        photo_stream_bytes=int(phase3["photo_stream_bytes"]),
        complete_model_storage_bytes=int(phase3["complete_model_storage_bytes"]),
        formal_scope_photo_count=96,
        approved_scope_max=300,
    )
    result: dict[str, object] = {
        "schema": "pw_plr_terminal_phase4_result_v1",
        "terminal_state": decision.state,
        "jxl_measurement_count_per_input": 1,
        "lepton_measurement_count_per_input": 1,
        "jxl_version": "0.12.0",
        "jxl_revision": PINNED_LIBJXL_COMMIT,
        "cjxl_sha256": _sha256(arguments.cjxl),
        "djxl_sha256": _sha256(arguments.djxl),
        "lepton_version": "0.5.8",
        "lepton_revision": PINNED_LEPTON_COMMIT,
        "lepton_binary_sha256": _sha256(arguments.lepton),
        "effort": 10,
        "lossless_jpeg_reconstruction": True,
        "roles": roles,
        "jxl_pair_bytes": jxl_pair_bytes,
        "lepton_pair_bytes": lepton_pair_bytes,
        "candidate_photo_stream_bytes": phase3["photo_stream_bytes"],
        "candidate_complete_model_storage_bytes": phase3[
            "complete_model_storage_bytes"
        ],
        "candidate_accounted_model_bytes_at_96": phase3[
            "accounted_model_bytes"
        ],
        "candidate_total_accounted_bytes_at_96": (
            decision.formal_total_accounted_bytes
        ),
        "candidate_minus_jxl_bytes_at_96": (
            decision.formal_total_accounted_bytes - jxl_pair_bytes
        ),
        "candidate_minus_lepton_bytes_at_96": (
            decision.formal_total_accounted_bytes - lepton_pair_bytes
        ),
        "secondary_baseline_diagnostic": classify_secondary_baseline(
            candidate_bytes=decision.formal_total_accounted_bytes,
            formal_jxl_bytes=jxl_pair_bytes,
            diagnostic_lepton_bytes=lepton_pair_bytes,
        ),
        "stream_headroom_before_model_accounting": (
            decision.stream_headroom_bytes
        ),
        "minimum_scope_break_even": decision.minimum_scope_break_even,
        "break_even_reachable_under_approved_scope": (
            decision.minimum_scope_break_even is not None
            and decision.minimum_scope_break_even <= 300
        ),
        "strictly_smaller_than_jxl_at_96": (
            decision.formal_total_accounted_bytes < jxl_pair_bytes
        ),
        "strictly_smaller_than_lepton_at_96": (
            decision.formal_total_accounted_bytes < lepton_pair_bytes
        ),
        "source_unchanged": all(
            _sha256(Path(inputs[role]["path"])) == inputs[role]["sha256"]
            for role in ("A", "B")
        ),
        "wall_seconds": time.monotonic() - started,
        "production_promoted": False,
        "phone_accessed": False,
    }
    _atomic_json(arguments.output, result)
    print(json.dumps(result, sort_keys=True), flush=True)


if __name__ == "__main__":
    main()
