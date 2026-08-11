#!/usr/bin/env python3
from __future__ import annotations

import json
from pathlib import Path

import mlflow


ROOT = Path(__file__).resolve().parent
RESULTS = ROOT / "results"
tracking_db = ROOT / "mlflow.db"
artifact_root = ROOT / "mlruns"
mlflow.set_tracking_uri(f"sqlite:///{tracking_db}")
experiment_name = "pocketworld-cross-photo-abc-exact-2026-08-02"
experiment = mlflow.get_experiment_by_name(experiment_name)
if experiment is None:
    experiment_id = mlflow.create_experiment(
        experiment_name,
        artifact_location=artifact_root.resolve().as_uri(),
    )
else:
    experiment_id = experiment.experiment_id

baseline = json.loads((RESULTS / "baseline.json").read_text(encoding="utf-8"))
arm_a = json.loads((RESULTS / "arm-a.json").read_text(encoding="utf-8"))
arm_b = json.loads((RESULTS / "arm-b.json").read_text(encoding="utf-8"))
c_audit = json.loads((ROOT / "arm-c-audit.json").read_text(encoding="utf-8"))

with mlflow.start_run(
    experiment_id=experiment_id,
    run_name="abc-complete-host-benchmark",
    tags={
        "production_modified": "false",
        "winner": "jxl_exact_baseline",
        "arm_c_status": c_audit["benchmark_status"],
    },
) as run:
    mlflow.log_params(
        {
            "source_jpeg_count": baseline["source_count"],
            "source_jpeg_bytes": baseline["source_jpeg_bytes"],
            "group_size": 8,
            "exactness_requirement": "byte-and-sha256",
            "backend": "zpaq-7.15-method-5",
            "future_minimum_complete_photos": 2,
        }
    )
    mlflow.log_metrics(
        {
            "baseline_complete_archive_bytes": baseline["complete_archive_bytes"],
            "arm_a_complete_archive_bytes": arm_a["complete_archive_bytes"],
            "arm_b_complete_archive_bytes": arm_b["complete_archive_bytes"],
            "arm_a_ratio": arm_a["ratio"],
            "arm_b_ratio": arm_b["ratio"],
            "arm_a_exactness_failures": arm_a["exactness_failures"],
            "arm_b_exactness_failures": arm_b["exactness_failures"],
        }
    )
    for artifact in (
        ROOT / "experiment-contract.yaml",
        ROOT / "input-manifest.yaml",
        ROOT / "arm-c-audit.json",
        ROOT / "evidence.json",
        RESULTS / "baseline.json",
        RESULTS / "arm-a.json",
        RESULTS / "arm-b.json",
        RESULTS / "summary.json",
    ):
        mlflow.log_artifact(artifact)
    print(run.info.run_id)
