#!/usr/bin/env python3
"""Restore one self-contained terminal model envelope exactly."""

from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path
import subprocess
import tempfile

from pw_plr.model_storage import decode_model_storage


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while block := source.read(1024 * 1024):
            digest.update(block)
    return digest.hexdigest()


def _run(command: list[str]) -> None:
    subprocess.run(command, check=True, capture_output=True, text=True)


def restore_model_storage(
    storage: Path,
    output: Path,
    *,
    zstd: Path | None,
    zpaq: Path | None,
) -> None:
    decoded = decode_model_storage(storage.read_bytes())
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary_output = output.with_suffix(output.suffix + ".tmp")
    temporary_output.unlink(missing_ok=True)
    try:
        with tempfile.TemporaryDirectory(
            prefix="model-storage-", dir=output.parent
        ) as directory:
            payload = Path(directory) / "payload.encoded"
            payload.write_bytes(decoded.encoded_payload)
            if decoded.codec_id == "raw":
                temporary_output.write_bytes(decoded.encoded_payload)
            elif decoded.codec_id == "zstd_1_5_7_level22":
                if zstd is None or not zstd.is_file():
                    raise ValueError("registered Zstd decoder is required")
                _run(
                    [
                        str(zstd),
                        "-q",
                        "-d",
                        "-f",
                        str(payload),
                        "-o",
                        str(temporary_output),
                    ]
                )
            elif decoded.codec_id == "zpaq_7_15_method5":
                if zpaq is None or not zpaq.is_file():
                    raise ValueError("registered ZPAQ decoder is required")
                _run(
                    [
                        str(zpaq),
                        "decompress",
                        str(payload),
                        str(temporary_output),
                    ]
                )
            else:
                raise ValueError(
                    f"unsupported model storage codec: {decoded.codec_id}"
                )
        if (
            not temporary_output.is_file()
            or temporary_output.stat().st_size != decoded.model_bytes
            or _sha256(temporary_output) != decoded.model_sha256
        ):
            raise RuntimeError("restored model artifact identity mismatch")
        os.replace(temporary_output, output)
    except Exception:
        temporary_output.unlink(missing_ok=True)
        raise


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--storage", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--zstd", type=Path)
    parser.add_argument("--zpaq", type=Path)
    arguments = parser.parse_args()
    restore_model_storage(
        arguments.storage,
        arguments.output,
        zstd=arguments.zstd,
        zpaq=arguments.zpaq,
    )


if __name__ == "__main__":
    main()
