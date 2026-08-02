from __future__ import annotations

import hashlib
import json
from pathlib import Path

import yaml


EXPERIMENT_ROOT = Path(__file__).resolve().parents[1]


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def test_contract_and_manifest_match_the_frozen_capture() -> None:
    contract = yaml.safe_load(
        (EXPERIMENT_ROOT / "experiment-contract.yaml").read_text()
    )
    manifest = json.loads((EXPERIMENT_ROOT / "input-manifest.yaml").read_text())

    capture_root = Path(contract["input"]["capture_root"])
    entries = manifest["entries"]
    assert capture_root.is_dir()
    assert manifest["capture_id"] == contract["input"]["capture_id"]
    assert manifest["ordering"] == "normalized_relative_path_utf8"
    assert manifest["entry_count"] == len(entries)
    assert entries == sorted(entries, key=lambda entry: entry["path"].encode("utf-8"))

    actual_paths = sorted(
        (path.relative_to(capture_root).as_posix() for path in capture_root.rglob("*") if path.is_file()),
        key=lambda value: value.encode("utf-8"),
    )
    assert [entry["path"] for entry in entries] == actual_paths
    assert manifest["source_bytes"] == sum(entry["bytes"] for entry in entries)

    by_path = {entry["path"]: entry for entry in entries}
    for key in ("sqlite", "sparse_ply"):
        frozen = contract["input"][key]
        entry = by_path[frozen["path"]]
        assert entry["bytes"] == frozen["bytes"]
        assert entry["sha256"] == frozen["sha256"]
        assert _sha256(capture_root / frozen["path"]) == frozen["sha256"]


def test_contract_forbids_product_and_phone_mutation() -> None:
    contract = yaml.safe_load(
        (EXPERIMENT_ROOT / "experiment-contract.yaml").read_text()
    )
    acceptance = contract["acceptance"]
    assert acceptance["production_changes"] == "forbidden"
    assert acceptance["phone_access"] == "forbidden"
    assert contract["configuration"]["run_each_registered_arm_once"] is True
    assert contract["configuration"]["repeat_count"] == 1

