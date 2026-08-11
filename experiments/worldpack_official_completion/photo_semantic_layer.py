"""Build the self-contained logical-original-JPEG layer manifest."""

from __future__ import annotations

from collections.abc import Mapping
from typing import Any


def _sha256(value: object, label: str) -> str:
    text = str(value)
    try:
        decoded = bytes.fromhex(text)
    except ValueError as error:
        raise ValueError(f"invalid {label} SHA-256") from error
    if len(decoded) != 32:
        raise ValueError(f"invalid {label} SHA-256")
    return text


def _positive_int(value: object, label: str) -> int:
    number = int(value)
    if number <= 0:
        raise ValueError(f"{label} must be positive")
    return number


def build_photo_layer_manifest(
    logical_document: Mapping[str, Any],
    *,
    learned_records: Mapping[str, Mapping[str, Any]] | None = None,
    shared_model: Mapping[str, Any] | None = None,
) -> dict[str, Any]:
    if logical_document.get("schema") not in {
        "pw_worldpack_logical_photo_manifest_v1",
        "pw_worldpack_logical_photo_manifest_v2",
    }:
        raise ValueError("unsupported logical photo manifest")
    raw_photos = list(logical_document.get("photos", ()))
    if len(raw_photos) != int(logical_document.get("logical_photo_count", -1)):
        raise ValueError("logical photo count mismatch")
    _sha256(logical_document.get("logical_photo_identity_sha256"), "identity")
    learned = dict(learned_records or {})
    if learned and shared_model is None:
        raise ValueError("learned photo layer requires one shared model")
    if not learned and shared_model is not None:
        raise ValueError("shared model cannot be stored without learned photos")

    photos_by_path: dict[str, Mapping[str, Any]] = {}
    for photo in raw_photos:
        logical_path = str(photo["logical_path"])
        if not logical_path or logical_path in photos_by_path:
            raise ValueError("duplicate or empty logical photo path")
        photos_by_path[logical_path] = photo
    unknown = set(learned) - set(photos_by_path)
    if unknown:
        raise ValueError(f"unknown logical photo: {min(unknown)}")

    model_document: dict[str, Any] | None = None
    if shared_model is not None:
        model_document = {
            "path": str(shared_model["path"]),
            "bytes": _positive_int(shared_model["bytes"], "model bytes"),
            "sha256": _sha256(shared_model["sha256"], "model"),
            "codec": str(shared_model["codec"]),
        }
        if not model_document["path"] or not model_document["codec"]:
            raise ValueError("invalid shared model identity")

    records: list[dict[str, Any]] = []
    for logical_path in sorted(photos_by_path, key=lambda value: value.encode()):
        source = photos_by_path[logical_path]
        base: dict[str, Any] = {
            "logical_path": logical_path,
            "logical_bytes": _positive_int(source["logical_bytes"], "JPEG bytes"),
            "logical_sha256": _sha256(source["logical_sha256"], "JPEG"),
        }
        learned_record = learned.get(logical_path)
        if learned_record is None:
            base.update(
                {
                    "storage_kind": "incumbent_exact_jpeg",
                    "storage_members": [
                        {
                            "path": str(source["storage_path"]),
                            "codec": str(source["storage_codec"]),
                            "bytes": _positive_int(
                                source["storage_bytes"], "incumbent photo bytes"
                            ),
                            "sha256": _sha256(
                                source["storage_sha256"], "incumbent photo"
                            ),
                        }
                    ],
                }
            )
        else:
            base.update(
                {
                    "storage_kind": "plr_derived_exact_jpeg",
                    "storage_members": [
                        {
                            "path": str(learned_record["photo_archive_path"]),
                            "codec": "plr_derived_photo_stream_v1",
                            "bytes": _positive_int(
                                learned_record["photo_archive_bytes"],
                                "learned photo bytes",
                            ),
                            "sha256": _sha256(
                                learned_record["photo_archive_sha256"],
                                "learned photo",
                            ),
                        },
                        {
                            "path": str(learned_record["side_path"]),
                            "codec": "brunsli_v0_1_exact_side_v1",
                            "bytes": _positive_int(
                                learned_record["side_bytes"], "exact side bytes"
                            ),
                            "sha256": _sha256(
                                learned_record["side_sha256"], "exact side"
                            ),
                        },
                    ],
                }
            )
        if any(not member["path"] for member in base["storage_members"]):
            raise ValueError("empty photo storage member path")
        records.append(base)

    return {
        "schema": "pw_semantic_photo_layer_v1",
        "original_jpeg_byte_recovery_required": True,
        "logical_photo_count": len(records),
        "logical_photo_identity_sha256": logical_document[
            "logical_photo_identity_sha256"
        ],
        "learned_photo_count": len(learned),
        "retained_incumbent_photo_count": len(records) - len(learned),
        "shared_model": model_document,
        "photos": records,
    }
