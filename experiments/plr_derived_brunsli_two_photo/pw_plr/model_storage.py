"""Self-contained accounting envelope for one compressed deployment model."""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import json
import re
import struct


MAGIC = b"PWMST1\0\0"
_CODEC_ID = re.compile(r"^[a-z0-9][a-z0-9_.-]{0,63}$")


@dataclass(frozen=True)
class DecodedModelStorage:
    codec_id: str
    model_bytes: int
    model_sha256: str
    encoded_payload: bytes


def _validate_codec(codec_id: str) -> str:
    if not _CODEC_ID.fullmatch(codec_id):
        raise ValueError("invalid model storage codec identity")
    return codec_id


def encode_model_storage(
    *,
    codec_id: str,
    model_artifact: bytes,
    encoded_payload: bytes,
) -> bytes:
    codec_id = _validate_codec(codec_id)
    manifest = json.dumps(
        {
            "schema": "pw_plr_model_storage_v1",
            "codec_id": codec_id,
            "model_bytes": len(model_artifact),
            "model_sha256": hashlib.sha256(model_artifact).hexdigest(),
            "payload_bytes": len(encoded_payload),
            "payload_sha256": hashlib.sha256(encoded_payload).hexdigest(),
        },
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    payload = struct.pack("<Q", len(manifest)) + manifest + encoded_payload
    return MAGIC + hashlib.sha256(payload).digest() + payload


def decode_model_storage(document: bytes) -> DecodedModelStorage:
    header_bytes = len(MAGIC) + 32
    if len(document) < header_bytes + 8 or not document.startswith(MAGIC):
        raise ValueError("invalid model storage envelope")
    expected_sha256 = document[len(MAGIC) : header_bytes]
    payload = document[header_bytes:]
    if hashlib.sha256(payload).digest() != expected_sha256:
        raise ValueError("model storage SHA-256 mismatch")
    manifest_bytes = struct.unpack_from("<Q", payload, 0)[0]
    if manifest_bytes > len(payload) - 8:
        raise ValueError("truncated model storage manifest")
    manifest_end = 8 + manifest_bytes
    try:
        manifest = json.loads(payload[8:manifest_end])
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ValueError("invalid model storage manifest") from error
    if manifest.get("schema") != "pw_plr_model_storage_v1":
        raise ValueError("unsupported model storage schema")
    codec_id = _validate_codec(str(manifest["codec_id"]))
    encoded_payload = payload[manifest_end:]
    if len(encoded_payload) != int(manifest["payload_bytes"]):
        raise ValueError("model storage payload byte count mismatch")
    if hashlib.sha256(encoded_payload).hexdigest() != str(
        manifest["payload_sha256"]
    ):
        raise ValueError("model storage payload SHA-256 mismatch")
    model_sha256 = str(manifest["model_sha256"])
    try:
        digest = bytes.fromhex(model_sha256)
    except ValueError as error:
        raise ValueError("invalid model artifact SHA-256") from error
    if len(digest) != 32 or int(manifest["model_bytes"]) < 0:
        raise ValueError("invalid model artifact identity")
    return DecodedModelStorage(
        codec_id=codec_id,
        model_bytes=int(manifest["model_bytes"]),
        model_sha256=model_sha256,
        encoded_payload=encoded_payload,
    )

