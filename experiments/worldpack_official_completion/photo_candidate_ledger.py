"""Atomic per-photo progress ledger for an interruptible full-project run."""

from __future__ import annotations

from copy import deepcopy
import json
import os
from pathlib import Path
from typing import Any, Mapping


class PhotoCandidateLedger:
    def __init__(self, path: Path, document: dict[str, Any]) -> None:
        self.path = path
        self._document = document

    @classmethod
    def open(
        cls,
        path: Path,
        *,
        identity: Mapping[str, Any],
    ) -> "PhotoCandidateLedger":
        expected_identity = deepcopy(dict(identity))
        if path.exists():
            document = json.loads(path.read_bytes())
            if document.get("schema") != "pw_full_photo_candidate_progress_v1":
                raise ValueError("unsupported progress ledger")
            if document.get("identity") != expected_identity:
                raise ValueError("progress ledger identity mismatch")
            completed = document.get("completed")
            if not isinstance(completed, dict) or document.get("completed_count") != len(
                completed
            ):
                raise ValueError("invalid progress ledger completion state")
            return cls(path, document)
        document = {
            "schema": "pw_full_photo_candidate_progress_v1",
            "identity": expected_identity,
            "completed_count": 0,
            "completed": {},
        }
        ledger = cls(path, document)
        ledger._publish()
        return ledger

    def _publish(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        temporary = self.path.with_suffix(self.path.suffix + ".tmp")
        temporary.write_text(
            json.dumps(self._document, indent=2, sort_keys=True) + "\n"
        )
        os.replace(temporary, self.path)

    def get(self, logical_path: str) -> dict[str, Any] | None:
        value = self._document["completed"].get(logical_path)
        return deepcopy(value) if value is not None else None

    def record(self, logical_path: str, result: Mapping[str, Any]) -> None:
        if not logical_path:
            raise ValueError("logical photo path is empty")
        candidate = deepcopy(dict(result))
        current = self._document["completed"].get(logical_path)
        if current is not None:
            if current != candidate:
                raise ValueError("conflicting completed photo record")
            return
        self._document["completed"][logical_path] = candidate
        self._document["completed_count"] = len(self._document["completed"])
        self._publish()
