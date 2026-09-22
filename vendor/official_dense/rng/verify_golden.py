#!/usr/bin/env python3
"""Fail-closed validator for an official-CUDA COLMAP 4.1.1 RNG capture."""

from __future__ import annotations

import hashlib
import json
import math
from pathlib import Path
import struct
import sys
from typing import Any


SCHEMA = "pocketworld.colmap411.curand_xorwow_golden.v1"
UPSTREAM_COMMIT = "a0d785fba74b2664f31edc4a29026a8b27c00f67"
GPU_MAT_PRNG_SHA256 = (
    "aac48adcc68e558b3634141d327a352895ea90d351c254bce3e7d289f5ffe15f"
)
REQUIRED_KEYS = {
    "schema",
    "upstream_commit",
    "gpu_mat_prng_sha256",
    "cuda_runtime_version",
    "cuda_driver_version",
    "cuda_device_name",
    "cuda_device_uuid",
    "init_block",
    "width",
    "height",
    "seed",
    "subsequence",
    "offset",
    "state_word_count",
    "state_order",
    "state_file",
    "state_sha256",
    "draws_per_state",
    "uniform_order",
    "uniform_range",
    "uniform_bits_file",
    "uniform_bits_sha256",
    "endianness",
}


class InvalidGolden(ValueError):
    pass


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise InvalidGolden(message)


def _positive_int(value: Any, label: str) -> int:
    _require(type(value) is int and value > 0, f"{label} must be a positive int")
    return value


def _capture_identity(value: Any, label: str) -> str:
    _require(isinstance(value, str) and value.strip(), f"{label} is required")
    _require(not value.startswith("REQUIRED_"), f"{label} is still a placeholder")
    return value


def _sha256(value: Any, label: str) -> str:
    _require(isinstance(value, str), f"{label} must be a string")
    _require(len(value) == 64, f"{label} must contain 64 lowercase hex digits")
    _require(value == value.lower(), f"{label} must be lowercase")
    try:
        int(value, 16)
    except ValueError as error:
        raise InvalidGolden(f"{label} is not hexadecimal") from error
    return value


def _relative_payload(manifest_dir: Path, value: Any, label: str) -> Path:
    _require(isinstance(value, str) and value, f"{label} must be a filename")
    relative = Path(value)
    _require(not relative.is_absolute(), f"{label} must be relative")
    _require(".." not in relative.parts, f"{label} must not traverse parents")
    path = manifest_dir / relative
    _require(path.is_file(), f"{label} does not exist: {value}")
    return path


def _validate_file(path: Path, expected_size: int, expected_sha256: str) -> None:
    _require(path.stat().st_size == expected_size, f"wrong byte size: {path.name}")
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    _require(digest.hexdigest() == expected_sha256, f"SHA-256 mismatch: {path.name}")


def _validate_uniform_range(path: Path) -> None:
    with path.open("rb") as stream:
        while chunk := stream.read(4 * 16384):
            _require(len(chunk) % 4 == 0, "uniform payload is not uint32-aligned")
            for (bits,) in struct.iter_unpack("<I", chunk):
                value = struct.unpack("<f", struct.pack("<I", bits))[0]
                _require(math.isfinite(value), "uniform payload contains non-finite float")
                _require(value > 0.0 and value <= 1.0, "uniform value is outside (0,1]")


def validate(manifest_path: Path) -> None:
    with manifest_path.open("r", encoding="utf-8") as stream:
        manifest = json.load(stream)
    _require(isinstance(manifest, dict), "manifest root must be an object")
    missing = sorted(REQUIRED_KEYS - manifest.keys())
    _require(not missing, f"missing keys: {', '.join(missing)}")

    _require(manifest["schema"] == SCHEMA, "wrong schema")
    _require(manifest["upstream_commit"] == UPSTREAM_COMMIT, "wrong upstream commit")
    _require(
        manifest["gpu_mat_prng_sha256"] == GPU_MAT_PRNG_SHA256,
        "wrong gpu_mat_prng.cu SHA-256",
    )
    _require(manifest["init_block"] == [32, 16, 1], "wrong init block")
    _require(manifest["seed"] == "linear_thread_id", "wrong seed mapping")
    _require(manifest["subsequence"] == 0, "subsequence must be zero")
    _require(manifest["offset"] == 0, "offset must be zero")
    _require(manifest["state_order"] == "state_word,row,col", "wrong state order")
    _require(manifest["uniform_order"] == "draw,row,col", "wrong uniform order")
    _require(manifest["uniform_range"] == "(0,1]", "wrong uniform range")
    _require(manifest["endianness"] == "little", "wrong endianness")

    for key in ("cuda_runtime_version", "cuda_driver_version", "cuda_device_uuid"):
        _capture_identity(manifest[key], key)
    cuda_device_name = _capture_identity(manifest["cuda_device_name"], "cuda_device_name")
    _require("5090" in cuda_device_name, "golden capture must come from a 5090")

    width = _positive_int(manifest["width"], "width")
    height = _positive_int(manifest["height"], "height")
    state_word_count = _positive_int(manifest["state_word_count"], "state_word_count")
    draws_per_state = _positive_int(manifest["draws_per_state"], "draws_per_state")

    state_path = _relative_payload(
        manifest_path.parent, manifest["state_file"], "state_file"
    )
    uniform_path = _relative_payload(
        manifest_path.parent, manifest["uniform_bits_file"], "uniform_bits_file"
    )
    state_hash = _sha256(manifest["state_sha256"], "state_sha256")
    uniform_hash = _sha256(
        manifest["uniform_bits_sha256"], "uniform_bits_sha256"
    )

    pixels = width * height
    _validate_file(state_path, state_word_count * pixels * 4, state_hash)
    _validate_file(uniform_path, draws_per_state * pixels * 4, uniform_hash)
    _validate_uniform_range(uniform_path)


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("INVALID: usage: verify_golden.py MANIFEST.json", file=sys.stderr)
        return 2
    try:
        validate(Path(argv[1]))
    except (InvalidGolden, OSError, json.JSONDecodeError) as error:
        print(f"INVALID: {error}", file=sys.stderr)
        return 1
    print("VALID: structurally consistent 5090 CUDA RNG golden capture")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
