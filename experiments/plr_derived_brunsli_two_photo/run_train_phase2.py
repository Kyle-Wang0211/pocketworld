"""Train one preregistered PLR-derived model arm with resumable evidence."""

from __future__ import annotations

import argparse
from collections import defaultdict
import hashlib
import json
import math
import os
from pathlib import Path
import random
import subprocess
import sys
import time

os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")

import mlflow
import torch
from torch.optim.lr_scheduler import ReduceLROnPlateau
from torch.utils.data import DataLoader
import yaml

from pw_plr.exact_dataset import ExactJpegPatchDataset
from pw_plr.trainer import (
    build_optimizers,
    equal_tile_batches,
    train_batch,
    validation_patch_bits,
)
from pw_plr.training_metrics import (
    accounted_validation_bytes,
    raw_state_dict_bytes,
)


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _verify_runtime_identity(
    config: dict[str, object],
    *,
    config_path: Path,
    upstream: Path,
    extractor: Path,
) -> None:
    root = config_path.resolve().parent
    input_config = config["input"]
    training_config = config["training"]
    upstream_config = config["upstream"]
    if _sha256(extractor) != input_config["extractor"]["sha256"]:
        raise ValueError("extractor identity mismatch")
    lock_path = root / "uv.lock"
    if _sha256(lock_path) != training_config["environment"]["uv_lock_sha256"]:
        raise ValueError("uv.lock identity mismatch")
    for field, filename in (
        ("lazy_import_patch_sha256", "plr-lazy-import.patch"),
        ("exact_completion_patch_sha256", "plr-exact-22-stage.patch"),
    ):
        patch_path = root / "patches" / filename
        if _sha256(patch_path) != upstream_config[field]:
            raise ValueError(f"PLR patch identity mismatch: {filename}")
        reverse_check = subprocess.run(
            [
                "git",
                "-C",
                str(upstream),
                "apply",
                "--reverse",
                "--check",
                str(patch_path),
            ],
            capture_output=True,
            check=False,
            text=True,
        )
        if reverse_check.returncode != 0:
            raise ValueError(f"registered PLR patch is not applied: {filename}")
    revision = subprocess.run(
        ["git", "-C", str(upstream), "rev-parse", "HEAD"],
        capture_output=True,
        check=True,
        text=True,
    ).stdout.strip()
    if revision != upstream_config["commit"]:
        raise ValueError("PLR upstream revision mismatch")


