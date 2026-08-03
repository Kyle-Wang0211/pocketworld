import hashlib
from pathlib import Path

import yaml

from semantic_slice import extract_minimum_slice


ROOT = Path(__file__).resolve().parents[1]


def _capture_root() -> Path:
    manifest = yaml.safe_load((ROOT / "input-manifest.yaml").read_text())
    return Path(manifest["capture"]["root"])


def test_selected_pair_is_deterministic_and_has_shared_geometry():
    first = extract_minimum_slice(_capture_root())
    second = extract_minimum_slice(_capture_root())
    assert first.identity_sha256 == second.identity_sha256
    assert first.child.capture_ordinal == first.root.capture_ordinal + 1
    assert first.verified_match_count > 0
    assert len(first.shared_anchor_ids) > 0


def test_slice_carries_exact_training_values():
    value = extract_minimum_slice(_capture_root())
    assert value.descriptor_shape == ((8192, 128), (8192, 128))
    assert all(len(blob) == rows * cols for blob, (rows, cols) in zip(
        value.descriptor_blobs, value.descriptor_shape, strict=True
    ))
    assert len(value.match_records_blob) == value.raw_match_count * 2 * 4
    assert value.logical_roundtrip_sha256() == value.identity_sha256


def test_jxl_members_restore_the_original_jpeg_bytes(tmp_path):
    value = extract_minimum_slice(_capture_root())
    restored = value.restore_original_jpegs(tmp_path)
    assert [path.stat().st_size for path in restored] == [
        value.root.jpeg_bytes,
        value.child.jpeg_bytes,
    ]
    assert [hashlib.sha256(path.read_bytes()).hexdigest() for path in restored] == [
        value.root.jpeg_sha256,
        value.child.jpeg_sha256,
    ]

