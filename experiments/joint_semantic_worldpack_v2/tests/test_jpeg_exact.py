import hashlib
from pathlib import Path

import pytest
import yaml

from jpeg_exact import (
    ExactJpegError,
    build_coefficient_tool,
    extract_exact_jpeg,
    extract_exact_jpeg_bytes,
    restore_exact_jpeg,
)
from semantic_slice import extract_minimum_slice


ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = ROOT.parents[1]


@pytest.fixture(scope="module")
def minimum_slice():
    manifest = yaml.safe_load((ROOT / "input-manifest.yaml").read_text())
    return extract_minimum_slice(Path(manifest["capture"]["root"]))


def test_both_frozen_jpegs_restore_byte_for_byte(minimum_slice, tmp_path):
    tool = build_coefficient_tool(
        REPOSITORY / "experiments/cross_photo_lossless_potential/jpeg_coeff_tool.cpp",
        tmp_path / "jpeg_coeff_tool",
    )
    source_paths = minimum_slice.restore_original_jpegs(tmp_path / "source")
    for photo, source in zip(
        (minimum_slice.root, minimum_slice.child), source_paths, strict=True
    ):
        logical = extract_exact_jpeg(source, tool)
        restored = restore_exact_jpeg(logical, tool)
        assert restored == source.read_bytes()
        assert hashlib.sha256(restored).hexdigest() == photo.jpeg_sha256
        assert logical.source_sha256 == photo.jpeg_sha256
        assert logical.component_shapes
        assert logical.coefficient_count > 0


def test_truncated_input_fails_closed(tmp_path):
    tool = build_coefficient_tool(
        REPOSITORY / "experiments/cross_photo_lossless_potential/jpeg_coeff_tool.cpp",
        tmp_path / "jpeg_coeff_tool",
    )
    with pytest.raises(ExactJpegError):
        extract_exact_jpeg_bytes(b"\xff\xd8\xff", tool)

