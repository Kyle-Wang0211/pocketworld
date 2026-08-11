import json
from pathlib import Path

import mlflow


HERE = Path(__file__).resolve().parent
SHARED_PWA2 = HERE.parent / "pwa2_structure_zpaq"
SCREENING = HERE / "results" / "2026-08-02-real-member-screening.json"
FULL_NUMERIC = (
    HERE / "results" / "2026-08-02-pcodec-full-numeric-projection.json"
)
BASELINE_DECISION = HERE / "baseline-decision.json"


def main() -> None:
    screening = json.loads(SCREENING.read_text(encoding="utf-8"))
    full_numeric = json.loads(FULL_NUMERIC.read_text(encoding="utf-8"))
    baseline_decision = json.loads(BASELINE_DECISION.read_text(encoding="utf-8"))
    mlflow.set_tracking_uri(f"sqlite:///{SHARED_PWA2 / 'mlflow.db'}")
    mlflow.set_experiment("pwa2_official_codec_backends")
    with mlflow.start_run(run_name="2026-08-02-official-codec-host-rejection") as run:
        mlflow.log_params(
            {
                "input_sha256": (
                    "0c12c0dfa76d50cae59929774242282d8236daeb852bdee6ac99c3062d6d08b0"
                ),
                "input_bytes": 198983680,
                "openzl": "v0.2.0@3dceb64867840201fb8f57a29d179995f700c9b8",
                "pcodec": "v1.0.2@2d8555888b21bbaa19326580b740fa24b7da6bd3",
                "c_blosc2": "v3.3.0@7265419b23872707b1b52298d5f1469c9ea7b9e7",
                "pwa2_all_zpaq_bytes": 129567942,
                "production_baseline_bytes": 124401918,
                "maximum_accepted_bytes": 111961726,
                "repeat_count": 1,
                "evidence_role": "host-rejection-only",
            }
        )
        mlflow.log_metrics(
            {
                "screening_zpaq_bytes": screening["zpaq_bytes"],
                "screening_pcodec_bytes": screening["pcodec_bytes"],
                "screening_openzl_bytes": screening["openzl_bytes"],
                "screening_blosc2_best_bytes": min(
                    screening["blosc2_none_bytes"],
                    screening["blosc2_shuffle_bytes"],
                    screening["blosc2_bitshuffle_bytes"],
                ),
                "numeric_zpaq_bytes": full_numeric["numeric_zpaq_bytes"],
                "numeric_selected_bytes": full_numeric[
                    "numeric_selected_bytes"
                ],
                "numeric_delta_bytes": full_numeric["numeric_delta_bytes"],
                "projected_complete_persisted_bytes": full_numeric[
                    "projected_complete_persisted_bytes"
                ],
                "size_gate_pass": full_numeric["size_gate_pass"],
                "accepted_pwa2_baseline_bytes": baseline_decision[
                    "new_baseline"
                ]["bytes"],
            }
        )
        mlflow.set_tags(
            {
                "pwa2_baseline_status": baseline_decision["status"],
                "pwa2_baseline_bytes": str(
                    baseline_decision["new_baseline"]["bytes"]
                ),
                "production_promotion": str(
                    baseline_decision["production_promotion"]
                ).lower(),
            }
        )
        for artifact in (
            HERE / "experiment-contract.yaml",
            HERE / "input-manifest.yaml",
            SCREENING,
            FULL_NUMERIC,
            BASELINE_DECISION,
        ):
            mlflow.log_artifact(str(artifact))
        print(run.info.run_id)


if __name__ == "__main__":
    main()
