from __future__ import annotations

import json
from pathlib import Path

import pytest

from photo_candidate_ledger import PhotoCandidateLedger


def test_ledger_resumes_only_the_same_frozen_experiment(tmp_path: Path) -> None:
    path = tmp_path / "progress.json"
    identity = {
        "checkpoint_sha256": "11" * 32,
        "logical_photo_identity_sha256": "22" * 32,
    }
    ledger = PhotoCandidateLedger.open(path, identity=identity)
    record = {
        "source_sha256": "33" * 32,
        "archive_bytes": 123,
        "archive_sha256": "44" * 32,
    }
    ledger.record("photos/a.jpg", record)

    resumed = PhotoCandidateLedger.open(path, identity=identity)
    assert resumed.get("photos/a.jpg") == record
    assert json.loads(path.read_text())["completed_count"] == 1

    with pytest.raises(ValueError, match="identity"):
        PhotoCandidateLedger.open(
            path,
            identity={**identity, "checkpoint_sha256": "55" * 32},
        )


def test_ledger_is_idempotent_but_rejects_conflicting_rewrites(tmp_path: Path) -> None:
    ledger = PhotoCandidateLedger.open(tmp_path / "progress.json", identity={"id": 1})
    ledger.record("photos/a.jpg", {"bytes": 10})
    ledger.record("photos/a.jpg", {"bytes": 10})
    with pytest.raises(ValueError, match="conflicting"):
        ledger.record("photos/a.jpg", {"bytes": 11})
