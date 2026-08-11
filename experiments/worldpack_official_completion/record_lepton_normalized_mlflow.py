#!/usr/bin/env python3
"""Link the completed Lepton-normalized archive result to MLflow metadata."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path

import mlflow


ROOT = Path(__file__).resolve().parent
RESULT = ROOT / "results/worldpack-lepton-normalized-incumbent.json"
LOGICAL = ROOT / "results/worldpack-logical-photo-manifest-v2.json"
EVIDENCE = ROOT / "results/worldpack-lepton-normalized-incumbent-mlflow.json"
DATABASE = ROOT / "mlflow.db"


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while block := source.read(1024 * 1024):
            digest.update(block)
    return digest.hexdigest()


def main() -> None:
    if EVIDENCE.exists():
        raise FileExistsError("Lepton normalized MLflow evidence already exists")
    result = json.loads(RESULT.read_bytes())
    if result.get("schema") != "pw_worldpack_lepton_normalized_incumbent_v1":
        raise RuntimeError("Lepton normalized terminal result is absent")
    archive = Path(str(result["archive_path"]))
    if (
        archive.stat().st_size != int(result["complete_persisted_bytes"])
        or _sha256(archive) != result["archive_sha256"]
    ):
        raise RuntimeError("Lepton normalized archive identity changed")
    mlflow.set_tracking_uri(f"sqlite:///{DATABASE}")
    mlflow.set_experiment("worldpack-official-completion")
    with mlflow.start_run(run_name="lepton-normalized-full-semantic") as run:
        mlflow.log_params(
            {
                "schema": result["schema"],
                "scope": "complete_frozen_semantic_project",
                "lepton_revision": "90fdc27828676892fbb41777cfcc6bad1e470516",
                "archive_sha256": result["archive_sha256"],
                "logical_photo_identity_sha256": result[
                    "logical_photo_identity_sha256"
                ],
                "production_promoted": False,
                "phone_accessed": False,
            }
        )
        mlflow.log_metrics(
            {
                "complete_persisted_bytes": result["complete_persisted_bytes"],
                "predecessor_archive_bytes": result["predecessor_archive_bytes"],
                "improvement_bytes": result["improvement_bytes"],
                "candidate_roundtrip_exact": result["candidate_roundtrip_exact"],
                "selected_lepton_photo_count": result[
                    "selected_lepton_photo_count"
                ],
                "logical_original_jpegs_byte_equal": result[
                    "logical_original_jpegs_byte_equal"
                ],
                "corruption_rejected": result["corruption_rejected"],
            }
        )
        mlflow.log_artifact(str(RESULT), artifact_path="results")
        mlflow.log_artifact(str(LOGICAL), artifact_path="results")
        run_id = run.info.run_id
    evidence = {
        "schema": "pw_worldpack_lepton_normalized_mlflow_link_v1",
        "mlflow_run_id": run_id,
        "result_sha256": _sha256(RESULT),
        "logical_manifest_sha256": _sha256(LOGICAL),
        "archive_bytes": archive.stat().st_size,
        "archive_sha256": _sha256(archive),
    }
    temporary = EVIDENCE.with_suffix(EVIDENCE.suffix + ".tmp")
    temporary.write_text(json.dumps(evidence, indent=2, sort_keys=True) + "\n")
    os.replace(temporary, EVIDENCE)
    print(json.dumps(evidence, sort_keys=True), flush=True)


if __name__ == "__main__":
    main()
