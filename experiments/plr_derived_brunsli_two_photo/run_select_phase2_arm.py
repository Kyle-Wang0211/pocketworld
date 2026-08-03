"""Select the sole terminal model arm from frozen validation evidence."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path

import torch
import yaml

from pw_plr.model_selection import select_registered_arm


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--runs-directory", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()
    config_bytes = arguments.config.read_bytes()
    config = yaml.safe_load(config_bytes)
    arm_ids = {str(arm["id"]) for arm in config["model_arms"]}
    candidates: dict[str, dict[str, object]] = {}
    evidence: dict[str, dict[str, object]] = {}
    for arm_id in sorted(arm_ids):
        arm_directory = arguments.runs_directory / arm_id
        best_path = arm_directory / "best.pt"
        metrics_path = arm_directory / "epochs.jsonl"
        checkpoint = torch.load(best_path, map_location="cpu")
        metrics = [
            json.loads(line)
            for line in metrics_path.read_text().splitlines()
            if line.strip()
        ]
        best_metric = min(
            metrics,
            key=lambda item: (
                int(item["validation_total_accounted_bytes"]),
                int(item["epoch"]),
            ),
        )
        if checkpoint["arm"] != arm_id or checkpoint["metric"] != best_metric:
            raise ValueError(f"best checkpoint/metric mismatch for {arm_id}")
        checkpoint_sha256 = hashlib.sha256(best_path.read_bytes()).hexdigest()
        candidate = {
            "validation_total_accounted_bytes": int(
                best_metric["validation_total_accounted_bytes"]
            ),
            "raw_model_tensor_bytes": int(best_metric["raw_model_tensor_bytes"]),
            "checkpoint_sha256": checkpoint_sha256,
        }
        candidates[arm_id] = candidate
        evidence[arm_id] = {
            **candidate,
            "best_epoch": int(best_metric["epoch"]),
            "best_checkpoint": str(best_path),
            "epoch_count": len(metrics),
            "metrics_sha256": hashlib.sha256(metrics_path.read_bytes()).hexdigest(),
        }
    selected = select_registered_arm(
        candidates,
        registered_arm_ids=arm_ids,
    )
    result = {
        "schema": "pw_plr_phase2_selected_arm_v1",
        "selection_split": "validation",
        "uses_frozen_pair": False,
        "config_sha256": hashlib.sha256(config_bytes).hexdigest(),
        "candidates": evidence,
        "selected_arm": selected.arm_id,
        "selected_validation_total_accounted_bytes": (
            selected.validation_total_accounted_bytes
        ),
        "selected_checkpoint_sha256": selected.checkpoint_sha256,
        "terminal_arm_count": 1,
    }
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    temporary = arguments.output.with_suffix(arguments.output.suffix + ".tmp")
    temporary.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    os.replace(temporary, arguments.output)


if __name__ == "__main__":
    main()
