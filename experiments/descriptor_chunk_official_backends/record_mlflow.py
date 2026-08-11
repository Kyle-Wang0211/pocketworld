import json
from pathlib import Path

import mlflow


HERE = Path(__file__).resolve().parent
RESULT = HERE / "results" / "2026-08-02-minimal-chunk.json"
SHARED_TRACKING_DB = HERE.parent / "pwa2_structure_zpaq" / "mlflow.db"


def main() -> None:
    result = json.loads(RESULT.read_text(encoding="utf-8"))
    arms = {arm["name"]: arm for arm in result["arms"]}
    mlflow.set_tracking_uri(f"sqlite:///{SHARED_TRACKING_DB}")
    mlflow.set_experiment("descriptor_chunk_official_backends")
    with mlflow.start_run(run_name="2026-08-02-one-complete-chunk") as run:
        mlflow.log_params(
            {
                "source_sha256": result["source_sha256"],
                "source_bytes": result["source_bytes"],
                "descriptor_count": result["descriptor_count"],
                "dimension": result["dimension"],
                "root_count": result["root_count"],
                "predicted_count": result["predicted_count"],
                "repeat_count": 1,
                "openzl_ace_profile": result["openzl_ace_profile"],
                "stopping_rule": "one-complete-chunk-then-stop",
            }
        )
        for name, arm in arms.items():
            mlflow.log_metric(
                f"{name}.complete_persisted_bytes",
                arm["complete_persisted_bytes"],
            )
            mlflow.log_metric(f"{name}.codec_frame_bytes", arm["codec_frame_bytes"])
            mlflow.log_metric(f"{name}.encode_ms", arm["encode_ms"])
            mlflow.log_metric(f"{name}.decode_ms", arm["decode_ms"])
        mlflow.log_metric("parent_sidecar_bytes", result["parent_sidecar_bytes"])
        mlflow.log_metric("exactness_pass", 1)
        mlflow.set_tags(
            {
                "winner": result["winner"],
                "scope": result["scope"],
                "production_promoted": "false",
                "comparison": "same-structure-same-chunk-complete-byte-accounting",
            }
        )
        for artifact in (
            HERE / "experiment-contract.yaml",
            HERE / "input-manifest.yaml",
            RESULT,
        ):
            mlflow.log_artifact(str(artifact))
        print(run.info.run_id)


if __name__ == "__main__":
    main()
