from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]


def test_contract_freezes_all_decision_inputs() -> None:
    contract = yaml.safe_load((ROOT / "experiment-contract.yaml").read_text())

    assert contract["formal_project_photo_count"] == 141
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
