"""CPU-only, separate-process terminal codec for exact JPEG coefficients."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

import torch
import yaml

from pw_plr.coefficient_archive import build_pwcf_from_mlcc_tiles
from pw_plr.dct_training import read_training_coefficients
from pw_plr.model_artifact import decode_model_artifact, encode_model_artifact
from pw_plr.model_photo_codec import decode_photo_with_model, encode_photo_with_model


def _atomic_write(path: Path, document: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.unlink(missing_ok=True)
    temporary.write_bytes(document)
    os.replace(temporary, path)


def _atomic_json(path: Path, value: dict[str, object]) -> None:
    _atomic_write(
        path,
        (json.dumps(value, indent=2, sort_keys=True) + "\n").encode("utf-8"),
    )


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def _model_class(upstream: Path):
    sys.path.insert(0, str(upstream.resolve()))
    from compressai.models.base_eff import EfficientJPEGRecompression

    return EfficientJPEGRecompression


def _configure_cpu() -> None:
    for name in (
        "OMP_NUM_THREADS",
        "MKL_NUM_THREADS",
        "VECLIB_MAXIMUM_THREADS",
    ):
        if os.environ.get(name) != "1":
            raise RuntimeError(f"terminal codec requires {name}=1")
    torch.set_num_threads(1)
    torch.set_num_interop_threads(1)
    torch.use_deterministic_algorithms(True)


def _encode(arguments: argparse.Namespace) -> None:
    config_bytes = arguments.config.read_bytes()
    config = yaml.safe_load(config_bytes)
    checkpoint_bytes = arguments.checkpoint.read_bytes()
    checkpoint = torch.load(arguments.checkpoint, map_location="cpu")
    if checkpoint.get("schema") != "pw_plr_phase2_checkpoint_v1":
        raise ValueError("unsupported Phase 2 checkpoint")
    arm_id = str(checkpoint["arm"])
    arms = {str(arm["id"]): arm for arm in config["model_arms"]}
    if arm_id not in arms:
        raise ValueError("checkpoint arm is absent from terminal config")
    arm = arms[arm_id]
    chunks = tuple(str(value) for value in config["implementation"]["chunks"])
    model_type = _model_class(arguments.upstream)
    model = model_type(N=int(arm["N"]), M=int(arm["M"]), chunk=chunks).eval()
    model.load_state_dict(checkpoint["model"])
    model.update(force=True)

    identity = {
        "schema": "pw_plr_terminal_model_identity_v1",
        "arm": arm_id,
        "N": int(arm["N"]),
        "M": int(arm["M"]),
        "chunks": list(chunks),
        "checkpoint_sha256": hashlib.sha256(checkpoint_bytes).hexdigest(),
        "config_sha256": hashlib.sha256(config_bytes).hexdigest(),
        "entropy_tables": "post_update_embedded",
    }
    artifact = encode_model_artifact(model.state_dict(), identity)
    coefficients = read_training_coefficients(arguments.coefficients)
    with torch.no_grad():
        encoded = encode_photo_with_model(model, coefficients)
    _atomic_write(arguments.model_artifact, artifact)
    _atomic_write(arguments.archive, encoded.archive)
    _atomic_json(arguments.trace, encoded.trace)


def _load_artifact_model(upstream: Path, artifact_path: Path):
    decoded_artifact = decode_model_artifact(artifact_path.read_bytes())
    identity = decoded_artifact.identity
    if identity.get("schema") != "pw_plr_terminal_model_identity_v1":
        raise ValueError("unsupported terminal model identity")
    model_type = _model_class(upstream)
    model = model_type(
        N=int(identity["N"]),
        M=int(identity["M"]),
        chunk=tuple(str(value) for value in identity["chunks"]),
    ).eval()
    model.load_state_dict(decoded_artifact.state_dict)
    return model


def _encode_artifact(arguments: argparse.Namespace) -> None:
    model = _load_artifact_model(arguments.upstream, arguments.model_artifact)
    coefficients = read_training_coefficients(arguments.coefficients)
    with torch.no_grad():
        encoded = encode_photo_with_model(model, coefficients)
    _atomic_write(arguments.archive, encoded.archive)
    _atomic_json(arguments.trace, encoded.trace)


def _restore_jpeg(arguments: argparse.Namespace, pwcf: Path) -> None:
    restore_options = (arguments.side, arguments.adapter, arguments.jpeg)
    if all(value is None for value in restore_options):
        return
    if any(value is None for value in restore_options):
        raise ValueError("--side, --adapter, and --jpeg must be supplied together")
    arguments.jpeg.parent.mkdir(parents=True, exist_ok=True)
    temporary = arguments.jpeg.with_suffix(arguments.jpeg.suffix + ".tmp")
    temporary.unlink(missing_ok=True)
    completed = subprocess.run(
        [
            str(arguments.adapter),
            "restore",
            str(arguments.side),
            str(pwcf),
            str(temporary),
        ],
        check=False,
        capture_output=True,
        text=True,
    )
    if completed.returncode != 0:
        temporary.unlink(missing_ok=True)
        raise RuntimeError(
            "Brunsli restore failed: "
            f"returncode={completed.returncode} stderr={completed.stderr.strip()}"
        )
    os.replace(temporary, arguments.jpeg)


def _decode(arguments: argparse.Namespace) -> None:
    model = _load_artifact_model(arguments.upstream, arguments.model_artifact)
    with torch.no_grad():
        decoded = decode_photo_with_model(model, arguments.archive.read_bytes())
    pwcf = build_pwcf_from_mlcc_tiles(decoded.coefficients, list(decoded.tiles))
    _atomic_write(arguments.pwcf, pwcf)
    _atomic_json(arguments.trace, decoded.trace)
    _restore_jpeg(arguments, arguments.pwcf)
    if arguments.jpeg is not None:
        if arguments.jpeg.stat().st_size != decoded.coefficients.source_bytes:
            raise RuntimeError("restored JPEG byte count mismatch")
        if _sha256(arguments.jpeg) != decoded.coefficients.source_sha256:
            raise RuntimeError("restored JPEG SHA-256 mismatch")


def main() -> None:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    encode = subparsers.add_parser("encode")
    encode.add_argument("--checkpoint", type=Path, required=True)
    encode.add_argument("--config", type=Path, required=True)
    encode.add_argument("--upstream", type=Path, required=True)
    encode.add_argument("--coefficients", type=Path, required=True)
    encode.add_argument("--archive", type=Path, required=True)
    encode.add_argument("--model-artifact", type=Path, required=True)
    encode.add_argument("--trace", type=Path, required=True)

    encode_artifact = subparsers.add_parser("encode-artifact")
    encode_artifact.add_argument("--upstream", type=Path, required=True)
    encode_artifact.add_argument("--model-artifact", type=Path, required=True)
    encode_artifact.add_argument("--coefficients", type=Path, required=True)
    encode_artifact.add_argument("--archive", type=Path, required=True)
    encode_artifact.add_argument("--trace", type=Path, required=True)

    decode = subparsers.add_parser("decode")
    decode.add_argument("--upstream", type=Path, required=True)
    decode.add_argument("--model-artifact", type=Path, required=True)
    decode.add_argument("--archive", type=Path, required=True)
    decode.add_argument("--pwcf", type=Path, required=True)
    decode.add_argument("--trace", type=Path, required=True)
    decode.add_argument("--side", type=Path)
    decode.add_argument("--adapter", type=Path)
    decode.add_argument("--jpeg", type=Path)

    arguments = parser.parse_args()
    _configure_cpu()
    if arguments.command == "encode":
        _encode(arguments)
    elif arguments.command == "encode-artifact":
        _encode_artifact(arguments)
    else:
        _decode(arguments)


if __name__ == "__main__":
    main()
