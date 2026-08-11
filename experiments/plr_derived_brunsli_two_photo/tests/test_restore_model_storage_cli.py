from __future__ import annotations

import os
from pathlib import Path
import subprocess
import sys

from pw_plr.model_storage import encode_model_storage


ROOT = Path(__file__).resolve().parents[1]


def _run(storage: Path, output: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            sys.executable,
            str(ROOT / "run_restore_model_storage.py"),
            "--storage",
            str(storage),
            "--output",
            str(output),
        ],
        cwd=ROOT,
        check=False,
        capture_output=True,
        text=True,
    )


def test_raw_model_storage_is_restored_atomically_and_exactly(tmp_path: Path) -> None:
    model = os.urandom(8192)
    storage = tmp_path / "model.pwmst"
    output = tmp_path / "model.pwmod"
    storage.write_bytes(
        encode_model_storage(
            codec_id="raw", model_artifact=model, encoded_payload=model
        )
    )

    completed = _run(storage, output)

    assert completed.returncode == 0, completed.stderr
    assert output.read_bytes() == model
    assert not output.with_suffix(output.suffix + ".tmp").exists()


def test_corrupt_model_storage_fails_closed_without_publishing(tmp_path: Path) -> None:
    document = bytearray(
        encode_model_storage(
            codec_id="raw", model_artifact=b"model", encoded_payload=b"model"
        )
    )
    document[-1] ^= 1
    storage = tmp_path / "corrupt.pwmst"
    output = tmp_path / "model.pwmod"
    storage.write_bytes(document)

    completed = _run(storage, output)

    assert completed.returncode != 0
    assert "model storage SHA-256 mismatch" in completed.stderr
    assert not output.exists()
    assert not output.with_suffix(output.suffix + ".tmp").exists()
