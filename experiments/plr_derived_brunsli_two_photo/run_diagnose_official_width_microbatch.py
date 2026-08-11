"""Run one preregistered effective batch through bounded MPS microbatches."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import random
import resource
import sys
import time

os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")

import torch
from torch.utils.data import DataLoader
import yaml

from pw_plr.exact_dataset import ExactJpegPatchDataset
from pw_plr.trainer import build_optimizers, train_accumulated_batch


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--corpus", type=Path, required=True)
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--upstream", type=Path, required=True)
    parser.add_argument("--extractor", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()

    config = yaml.safe_load(arguments.config.read_bytes())
    corpus = json.loads(arguments.corpus.read_bytes())
    batch_size = int(config["training"]["batch_size"])
    microbatch_size = int(config["training"]["microbatch_size"])
    seed = int(config["training"]["seed"])
    arm = next(
        arm for arm in config["model_arms"] if arm["id"] == "official_width"
    )
    training_images = [
        image for image in corpus["images"] if image["split"] == "train"
    ][:batch_size]
    if len(training_images) != batch_size:
        raise ValueError("diagnostic corpus does not contain one effective batch")
    if not torch.backends.mps.is_available():
        raise RuntimeError("registered MPS backend is unavailable")

    torch.manual_seed(seed)
    random.seed(seed)
    torch.use_deterministic_algorithms(True, warn_only=True)
    dataset = ExactJpegPatchDataset(
        training_images,
        extractor=arguments.extractor,
        seed=seed,
    )
    dataset.set_epoch(0)
    loader = DataLoader(
        dataset,
        batch_size=batch_size,
        shuffle=False,
        num_workers=int(config["training"]["data_loader_workers"]),
        prefetch_factor=int(config["training"]["prefetch_factor"]),
    )
    batch_started = time.monotonic()
    batch = next(iter(loader))
    extraction_seconds = time.monotonic() - batch_started

    sys.path.insert(0, str(arguments.upstream))
    from compressai.models.base_eff import EfficientJPEGRecompression

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
    train_started = time.monotonic()
    metrics = train_accumulated_batch(
        model,
        batch,
        main_optimizer,
        auxiliary_optimizer,
        microbatch_size=microbatch_size,
        gradient_clip_max_norm=float(
            config["training"]["gradient_clip_max_norm"]
        ),
    )
    torch.mps.synchronize()
    training_seconds = time.monotonic() - train_started
    peak_rss_bytes = int(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss)
    result = {
        "schema": "pw_plr_official_width_microbatch_diagnostic_v1",
        "diagnostic_only": True,
        "arm": "official_width",
        "model_n": int(arm["N"]),
        "model_m": int(arm["M"]),
        "effective_batch_size": batch_size,
        "execution_microbatch_size": microbatch_size,
        "microbatch_count": math.ceil(batch_size / microbatch_size),
        "corpus_sha256": _sha256(arguments.corpus),
        "config_sha256": _sha256(arguments.config),
        "extractor_sha256": _sha256(arguments.extractor),
        "upstream_commit": config["upstream"]["commit"],
        "device": "mps_with_cpu_erfc_fallback",
        "extraction_seconds": extraction_seconds,
        "training_seconds": training_seconds,
        "process_peak_rss_bytes": peak_rss_bytes,
        "mps_current_allocated_bytes": int(torch.mps.current_allocated_memory()),
        "mps_driver_allocated_bytes": int(torch.mps.driver_allocated_memory()),
        "loss_bits_per_pixel": metrics.loss_bits_per_pixel,
        "auxiliary_loss": metrics.auxiliary_loss,
        "gradient_norm": metrics.gradient_norm,
        "completed_effective_batch": True,
        "finite_metrics": all(
            math.isfinite(value)
            for value in (
                metrics.loss_bits_per_pixel,
                metrics.auxiliary_loss,
                metrics.gradient_norm,
            )
        ),
        "replacement_contract": (
            "same effective batch 64, model, corpus, seed, loss, optimizer and "
            "acceptance gates; execution split into bounded microbatches"
        ),
    }
    if not result["finite_metrics"]:
        raise FloatingPointError("microbatch diagnostic produced non-finite metrics")
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    temporary = arguments.output.with_suffix(arguments.output.suffix + ".tmp")
    temporary.write_text(
        json.dumps(result, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    os.replace(temporary, arguments.output)
    print(json.dumps(result, sort_keys=True), flush=True)


if __name__ == "__main__":
    main()
