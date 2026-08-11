from __future__ import annotations

from pathlib import Path
import sys

import pytest


EXPERIMENT_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(EXPERIMENT_ROOT))

from worldpack import (  # noqa: E402
    MemberSpec,
    WorldPackCorruption,
    WorldPackReader,
    WorldPackWriter,
)


def _archive(tmp_path: Path) -> tuple[Path, object]:
    source = tmp_path / "source.bin"
    source.write_bytes(b"exact archive payload" * 100)
    archive = tmp_path / "valid.worldpack"
    result = WorldPackWriter(
        archive,
        manifest_sha256="22" * 32,
        scratch_root=tmp_path / "scratch",
        codecs=[],
    ).write([MemberSpec("source.bin", source, ("raw",))])
    return archive, result


def test_worldpack_rejects_payload_corruption_before_returning_bytes(
    tmp_path: Path,
) -> None:
    archive, result = _archive(tmp_path)
    damaged = bytearray(archive.read_bytes())
    damaged[result.entries[0].payload_offset + 7] ^= 0x80
    corrupt = tmp_path / "payload-corrupt.worldpack"
    corrupt.write_bytes(damaged)
    with pytest.raises(WorldPackCorruption, match="payload SHA-256"):
        WorldPackReader(corrupt, codecs=[]).read_member("source.bin")


def test_worldpack_rejects_footer_index_corruption_and_truncation(
    tmp_path: Path,
) -> None:
    archive, _ = _archive(tmp_path)
    encoded = archive.read_bytes()
    damaged = bytearray(encoded)
    damaged[-80] ^= 1
    corrupt = tmp_path / "index-corrupt.worldpack"
    corrupt.write_bytes(damaged)
    with pytest.raises(WorldPackCorruption):
        WorldPackReader(corrupt, codecs=[])

    truncated = tmp_path / "truncated.worldpack"
    truncated.write_bytes(encoded[:-1])
    with pytest.raises(WorldPackCorruption):
        WorldPackReader(truncated, codecs=[])


def test_worldpack_rejects_forward_or_out_of_range_dependency(
    tmp_path: Path,
) -> None:
    archive, result = _archive(tmp_path)
    damaged = bytearray(archive.read_bytes())
    dependency_offset = result.entries[0].chunk_offset + 16
    damaged[dependency_offset : dependency_offset + 8] = (7).to_bytes(
        8, "little", signed=True
    )
    corrupt = tmp_path / "dependency-corrupt.worldpack"
    corrupt.write_bytes(damaged)
    with pytest.raises(WorldPackCorruption):
        WorldPackReader(corrupt, codecs=[])

