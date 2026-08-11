from __future__ import annotations

import hashlib
from pathlib import Path
import zlib

from worldpack import FileCodec, MemberSpec, WorldPackReader, WorldPackWriter
from worldpack_verified_rewrite import PreverifiedPayloadEvidence, rewrite_member_payload


def _zlib_codec() -> FileCodec:
    def encode(source: Path, destination: Path) -> None:
        destination.write_bytes(zlib.compress(source.read_bytes(), level=9))

    def decode(source: Path, destination: Path) -> None:
        destination.write_bytes(zlib.decompress(source.read_bytes()))

    return FileCodec("test_zlib", encode, decode)


def test_rewrite_reuses_unrelated_payload_and_replaces_only_verified_member(
    tmp_path: Path,
) -> None:
    first = tmp_path / "first.bin"
    target = tmp_path / "target.bin"
    first.write_bytes(b"unchanged payload")
    target.write_bytes(b"target-" * 256)
    original = tmp_path / "original.worldpack"
    WorldPackWriter(
        original,
        manifest_sha256="11" * 32,
        scratch_root=tmp_path / "original-scratch",
        codecs=[],
    ).write(
        [
            MemberSpec("first.bin", first, ("raw",)),
            MemberSpec("target.bin", target, ("raw",)),
        ]
    )
    original_reader = WorldPackReader(original, codecs=[])
    original_first = original_reader.entries[0]
    replacement = tmp_path / "target.zlib"
    codec = _zlib_codec()
    codec.encode_file(target, replacement)

    rewritten = tmp_path / "rewritten.worldpack"
    result = rewrite_member_payload(
        original,
        rewritten,
        codecs=[codec],
        member_path="target.bin",
        expected_source_path=target,
        replacement_codec_id=codec.codec_id,
        replacement_payload=replacement,
    )
    reader = WorldPackReader(rewritten, codecs=[codec])

    assert reader.entries[0].payload_sha256 == original_first.payload_sha256
    assert reader.entries[0].payload_bytes == original_first.payload_bytes
    assert reader.entries[1].codec_id == "test_zlib"
    assert reader.entries[1].payload_bytes == replacement.stat().st_size
    assert result.complete_persisted_bytes == rewritten.stat().st_size
    assert reader.read_member("first.bin") == first.read_bytes()
    assert reader.read_member("target.bin") == target.read_bytes()


def test_rewrite_accepts_hash_bound_prior_exactness_without_decoding_again(
    tmp_path: Path,
) -> None:
    target = tmp_path / "target.bin"
    target.write_bytes(b"prior-evidence-" * 128)
    original = tmp_path / "original.worldpack"
    WorldPackWriter(
        original,
        manifest_sha256="22" * 32,
        scratch_root=tmp_path / "original-scratch",
        codecs=[],
    ).write([MemberSpec("target.bin", target, ("raw",))])
    replacement = tmp_path / "target.zlib"
    real_codec = _zlib_codec()
    real_codec.encode_file(target, replacement)
    decoder_called = False

    def forbidden_decode(source: Path, destination: Path) -> None:
        nonlocal decoder_called
        decoder_called = True
        raise AssertionError("prior exactness evidence should avoid duplicate decode")

    evidence_codec = FileCodec("test_zlib", lambda _s, _d: None, forbidden_decode)
    evidence = PreverifiedPayloadEvidence(
        payload_sha256=hashlib.sha256(replacement.read_bytes()).hexdigest(),
        source_bytes=target.stat().st_size,
        source_sha256=hashlib.sha256(target.read_bytes()).hexdigest(),
        byte_equal=True,
        sha256_equal=True,
        corruption_rejected=True,
    )

    rewritten = tmp_path / "rewritten.worldpack"
    rewrite_member_payload(
        original,
        rewritten,
        codecs=[evidence_codec],
        member_path="target.bin",
        expected_source_path=target,
        replacement_codec_id="test_zlib",
        replacement_payload=replacement,
        preverified=evidence,
    )

    assert decoder_called is False
    assert WorldPackReader(rewritten, codecs=[real_codec]).read_member(
        "target.bin"
    ) == target.read_bytes()
