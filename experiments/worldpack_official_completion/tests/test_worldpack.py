from __future__ import annotations

import hashlib
from pathlib import Path
import sys
import zlib


EXPERIMENT_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(EXPERIMENT_ROOT))

from worldpack import (  # noqa: E402
    FileCodec,
    MemberSpec,
    WorldPackReader,
    WorldPackWriter,
)


def _zlib_codec() -> FileCodec:
    def encode(source: Path, destination: Path) -> None:
        destination.write_bytes(zlib.compress(source.read_bytes(), level=9))

    def decode(source: Path, destination: Path) -> None:
        destination.write_bytes(zlib.decompress(source.read_bytes()))

    return FileCodec("test_zlib_9", encode, decode)


def test_worldpack_round_trip_selects_smallest_verified_codec_and_deduplicates(
    tmp_path: Path,
) -> None:
    source = tmp_path / "source"
    source.mkdir()
    repeated = b"descriptor-track-" * 4096
    (source / "a.bin").write_bytes(repeated)
    (source / "b.bin").write_bytes(repeated)
    (source / "random.bin").write_bytes(bytes(range(256)))
    archive = tmp_path / "capture.worldpack"
    manifest_sha = hashlib.sha256(b"frozen-manifest").hexdigest()
    writer = WorldPackWriter(
        archive,
        manifest_sha256=manifest_sha,
        scratch_root=tmp_path / "scratch",
        codecs=[_zlib_codec()],
    )
    result = writer.write(
        [
            MemberSpec("a.bin", source / "a.bin", ("test_zlib_9", "raw")),
            MemberSpec("b.bin", source / "b.bin", ("test_zlib_9", "raw")),
            MemberSpec("random.bin", source / "random.bin", ("raw",)),
        ]
    )

    assert archive.stat().st_size == result.complete_persisted_bytes
    assert result.entries[0].codec_id == "test_zlib_9"
    assert result.entries[1].codec_id == "reference"
    assert result.entries[1].dependency_index == 0
    assert result.entries[2].codec_id == "raw"

    reader = WorldPackReader(archive, codecs=[_zlib_codec()])
    assert reader.reconstructed_write_result() == result
    assert reader.manifest_sha256 == manifest_sha
    assert reader.paths == ("a.bin", "b.bin", "random.bin")
    assert reader.read_member("b.bin") == repeated
    restored = tmp_path / "restored"
    reader.extract_all(restored)
    for name in reader.paths:
        assert (restored / name).read_bytes() == (source / name).read_bytes()


def test_worldpack_random_read_is_bounded_to_one_independent_chunk(
    tmp_path: Path,
) -> None:
    source = tmp_path / "source"
    source.mkdir()
    specs: list[MemberSpec] = []
    for index in range(8):
        path = source / f"member-{index}.bin"
        path.write_bytes(bytes([index]) * (1024 + index))
        specs.append(MemberSpec(path.name, path, ("raw",)))
    archive = tmp_path / "random.worldpack"
    result = WorldPackWriter(
        archive,
        manifest_sha256="00" * 32,
        scratch_root=tmp_path / "scratch",
        codecs=[],
    ).write(specs)

    reader = WorldPackReader(archive, codecs=[])
    data, touched = reader.read_member_with_trace("member-5.bin")
    assert data == bytes([5]) * 1029
    assert touched == (5,)
    assert result.entries[5].payload_bytes == 1029


def test_worldpack_failed_candidate_never_publishes_archive(tmp_path: Path) -> None:
    source = tmp_path / "source.bin"
    source.write_bytes(b"must survive")

    def broken_encode(_: Path, destination: Path) -> None:
        destination.write_bytes(b"broken")

    def broken_decode(_: Path, destination: Path) -> None:
        destination.write_bytes(b"not the source")

    archive = tmp_path / "failed.worldpack"
    writer = WorldPackWriter(
        archive,
        manifest_sha256="11" * 32,
        scratch_root=tmp_path / "scratch",
        codecs=[FileCodec("broken", broken_encode, broken_decode)],
    )
    try:
        writer.write([MemberSpec("source.bin", source, ("broken",))])
    except ValueError as error:
        assert "exact" in str(error)
    else:
        raise AssertionError("non-exact codec was accepted")
    assert not archive.exists()
