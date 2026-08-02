from __future__ import annotations

import hashlib
import json
from pathlib import Path

import run_benchmark


def test_zpaq_arm_resumes_valid_checkpoint_without_overwriting(tmp_path: Path) -> None:
    source = tmp_path / "test.bundle"
    source.write_bytes(b"strict-lossless-source")
    archive = tmp_path / "zpaq_method5.zpaq"
    archive.write_bytes(b"persisted-archive")
    restored = tmp_path / "zpaq_method5.restored"
    restored.write_bytes(source.read_bytes())
    source_sha = hashlib.sha256(source.read_bytes()).hexdigest()
    arm = {
        "mode": "zpaq_method5",
        "input_bytes": source.stat().st_size,
        "frame_bytes": archive.stat().st_size,
        "decoder_dependency_bytes": 0,
        "complete_persisted_bytes": archive.stat().st_size,
        "encoder_model_bytes": 0,
        "training_completed": 0,
        "completion_semantics": "not_applicable",
        "byte_equal": 1,
        "sha256_equal": 1,
        "source_sha256": source_sha,
        "restored_sha256": source_sha,
        "corruption_rejected": 1,
        "training_microseconds": 0,
        "compression_microseconds": 1,
        "decompression_microseconds": 1,
        "typed_data_streams": 3,
    }
    (tmp_path / "zpaq_method5.checkpoint.json").write_text(
        json.dumps(
            {
                "test_sha256": source_sha,
                "archive_sha256": hashlib.sha256(archive.read_bytes()).hexdigest(),
                "arm": arm,
            }
        )
    )

    assert run_benchmark._zpaq_arm(source, tmp_path) == arm
