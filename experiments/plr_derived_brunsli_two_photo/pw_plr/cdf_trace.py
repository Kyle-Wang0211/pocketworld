from __future__ import annotations

import hashlib
import json
from typing import Any, Iterable

import torch


def _tensor_record(tensor: torch.Tensor | None) -> dict[str, Any] | None:
    if tensor is None:
        return None
    value = tensor.detach().cpu().contiguous()
    payload = value.numpy().tobytes(order="C")
    return {
        "dtype": str(value.dtype),
        "shape": list(value.shape),
        "sha256": hashlib.sha256(payload).hexdigest(),
    }


def _entropy_table_record(module: Any) -> dict[str, Any]:
    return {
        "quantized_cdf": _tensor_record(module._quantized_cdf),
        "cdf_length": _tensor_record(module._cdf_length),
        "offset": _tensor_record(module._offset),
    }


def _luma_gaussian_stages(model: Any) -> Iterable[tuple[str, Any]]:
    for index, module in enumerate(model.Gaussion_Ys):
        yield f"y1_frequency_{index}", module
    for index, module in enumerate(model.Gaussion_Ys_234):
        yield f"y234_frequency_{index}", module


def collect_model_decision_trace(model: Any) -> dict[str, Any]:
    """Hash all integer decisions used by the codec's 22 entropy stages."""

    stages: list[dict[str, Any]] = []

    def add_entropy_bottleneck(name: str, entropy_bottleneck: Any) -> None:
        stages.append(
            {
                "name": name,
                "kind": "entropy_bottleneck",
                "entropy_tables": _entropy_table_record(entropy_bottleneck),
            }
        )

    def add_gaussian(name: str, codec: Any) -> None:
        decision = codec.last_decision_tensors
        if decision is None:
            raise RuntimeError(f"entropy stage {name} has not produced a decision")
        indexes, means = decision
        stages.append(
            {
                "name": name,
                "kind": "gaussian_conditional",
                "indexes": _tensor_record(indexes),
                "means": _tensor_record(means),
                "entropy_tables": _entropy_table_record(
                    codec.gaussian_conditional
                ),
            }
        )

    # Preserve the actual arithmetic stream order used by base_eff.compress.
    add_entropy_bottleneck("hyper_cbcr", model.hyper_cbcr.entropy_bottleneck)
    add_gaussian("cbcr_anchor", model.Guassian_cbcr_anchor)
    add_gaussian("cbcr_non_anchor", model.Guassian_cbcr_non_anchor)
    add_entropy_bottleneck("hyper_y", model.hyper_Y.entropy_bottleneck)
    for name, codec in _luma_gaussian_stages(model):
        add_gaussian(name, codec)

    serialized = json.dumps(
        stages, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")
    return {
        "schema": "pw_plr_model_decision_trace_v1",
        "stage_count": len(stages),
        "trace_sha256": hashlib.sha256(serialized).hexdigest(),
        "stages": stages,
    }
