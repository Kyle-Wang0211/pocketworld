import hashlib
from pathlib import Path

import pytest
import yaml

from pw_plr.input_identity import InputIdentityError, verify_inputs


def _write_manifest(
    path: Path,
    entries: list[dict[str, object]],
) -> None:
    path.write_text(yaml.safe_dump({"inputs": entries}, sort_keys=False))


def _entry(role: str, path: Path, payload: bytes) -> dict[str, object]:
    return {
        "role": role,
        "filename": path.name,
        "path": str(path),
        "bytes": len(payload),
        "sha256": hashlib.sha256(payload).hexdigest(),
    }


def test_verify_inputs_preserves_registered_order(tmp_path: Path) -> None:
    source_b = tmp_path / "b.jpg"
    source_a = tmp_path / "a.jpg"
    source_b.write_bytes(b"second")
    source_a.write_bytes(b"first")
    manifest = tmp_path / "manifest.yaml"
    _write_manifest(
        manifest,
        [
            _entry("B", source_b, b"second"),
            _entry("A", source_a, b"first"),
        ],
    )

    verified = verify_inputs(manifest)

    assert [item.role for item in verified] == ["B", "A"]
    assert [item.path for item in verified] == [source_b, source_a]
    assert [item.bytes for item in verified] == [6, 5]


def test_verify_inputs_rejects_length_mismatch(tmp_path: Path) -> None:
    source = tmp_path / "a.jpg"
    source.write_bytes(b"source")
    entry = _entry("A", source, b"source")
    entry["bytes"] = 999
    manifest = tmp_path / "manifest.yaml"
    _write_manifest(manifest, [entry])

    with pytest.raises(InputIdentityError, match="byte length mismatch"):
        verify_inputs(manifest)


def test_verify_inputs_rejects_sha_mismatch(tmp_path: Path) -> None:
    source = tmp_path / "a.jpg"
    source.write_bytes(b"source")
    entry = _entry("A", source, b"source")
    entry["sha256"] = "0" * 64
    manifest = tmp_path / "manifest.yaml"
    _write_manifest(manifest, [entry])

    with pytest.raises(InputIdentityError, match="SHA-256 mismatch"):
        verify_inputs(manifest)


def test_verify_inputs_rejects_duplicate_roles(tmp_path: Path) -> None:
    first = tmp_path / "a.jpg"
    second = tmp_path / "b.jpg"
    first.write_bytes(b"a")
    second.write_bytes(b"b")
    manifest = tmp_path / "manifest.yaml"
    _write_manifest(
        manifest,
        [_entry("A", first, b"a"), _entry("A", second, b"b")],
    )

    with pytest.raises(InputIdentityError, match="duplicate input role"):
        verify_inputs(manifest)


def test_verify_inputs_rejects_missing_file(tmp_path: Path) -> None:
    missing = tmp_path / "missing.jpg"
    manifest = tmp_path / "manifest.yaml"
    _write_manifest(manifest, [_entry("A", missing, b"missing")])

    with pytest.raises(InputIdentityError, match="not a readable file"):
        verify_inputs(manifest)
