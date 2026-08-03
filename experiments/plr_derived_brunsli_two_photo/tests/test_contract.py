from pathlib import Path
import json

import yaml


ROOT = Path(__file__).resolve().parents[1]


def test_contract_freezes_all_decision_inputs() -> None:
    contract = yaml.safe_load((ROOT / "experiment-contract.yaml").read_text())

    assert contract["formal_project_photo_count"] == 96
    assert contract["formal_project_photo_count_evidence"] == {
        "capture_id": "analysis_cap_1779777762841797",
        "photos_highres_count": 96,
        "counting_rule": "regular_files_with_lowercase_jpg_extension",
    }
    assert contract["approved_scope_photo_count"] == {"min": 93, "max": 300}
    assert contract["baseline"]["state"] == "not_yet_measured"
    assert contract["model_accounting"]["storage_candidates"] == [
        "raw",
        "zstd-1.5.7-level-22",
        "zpaq-7.15-method-5",
    ]
    assert contract["brunsli"]["primary_commit"] == (
        "8a0e9b8ca2e3e089731c95a1da7ce8a3180e667c"
    )
    assert contract["brunsli"]["fallback_commit"] == (
        "c9128f43994c1ca830dd079777d85f16736d6ba7"
    )
    assert contract["run_control"] == {
        "host": "macos-apple-silicon",
        "phone": "forbidden",
        "production": "forbidden",
        "full_project": "forbidden_before_two_photo_win",
        "subagents": "forbidden_by_user",
    }


def test_manifest_freezes_the_ordered_pair() -> None:
    manifest = yaml.safe_load((ROOT / "input-manifest.yaml").read_text())

    assert [entry["role"] for entry in manifest["inputs"]] == ["A", "B"]
    assert [entry["filename"] for entry in manifest["inputs"]] == [
        "cell_85_slot_4.jpg",
        "cell_85_slot_5.jpg",
    ]
    assert [entry["bytes"] for entry in manifest["inputs"]] == [
        2_995_750,
        3_112_949,
    ]
    assert [entry["sha256"] for entry in manifest["inputs"]] == [
        "ac91faba107c41f891dbce7128f0ecc8e66cb451892e231479d8bf8b738e4be6",
        "73ec448d66a2242f5d8a07d3531d9018f604d3a67b219a5689901734fce83e4e",
    ]


def test_phase2_contract_uses_self_contained_inputs_and_capture_level_exclusion() -> None:
    contract = yaml.safe_load((ROOT / "experiment-contract.yaml").read_text())

    assert contract["phase2"]["input_manifest"] == "phase2-input-manifest.yaml"
    assert contract["phase2"]["training_exclusion_manifest"] == (
        "training-exclusion-manifest.json"
    )
    assert contract["phase2"]["training_exclusion_manifest_sha256"] == (
        "09cef816e7fcfd6b21dbf46aa23281800b67c07ff022e6d25eaa63623b6714c2"
    )
    assert contract["phase2"]["decoder_sequential_passes"]["registered"] == 22
    assert contract["phase2"]["decoder_sequential_passes"]["maximum"] == 24
    assert contract["phase2"]["decoder_sequential_passes"]["frequency_groups"] == [
        28,
        8,
        7,
        6,
        5,
        4,
        3,
        2,
        1,
    ]
    assert contract["phase2"]["decoder_sequential_passes"]["derivation"] == (
        "2_hyperprior_plus_2_cbcr_checkerboard_plus_9_y1_groups_plus_9_y234_groups"
    )
    assert contract["phase2"]["decoder_sequential_passes"]["violation"] == (
        "blocked_portability"
    )
    assert contract["phase2"]["terminal_backend"] == {
        "device": "cpu",
        "fixed_thread_count": 1,
        "encoder_decoder_processes": "separate",
        "integer_cdf_trace_must_match": True,
    }
    assert contract["phase_boundary"]["current"] == "phase_2_contract_frozen"
    assert contract["phase_boundary"]["training"] == (
        "authorized_after_phase_2_contract_validation_and_commit"
    )


def test_phase2_manifest_and_dvc_pointer_are_self_contained() -> None:
    manifest = yaml.safe_load((ROOT / "phase2-input-manifest.yaml").read_text())
    dvc_pointer = yaml.safe_load((ROOT / "data/frozen_pair.dvc").read_text())

    assert manifest["formal_project_photo_count"] == 96
    assert [entry["path"] for entry in manifest["inputs"]] == [
        "data/frozen_pair/cell_85_slot_4.jpg",
        "data/frozen_pair/cell_85_slot_5.jpg",
    ]
    assert manifest["training_exclusion"]["granularity"] == "capture"
    assert manifest["training_exclusion"]["excluded_capture_ids"] == [
        "analysis_cap_1779777762841797",
        "analysis_cap_1779777762841797_v2",
    ]
    assert dvc_pointer["outs"][0]["size"] == 6_108_699
    assert dvc_pointer["outs"][0]["nfiles"] == 2


def test_training_exclusion_manifest_covers_neighbors_and_duplicate_capture() -> None:
    exclusion = json.loads((ROOT / "training-exclusion-manifest.json").read_text())

    assert exclusion["canonical_photo_count"] == 96
    assert exclusion["excluded_capture_ids"] == [
        "analysis_cap_1779777762841797",
        "analysis_cap_1779777762841797_v2",
    ]
    assert len(exclusion["canonical_photos"]) == 96
    filenames = {photo["filename"] for photo in exclusion["canonical_photos"]}
    assert {
        "cell_85_slot_3.jpg",
        "cell_85_slot_4.jpg",
        "cell_85_slot_5.jpg",
        "cell_85_slot_6.jpg",
    } <= filenames
    assert exclusion["captures"][0]["ordered_content_manifest_sha256"] == (
        exclusion["captures"][1]["ordered_content_manifest_sha256"]
    )
