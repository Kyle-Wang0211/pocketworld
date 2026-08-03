import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def test_method_map_names_every_required_stage():
    text = (ROOT / "method-map.md").read_text(encoding="utf-8")
    for stage in (
        "feature-domain prediction structure",
        "global disparity compensation",
        "local disparity compensation",
        "frequency-domain adaptive prediction",
        "context-adaptive entropy coding",
        "exact JPEG binary reconstruction",
    ):
        assert stage in text


def test_every_stage_has_a_terminal_fidelity_status():
    evidence = json.loads((ROOT / "evidence.json").read_text(encoding="utf-8"))
    allowed = {
        "faithful",
        "faithful_with_declared_substitution",
        "blocked_missing_detail",
    }
    assert set(evidence["method_stages"]) == {
        "feature_prediction",
        "global_compensation",
        "local_compensation",
        "frequency_prediction",
        "entropy_coding",
        "jpeg_binary_reconstruction",
    }
    assert all(
        stage["status"] in allowed
        for stage in evidence["method_stages"].values()
    )


def test_blocked_stage_forbids_faithful_benchmark_claim():
    evidence = json.loads((ROOT / "evidence.json").read_text(encoding="utf-8"))
    blocked = [
        name
        for name, stage in evidence["method_stages"].items()
        if stage["status"] == "blocked_missing_detail"
    ]
    assert evidence["faithful_2016_reproduction_allowed"] is (not blocked)

