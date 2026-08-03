from pathlib import Path

from pw_plr.brunsli_phase1 import run_phase1


ROOT = Path(__file__).resolve().parents[1]


def test_run_phase1_restores_both_frozen_inputs_and_records_evidence(
    tmp_path: Path,
) -> None:
    result = run_phase1(
        manifest_path=ROOT / "input-manifest.yaml",
        adapter_path=ROOT / "build" / "v0.1" / "pw_brunsli_side_adapter",
        revision="v0.1",
        work_directory=tmp_path,
    )

    assert result["schema"] == "pw_plr_brunsli_phase1_v1"
    assert result["status"] == "phase_1_exact_container_passed"
    assert result["brunsli_commit"] == (
        "8a0e9b8ca2e3e089731c95a1da7ce8a3180e667c"
    )
    assert [item["role"] for item in result["inputs"]] == ["A", "B"]
    assert [item["source_bytes"] for item in result["inputs"]] == [
        2_995_750,
        3_112_949,
    ]
    assert all(item["byte_equal"] for item in result["inputs"])
    assert all(item["sha256_equal"] for item in result["inputs"])
    assert all(item["source_unchanged"] for item in result["inputs"])
    assert all(item["side_bytes"] > 88 for item in result["inputs"])
    assert all(item["coefficient_bytes"] > 88 for item in result["inputs"])
    assert all(
        item["side_section_tags"] == [1, 2, 4, 3, 5]
        for item in result["inputs"]
    )
    assert all(
        all(item["corruption_rejected"].values())
        for item in result["inputs"]
    )
