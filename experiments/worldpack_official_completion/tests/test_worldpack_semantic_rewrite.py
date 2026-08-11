from __future__ import annotations

import hashlib
from pathlib import Path

from worldpack import MemberSpec, WorldPackReader, WorldPackWriter
from worldpack_semantic_rewrite import RawAddition, rewrite_drop_add_raw_members


def test_semantic_rewrite_drops_physical_member_and_reuses_all_other_payloads(
    tmp_path: Path,
) -> None:
    keep = tmp_path / "keep.bin"
    duplicate = tmp_path / "duplicate.bin"
    database = tmp_path / "database.db"
    keep.write_bytes(b"unchanged payload")
    duplicate.write_bytes(keep.read_bytes())
    database.write_bytes(b"physical sqlite pages")
    original = tmp_path / "original.worldpack"
    WorldPackWriter(
        original,
        manifest_sha256="11" * 32,
        scratch_root=tmp_path / "scratch",
        codecs=[],
    ).write(
        [
            MemberSpec("keep.bin", keep, ("raw",)),
            MemberSpec("database.db", database, ("raw",)),
            MemberSpec("duplicate.bin", duplicate, ("raw",)),
        ]
    )
    before = WorldPackReader(original, codecs=[])
    semantic_db = tmp_path / "database.pwa2.worldpack"
    semantic_manifest = tmp_path / "semantic-manifest.json"
    semantic_db.write_bytes(b"normalized logical database")
    semantic_manifest.write_bytes(b'{"schema":"semantic"}\n')
    manifest_sha = hashlib.sha256(semantic_manifest.read_bytes()).hexdigest()

    rewritten = tmp_path / "semantic.worldpack"
    result = rewrite_drop_add_raw_members(
        original,
        rewritten,
        codecs=[],
        manifest_sha256=manifest_sha,
        drop_paths={"database.db"},
        additions=(
            RawAddition("__semantic__/database.pwa2.worldpack", semantic_db),
            RawAddition("__semantic__/manifest.json", semantic_manifest),
        ),
    )
    after = WorldPackReader(rewritten, codecs=[])

    assert after.manifest_sha256 == manifest_sha
    assert after.paths == (
        "keep.bin",
        "duplicate.bin",
        "__semantic__/database.pwa2.worldpack",
        "__semantic__/manifest.json",
    )
    assert "database.db" not in after.paths
    assert after.entries[0].payload_sha256 == before.entries[0].payload_sha256
    assert after.entries[1].codec_id == "reference"
    assert after.entries[1].dependency_index == 0
    assert after.read_member("duplicate.bin") == keep.read_bytes()
    assert after.read_member("__semantic__/database.pwa2.worldpack") == (
        semantic_db.read_bytes()
    )
    assert after.read_member("__semantic__/manifest.json") == (
        semantic_manifest.read_bytes()
    )
    assert result.complete_persisted_bytes == rewritten.stat().st_size