def _atomic_torch_save(document: dict[str, object], path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.unlink(missing_ok=True)
    torch.save(document, temporary)
    os.replace(temporary, path)


def _append_metric(path: Path, metric: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as output:
        output.write(json.dumps(metric, sort_keys=True) + "\n")
        output.flush()
        os.fsync(output.fileno())


def _tile_count(image: dict[str, object], luma_blocks: int = 32) -> int:
    return math.ceil(int(image["luma_width_in_blocks"]) / luma_blocks) * math.ceil(
        int(image["luma_height_in_blocks"]) / luma_blocks
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--corpus", type=Path, required=True)
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--arm", required=True)
    parser.add_argument("--upstream", type=Path, required=True)
    parser.add_argument("--extractor", type=Path, required=True)
    parser.add_argument("--output-directory", type=Path, required=True)
    parser.add_argument("--mlflow-database", type=Path, required=True)
    arguments = parser.parse_args()

    config_bytes = arguments.config.read_bytes()
    corpus_bytes = arguments.corpus.read_bytes()
    config = yaml.safe_load(config_bytes)
    corpus = json.loads(corpus_bytes)
    if config["schema"] != "pw_plr_phase2_model_config_v1":
        raise ValueError("unsupported Phase 2 model config")
    if corpus["schema"] != "pw_plr_combined_exact_jpeg_corpus_v1":
        raise ValueError("unsupported combined corpus manifest")
    _verify_runtime_identity(
        config,
        config_path=arguments.config,
        upstream=arguments.upstream,
        extractor=arguments.extractor,
    )
    arms = {str(arm["id"]): arm for arm in config["model_arms"]}
    if arguments.arm not in arms:
        raise ValueError(f"unregistered model arm: {arguments.arm}")
    arm = arms[arguments.arm]
    if not torch.backends.mps.is_available():
        raise RuntimeError("registered MPS training backend is unavailable")

    sys.path.insert(0, str(arguments.upstream))
    from compressai.models.base_eff import EfficientJPEGRecompression

    seed = int(config["training"]["seed"])
    torch.manual_seed(seed)
    random.seed(seed)
    torch.use_deterministic_algorithms(True, warn_only=True)
    images = [
        {**image, "full_photo_tile_count": _tile_count(image)}
        for image in corpus["images"]
    ]
    training_images = [image for image in images if image["split"] == "train"]
    validation_images = [
        image for image in images if image["split"] == "validation"
    ]
    training_dataset = ExactJpegPatchDataset(
        training_images,
        extractor=arguments.extractor,
        seed=seed,
    )
    validation_dataset = ExactJpegPatchDataset(
        validation_images,
        extractor=arguments.extractor,
        seed=seed,
    )
    validation_dataset.set_epoch(
        int(config["selection"]["entropy_estimator"]["validation_patch_epoch"])
    )
    batch_size = int(config["training"]["batch_size"])
    workers = int(config["training"]["data_loader_workers"])
    prefetch = int(config["training"]["prefetch_factor"])
    validation_batches = equal_tile_batches(
        validation_images,
        batch_size=batch_size,
    )

    device = torch.device("mps")
    model = EfficientJPEGRecompression(
        N=int(arm["N"]),
        M=int(arm["M"]),
        chunk=tuple(config["implementation"]["chunks"]),
    ).to(device)
    main_optimizer, auxiliary_optimizer = build_optimizers(
        model,
        main_learning_rate=float(config["training"]["main_learning_rate"]),
        auxiliary_learning_rate=float(
            config["training"]["auxiliary_learning_rate"]
        ),
    )
    scheduler_config = config["training"]["scheduler"]
    if scheduler_config["name"] != "ReduceLROnPlateau":
        raise ValueError("unsupported registered training scheduler")
    scheduler = ReduceLROnPlateau(
        main_optimizer,
        mode=str(scheduler_config["mode"]),
        factor=float(scheduler_config["factor"]),
        patience=int(scheduler_config["patience"]),
    )
    model_bytes = raw_state_dict_bytes(model)

    run_directory = arguments.output_directory / arguments.arm
    latest_path = run_directory / "latest.pt"
    best_path = run_directory / "best.pt"
    metrics_path = run_directory / "epochs.jsonl"
    start_epoch = 0
    best_validation = math.inf
    existing_run_id: str | None = None
    if latest_path.is_file():
        checkpoint = torch.load(latest_path, map_location=device)
        if checkpoint["config_sha256"] != hashlib.sha256(config_bytes).hexdigest():
            raise ValueError("resume config identity mismatch")
        if checkpoint["corpus_sha256"] != hashlib.sha256(corpus_bytes).hexdigest():
            raise ValueError("resume corpus identity mismatch")
        model.load_state_dict(checkpoint["model"])
        main_optimizer.load_state_dict(checkpoint["main_optimizer"])
        auxiliary_optimizer.load_state_dict(checkpoint["auxiliary_optimizer"])
        scheduler.load_state_dict(checkpoint["scheduler"])
        start_epoch = int(checkpoint["epoch"]) + 1
        best_validation = float(checkpoint["best_validation_accounted_bytes"])
        existing_run_id = str(checkpoint["mlflow_run_id"])

    arguments.mlflow_database.parent.mkdir(parents=True, exist_ok=True)
    mlflow.set_tracking_uri(
        "sqlite:///" + str(arguments.mlflow_database.resolve())
    )
    mlflow.set_experiment("pw-plr-derived-completion-phase2")
    with mlflow.start_run(run_id=existing_run_id) as active_run:
        if existing_run_id is None:
            mlflow.log_params(
                {
                    "arm": arguments.arm,
                    "N": int(arm["N"]),
                    "M": int(arm["M"]),
                    "seed": seed,
                    "epochs": int(config["training"]["epochs"]),
                    "batch_size": batch_size,
                    "scheduler": scheduler_config["name"],
                    "scheduler_mode": scheduler_config["mode"],
                    "scheduler_factor": float(scheduler_config["factor"]),
                    "scheduler_patience": int(scheduler_config["patience"]),
                    "corpus_sha256": hashlib.sha256(corpus_bytes).hexdigest(),
                    "config_sha256": hashlib.sha256(config_bytes).hexdigest(),
                    "upstream_commit": config["upstream"]["commit"],
                    "raw_model_tensor_bytes": model_bytes.complete_tensor_bytes,
                }
            )
        for epoch in range(start_epoch, int(config["training"]["epochs"])):
            epoch_started = time.monotonic()
            training_dataset.set_epoch(epoch)
            generator = torch.Generator().manual_seed(seed + epoch)
            training_loader = DataLoader(
                training_dataset,
                batch_size=batch_size,
                shuffle=True,
                generator=generator,
                num_workers=workers,
                prefetch_factor=prefetch,
            )
            train_samples = 0
            train_loss_sum = 0.0
            auxiliary_loss_sum = 0.0
            gradient_norm_max = 0.0
            for batch in training_loader:
                metrics = train_batch(
                    model,
                    batch,
                    main_optimizer,
                    auxiliary_optimizer,
                    gradient_clip_max_norm=float(
                        config["training"]["gradient_clip_max_norm"]
                    ),
                )
                count = int(batch["Y"].shape[0])
                train_samples += count
                train_loss_sum += metrics.loss_bits_per_pixel * count
                auxiliary_loss_sum += metrics.auxiliary_loss * count
                gradient_norm_max = max(
                    gradient_norm_max,
                    metrics.gradient_norm,
                )

            validation_loader = DataLoader(
                validation_dataset,
                batch_sampler=validation_batches,
                num_workers=workers,
                prefetch_factor=prefetch,
            )
            validation_groups: dict[int, dict[str, int | float]] = defaultdict(
                lambda: {
                    "photo_count": 0,
                    "tile_count": 0,
                    "total_patch_bits": 0.0,
                }
            )
            for batch in validation_loader:
                tile_counts = {int(value) for value in batch["full_photo_tile_count"]}
                if len(tile_counts) != 1:
                    raise AssertionError("validation batch mixed tile counts")
                tile_count = tile_counts.pop()
                group = validation_groups[tile_count]
                group["tile_count"] = tile_count
                group["photo_count"] = int(group["photo_count"]) + int(
                    batch["Y"].shape[0]
                )
                group["total_patch_bits"] = float(
                    group["total_patch_bits"]
                ) + validation_patch_bits(model, batch)
            accounting = accounted_validation_bytes(
                groups=validation_groups.values(),
                raw_model_bytes=model_bytes.complete_tensor_bytes,
                scope_photo_count=96,
            )
            scheduler.step(accounting.total_accounted_bytes)
            metric = {
                "epoch": epoch,
                "arm": arguments.arm,
                "train_photo_count": train_samples,
                "train_loss_bits_per_pixel": train_loss_sum / train_samples,
                "auxiliary_loss": auxiliary_loss_sum / train_samples,
                "gradient_norm_max": gradient_norm_max,
                "validation_photo_count": accounting.photo_count,
                "validation_estimated_entropy_bytes": (
                    accounting.estimated_entropy_bytes
                ),
                "validation_accounted_model_bytes": accounting.accounted_model_bytes,
                "validation_total_accounted_bytes": accounting.total_accounted_bytes,
                "raw_model_tensor_bytes": model_bytes.complete_tensor_bytes,
                "learning_rate": main_optimizer.param_groups[0]["lr"],
                "elapsed_seconds": time.monotonic() - epoch_started,
            }
            improved = accounting.total_accounted_bytes < best_validation
            if improved:
                best_validation = accounting.total_accounted_bytes
            checkpoint = {
                "schema": "pw_plr_phase2_checkpoint_v1",
                "arm": arguments.arm,
                "epoch": epoch,
                "model": model.state_dict(),
                "main_optimizer": main_optimizer.state_dict(),
                "auxiliary_optimizer": auxiliary_optimizer.state_dict(),
                "scheduler": scheduler.state_dict(),
                "best_validation_accounted_bytes": best_validation,
                "metric": metric,
                "config_sha256": hashlib.sha256(config_bytes).hexdigest(),
                "corpus_sha256": hashlib.sha256(corpus_bytes).hexdigest(),
                "mlflow_run_id": active_run.info.run_id,
            }
            _atomic_torch_save(checkpoint, latest_path)
            if improved:
                _atomic_torch_save(checkpoint, best_path)
            _append_metric(metrics_path, metric)
            mlflow.log_metrics(
                {
                    key: float(value)
                    for key, value in metric.items()
                    if key not in {"epoch", "arm"}
                },
                step=epoch,
            )
            print(json.dumps(metric, sort_keys=True), flush=True)


if __name__ == "__main__":
    main()
