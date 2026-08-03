"""Immutable input identity verification for the frozen JPEG pair."""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
from pathlib import Path

import yaml


class InputIdentityError(ValueError):
    """Raised when a registered input does not match its immutable identity."""


@dataclass(frozen=True)
class VerifiedInput:
    role: str
    path: Path
    bytes: int
    sha256: str


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while chunk := source.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def verify_inputs(manifest_path: Path) -> tuple[VerifiedInput, ...]:
    manifest = yaml.safe_load(manifest_path.read_text())
    entries = manifest["inputs"]
    seen_roles: set[str] = set()
    verified: list[VerifiedInput] = []

    for entry in entries:
        role = str(entry["role"])
        if role in seen_roles:
            raise InputIdentityError(f"duplicate input role: {role}")
        seen_roles.add(role)

        path = Path(entry["path"])
        if not path.is_file():
            raise InputIdentityError(f"not a readable file: {path}")

        registered_bytes = int(entry["bytes"])
        actual_bytes = path.stat().st_size
        if actual_bytes != registered_bytes:
            raise InputIdentityError(
                f"byte length mismatch for {role}: "
                f"registered={registered_bytes} actual={actual_bytes}"
            )

        registered_sha256 = str(entry["sha256"]).lower()
        actual_sha256 = _sha256_file(path)
        if actual_sha256 != registered_sha256:
            raise InputIdentityError(
                f"SHA-256 mismatch for {role}: "
                f"registered={registered_sha256} actual={actual_sha256}"
            )

        verified.append(
            VerifiedInput(
                role=role,
                path=path,
                bytes=actual_bytes,
                sha256=actual_sha256,
            )
        )

    return tuple(verified)
