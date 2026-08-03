import hashlib
import json
import sqlite3
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]


def _contract():
    return yaml.safe_load((ROOT / "experiment-contract.yaml").read_text())


def test_contract_never_reruns_saved_complete_baseline():
    contract = _contract()
    assert contract["baseline"]["original_source_bytes"] == 638_645_632
    assert contract["baseline"]["complete_persisted_bytes"] == 471_146_040
    assert contract["baseline"]["execution"] == "forbidden_reference_only"
    assert contract["scope"] == "host_only_two_photo_joint_unit"
    assert contract["phone_access"] is False
    assert contract["production_changes"] is False


def test_contract_cannot_claim_faithful_2016_reproduction():
    contract = _contract()
    assert contract["implementation_identity"] == "pocketworld_independent_v2"
    assert contract["fidelity"]["faithful_2016_claim_allowed"] is False
    assert contract["fidelity"]["paper_31_percent_is_acceptance_target"] is False


def test_contract_registers_exactness_and_one_shot_expansion():
    contract = _contract()
    assert contract["acceptance"]["jpeg_byte_equal"] is True
    assert contract["acceptance"]["jpeg_sha256_equal"] is True
    assert contract["acceptance"]["all_semantic_bits_equal"] is True
    assert contract["acceptance"]["candidate_must_be_strictly_smaller"] is True
    assert contract["run_control"]["automatic_repeats"] == 0
    assert contract["run_control"]["automatic_scale_up"] == "forbidden"


def test_frozen_manifest_matches_capture_without_writing_it():
    manifest = yaml.safe_load((ROOT / "input-manifest.yaml").read_text())
    capture_root = Path(manifest["capture"]["root"])

    for entry in manifest["context_files"]:
        source = capture_root / entry["path"]
        assert source.stat().st_size == entry["bytes"]
        assert hashlib.sha256(source.read_bytes()).hexdigest() == entry["sha256"]

    archive = json.loads((capture_root / "official_photo_archive.json").read_text())
    for photo in manifest["photos"]:
        incumbent = capture_root / photo["incumbent_relative_path"]
        assert incumbent.stat().st_size == photo["incumbent_bytes"]
        assert hashlib.sha256(incumbent.read_bytes()).hexdigest() == photo["incumbent_sha256"]
        archived = archive["entries"][Path(photo["original_relative_path"]).name]
        assert archived["source_bytes"] == photo["original_bytes"]
        assert archived["source_sha256"] == photo["original_sha256"]

    pair_id = manifest["selection"]["colmap_pair_id"]
    database = capture_root / "official_sfm_live.db"
    with sqlite3.connect(f"file:{database}?mode=ro", uri=True) as connection:
        raw_rows = connection.execute(
            "SELECT rows FROM matches WHERE pair_id = ?", (pair_id,)
        ).fetchone()[0]
        verified_rows = connection.execute(
            "SELECT rows FROM two_view_geometries WHERE pair_id = ?", (pair_id,)
        ).fetchone()[0]
    assert raw_rows == manifest["selection"]["raw_match_rows"]
    assert verified_rows == manifest["selection"]["verified_two_view_rows"]
