from __future__ import annotations

import hashlib
import json
import struct
from dataclasses import dataclass
from typing import Callable, Iterable


MAGIC = b"PWJGRP2\x00"
FOOTER_MAGIC = b"PWJEND2\x00"
VERSION = 1
HEADER = struct.Struct("<8sIIQQ")
FOOTER_BYTES = len(FOOTER_MAGIC) + 32


class JointGroupCorruption(RuntimeError):
    pass


@dataclass(frozen=True)
class GroupMember:
    index: int
    kind: str
    codec: str
    dependencies: tuple[int, ...]
    payload_offset: int
    payload_bytes: int
    original_bytes: int
    payload_sha256: str
    original_sha256: str


@dataclass(frozen=True)
class BuiltJointGroup:
    data: bytes
    members: tuple[GroupMember, ...]
    header_bytes: int
    index_bytes: int
    footer_bytes: int

    @property
    def complete_persisted_bytes(self) -> int:
        return len(self.data)


@dataclass(frozen=True)
class _PendingMember:
    kind: str
    codec: str
    dependencies: tuple[int, ...]
    original: bytes
    payload: bytes


class JointGroupBuilder:
    def __init__(self) -> None:
        self._members: list[_PendingMember] = []

    def add_member(
        self,
        kind: str,
        original: bytes,
        *,
        dependencies: Iterable[int],
        codec: str = "raw",
        encoded_payload: bytes | None = None,
    ) -> int:
        index = len(self._members)
        dependencies = tuple(int(value) for value in dependencies)
        if not kind or not codec:
            raise ValueError("member kind and codec are required")
        if len(set(dependencies)) != len(dependencies) or any(
            dependency < 0 or dependency >= index for dependency in dependencies
        ):
            raise ValueError("member dependencies must be unique and backward")
        payload = original if encoded_payload is None else encoded_payload
        if codec == "raw" and payload != original:
            raise ValueError("raw member payload must equal its original bytes")
        self._members.append(
            _PendingMember(
                kind=kind,
                codec=codec,
                dependencies=dependencies,
                original=bytes(original),
                payload=bytes(payload),
            )
        )
        return index

    def build(self) -> BuiltJointGroup:
        payload_offset = HEADER.size
        payloads = bytearray()
        index_members = []
        records = []
        for index, pending in enumerate(self._members):
            payload_sha256 = hashlib.sha256(pending.payload).hexdigest()
            original_sha256 = hashlib.sha256(pending.original).hexdigest()
            record = GroupMember(
                index=index,
                kind=pending.kind,
                codec=pending.codec,
                dependencies=pending.dependencies,
                payload_offset=payload_offset,
                payload_bytes=len(pending.payload),
                original_bytes=len(pending.original),
                payload_sha256=payload_sha256,
                original_sha256=original_sha256,
            )
            records.append(record)
            index_members.append(
                {
                    "codec": record.codec,
                    "dependencies": list(record.dependencies),
                    "index": record.index,
                    "kind": record.kind,
                    "original_bytes": record.original_bytes,
                    "original_sha256": record.original_sha256,
                    "payload_bytes": record.payload_bytes,
                    "payload_offset": record.payload_offset,
                    "payload_sha256": record.payload_sha256,
                }
            )
            payloads.extend(pending.payload)
            payload_offset += len(pending.payload)
        index = json.dumps(
            {"members": index_members, "schema": "pw_joint_group_index_v1"},
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")
        header = HEADER.pack(MAGIC, VERSION, len(records), payload_offset, len(index))
        footer = FOOTER_MAGIC + hashlib.sha256(index).digest()
        data = header + bytes(payloads) + index + footer
        return BuiltJointGroup(
            data=data,
            members=tuple(records),
            header_bytes=HEADER.size,
            index_bytes=len(index),
            footer_bytes=len(footer),
        )


class JointGroupReader:
    def __init__(
        self,
        data: bytes,
        *,
        decoders: dict[str, Callable[[bytes], bytes]] | None = None,
    ) -> None:
        self._data = bytes(data)
        self._decoders = {"raw": lambda value: value, **(decoders or {})}
        self._members = self._parse_and_validate_index()
        self._decoded: dict[int, bytes] = {}

    @property
    def members(self) -> tuple[GroupMember, ...]:
        return self._members

    def _parse_and_validate_index(self) -> tuple[GroupMember, ...]:
        if len(self._data) < HEADER.size + FOOTER_BYTES:
            raise JointGroupCorruption("joint group is truncated")
        magic, version, member_count, index_offset, index_bytes = HEADER.unpack_from(
            self._data
        )
        if magic != MAGIC or version != VERSION:
            raise JointGroupCorruption("joint group header mismatch")
        footer_offset = index_offset + index_bytes
        if (
            index_offset < HEADER.size
            or footer_offset + FOOTER_BYTES != len(self._data)
            or self._data[footer_offset : footer_offset + len(FOOTER_MAGIC)]
            != FOOTER_MAGIC
        ):
            raise JointGroupCorruption("joint group boundary mismatch")
        index_payload = self._data[index_offset:footer_offset]
        expected_index_hash = self._data[
            footer_offset + len(FOOTER_MAGIC) : footer_offset + FOOTER_BYTES
        ]
        if hashlib.sha256(index_payload).digest() != expected_index_hash:
            raise JointGroupCorruption("joint group index hash mismatch")
        try:
            parsed = json.loads(index_payload)
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise JointGroupCorruption("joint group index is invalid") from error
        if parsed.get("schema") != "pw_joint_group_index_v1":
            raise JointGroupCorruption("joint group index schema mismatch")
        raw_members = parsed.get("members")
        if not isinstance(raw_members, list) or len(raw_members) != member_count:
            raise JointGroupCorruption("joint group member count mismatch")

        expected_offset = HEADER.size
        records = []
        for expected_index, raw in enumerate(raw_members):
            try:
                dependencies = tuple(int(value) for value in raw["dependencies"])
                record = GroupMember(
                    index=int(raw["index"]),
                    kind=str(raw["kind"]),
                    codec=str(raw["codec"]),
                    dependencies=dependencies,
                    payload_offset=int(raw["payload_offset"]),
                    payload_bytes=int(raw["payload_bytes"]),
                    original_bytes=int(raw["original_bytes"]),
                    payload_sha256=str(raw["payload_sha256"]),
                    original_sha256=str(raw["original_sha256"]),
                )
            except (KeyError, TypeError, ValueError) as error:
                raise JointGroupCorruption("joint group member record is invalid") from error
            if (
                record.index != expected_index
                or not record.kind
                or record.codec not in self._decoders
                or record.payload_offset != expected_offset
                or record.payload_bytes < 0
                or record.original_bytes < 0
                or len(set(record.dependencies)) != len(record.dependencies)
                or any(
                    dependency < 0 or dependency >= record.index
                    for dependency in record.dependencies
                )
            ):
                raise JointGroupCorruption("joint group member contract failed")
            payload_end = record.payload_offset + record.payload_bytes
            if payload_end > index_offset:
                raise JointGroupCorruption("joint group payload exceeds index boundary")
            payload = self._data[record.payload_offset:payload_end]
            if hashlib.sha256(payload).hexdigest() != record.payload_sha256:
                raise JointGroupCorruption("joint group payload hash mismatch")
            expected_offset = payload_end
            records.append(record)
        if expected_offset != index_offset:
            raise JointGroupCorruption("joint group payload accounting mismatch")
        return tuple(records)

    def read_member(self, index: int) -> bytes:
        if index < 0 or index >= len(self._members):
            raise JointGroupCorruption("joint group member index is invalid")
        if index in self._decoded:
            return self._decoded[index]
        member = self._members[index]
        for dependency in member.dependencies:
            self.read_member(dependency)
        payload = self._data[
            member.payload_offset : member.payload_offset + member.payload_bytes
        ]
        try:
            original = self._decoders[member.codec](payload)
        except Exception as error:
            raise JointGroupCorruption("joint group member decode failed") from error
        if (
            len(original) != member.original_bytes
            or hashlib.sha256(original).hexdigest() != member.original_sha256
        ):
            raise JointGroupCorruption("joint group original hash mismatch")
        self._decoded[index] = original
        return original


def _rewrite_index(data: bytes, mutate: Callable[[dict], None]) -> bytes:
    magic, version, member_count, index_offset, index_bytes = HEADER.unpack_from(data)
    if magic != MAGIC or version != VERSION:
        raise ValueError("cannot rewrite an invalid test group")
    parsed = json.loads(data[index_offset : index_offset + index_bytes])
    mutate(parsed)
    replacement = json.dumps(
        parsed, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")
    header = HEADER.pack(MAGIC, VERSION, member_count, index_offset, len(replacement))
    return (
        header
        + data[HEADER.size:index_offset]
        + replacement
        + FOOTER_MAGIC
        + hashlib.sha256(replacement).digest()
    )


def corrupt_registered_field(data: bytes, field: str) -> bytes:
    damaged = bytearray(data)
    _, _, _, index_offset, index_bytes = HEADER.unpack_from(data)
    if field == "payload":
        damaged[HEADER.size] ^= 0x80
        return bytes(damaged)
    if field == "index":
        damaged[index_offset + index_bytes // 2] ^= 0x01
        return bytes(damaged)
    if field == "dependency":
        return _rewrite_index(
            data,
            lambda parsed: parsed["members"][1].__setitem__("dependencies", [1]),
        )
    if field == "hash":
        def mutate_hash(parsed: dict) -> None:
            current = parsed["members"][4]["payload_sha256"]
            parsed["members"][4]["payload_sha256"] = (
                ("0" if current[0] != "0" else "1") + current[1:]
            )

        return _rewrite_index(data, mutate_hash)
    raise ValueError(f"unknown corruption field: {field}")

