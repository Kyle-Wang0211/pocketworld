"""Canonical, checksummed storage for the exact deployment model state."""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import json
import struct
from typing import Mapping

import numpy as np
import torch


MAGIC = b"PWMOD1\0\0"


@dataclass(frozen=True)
class DecodedModelArtifact:
    identity: dict[str, object]
    state_dict: dict[str, torch.Tensor]


def encode_model_artifact(
    state_dict: Mapping[str, torch.Tensor],
    identity: Mapping[str, object],
) -> bytes:
    if not state_dict:
        raise ValueError("model artifact requires at least one tensor")
    tensor_payload = bytearray()
    entries: list[dict[str, object]] = []
    for name in sorted(state_dict):
        tensor = state_dict[name].detach().cpu().contiguous()
        if tensor.layout != torch.strided:
            raise ValueError(f"unsupported non-strided model tensor: {name}")
        try:
            numpy_value = tensor.numpy()
        except (TypeError, RuntimeError) as error:
            raise ValueError(f"unsupported model tensor dtype: {name}") from error
        raw = numpy_value.tobytes(order="C")
        entries.append(
            {
                "name": name,
                "dtype": numpy_value.dtype.str,
                "shape": list(tensor.shape),
                "offset": len(tensor_payload),
                "bytes": len(raw),
                "sha256": hashlib.sha256(raw).hexdigest(),
            }
        )
        tensor_payload.extend(raw)
    manifest = json.dumps(
        {
            "schema": "pw_plr_model_artifact_v1",
            "byte_order": "little",
            "identity": dict(identity),
            "tensors": entries,
        },
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    payload = struct.pack("<Q", len(manifest)) + manifest + bytes(tensor_payload)
    return MAGIC + hashlib.sha256(payload).digest() + payload


def decode_model_artifact(document: bytes) -> DecodedModelArtifact:
    header_bytes = len(MAGIC) + 32
    if len(document) < header_bytes + 8 or not document.startswith(MAGIC):
        raise ValueError("invalid model artifact envelope")
    expected_sha256 = document[len(MAGIC) : header_bytes]
    payload = document[header_bytes:]
    if hashlib.sha256(payload).digest() != expected_sha256:
        raise ValueError("model artifact SHA-256 mismatch")
    manifest_bytes = struct.unpack_from("<Q", payload, 0)[0]
    if manifest_bytes > len(payload) - 8:
        raise ValueError("truncated model artifact manifest")
    manifest_end = 8 + manifest_bytes
    try:
        manifest = json.loads(payload[8:manifest_end])
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ValueError("invalid model artifact manifest") from error
    if (
        manifest.get("schema") != "pw_plr_model_artifact_v1"
        or manifest.get("byte_order") != "little"
    ):
        raise ValueError("unsupported model artifact schema")
    tensor_payload = payload[manifest_end:]
    expected_offset = 0
    state_dict: dict[str, torch.Tensor] = {}
    for entry in manifest["tensors"]:
        name = str(entry["name"])
        offset = int(entry["offset"])
        byte_count = int(entry["bytes"])
        if name in state_dict or offset != expected_offset or byte_count < 0:
            raise ValueError("invalid model tensor ordering or range")
        end = offset + byte_count
        if end > len(tensor_payload):
            raise ValueError("truncated model tensor payload")
        raw = tensor_payload[offset:end]
        if hashlib.sha256(raw).hexdigest() != str(entry["sha256"]):
            raise ValueError(f"model tensor SHA-256 mismatch: {name}")
        try:
            dtype = np.dtype(str(entry["dtype"]))
            shape = tuple(int(value) for value in entry["shape"])
            numpy_value = np.frombuffer(raw, dtype=dtype).copy().reshape(shape)
            tensor = torch.from_numpy(numpy_value)
        except (TypeError, ValueError, RuntimeError) as error:
            raise ValueError(f"invalid model tensor metadata: {name}") from error
        state_dict[name] = tensor
        expected_offset = end
    if expected_offset != len(tensor_payload):
        raise ValueError("unexpected trailing model tensor bytes")
    identity = manifest["identity"]
    if not isinstance(identity, dict):
        raise ValueError("invalid model artifact identity")
    return DecodedModelArtifact(identity=identity, state_dict=state_dict)
