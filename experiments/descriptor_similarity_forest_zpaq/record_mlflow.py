import json
from pathlib import Path

import mlflow


HERE = Path(__file__).resolve().parent
SHARED_PWA2 = HERE.parent / "pwa2_structure_zpaq"
RESULT = HERE / "results" / "2026-08-02-descriptor-similarity-forest-zpaq.json"


def main() -> None:
    result = json.loads(RESULT.read_text(encoding="utf-8"))
    arm_a = result["arm_a"]
    arm_b = result["arm_b"]
    mlflow.set_tracking_uri(f"sqlite:///{SHARED_PWA2 / 'mlflow.db'}")
    mlflow.set_experiment("descriptor_similarity_forest_zpaq")
    with mlflow.start_run(run_name="2026-08-02-full-coverage-clean-ab") as run:
        mlflow.log_params(
            {
                "input_sha256": result["source_sha256"],
                "input_bytes": result["source_bytes"],
                "zpaq_version": result["zpaq_version"],
                "zpaq_method": result["zpaq_method"],
                "faiss_version": result["faiss_version"],
                "faiss_seed": result["faiss_parameters"]["seed"],
                "faiss_nlist": result["faiss_parameters"]["nlist"],
                "faiss_nprobe": result["faiss_parameters"]["nprobe"],
                "block_descriptors": result["faiss_parameters"][
                    "block_descriptors"
                ],
                "repeat_count": 1,
                "evidence_role": "host-local-research-baseline-only",
            }
        )
        mlflow.log_metrics(
            {
                "arm_a_archive_bytes": arm_a["archive_bytes"],
                "arm_b_archive_bytes": arm_b["archive_bytes"],
                "b_minus_a_bytes": result["b_minus_a_bytes"],
                "b_minus_a_fraction": result["b_minus_a_fraction"],
                "arm_a_predicted_nodes": arm_a["predicted_descriptor_nodes"],
                "arm_b_predicted_nodes": arm_b["predicted_descriptor_nodes"],
                "arm_b_parent_sidecar_bytes": arm_b["parent_sidecar_bytes"],
                "arm_a_elapsed_ms": arm_a["elapsed_ms"],
                "arm_b_elapsed_ms": arm_b["elapsed_ms"],
                "arm_b_peak_rss_bytes": arm_b["peak_rss_bytes"],
                "exactness_pass": min(
                    arm_b["source_unchanged"],
                    arm_b["byte_equal"],
                    arm_b["sha256_equal"],
                    arm_b["sqlite_integrity_ok"],
                    arm_b["sidecar_equal"],
                    arm_b["forest_valid"],
                ),
            }
        )
        mlflow.set_tags(
            {
                "local_research_baseline": result["local_research_baseline"],
                "production_promoted": str(result["production_promoted"]).lower(),
                "comparison": "same-container-same-zpaq-clean-ab",
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

