from __future__ import annotations

from webgraph_llp_verify import (
    decode_direct_mapping,
    decode_permutation_delta,
    encode_direct_mapping_v2,
    encode_permutation_delta,
    parse_canonical_records,
    restore_canonical_from_permuted_arcs,
)


def test_permutation_delta_round_trip_supports_both_directions() -> None:
    permutation = [2, 0, 3, 1]
    for direction in ("old_to_new", "new_to_old"):
        encoded = encode_permutation_delta(permutation, direction=direction)
        assert decode_permutation_delta(encoded) == permutation


def test_permuted_graph_sidecar_restores_duplicates_order_and_source_hash() -> None:
    source_sha = bytes(range(32))
    records = [
        (0, 2_147_483_649, 0, 1, 7, 2, 3),
        (0, 2_147_483_649, 1, 1, 7, 2, 3),
        (1, 2_147_483_649, 0, 1, 8, 2, 4),
    ]
    canonical = bytearray(b"PWGI1\0\0\0")
    canonical.extend((32).to_bytes(4, "little"))
    canonical.extend(len(records).to_bytes(8, "little"))
    canonical.extend(source_sha)
    for table, pair_id, ordinal, si, sf, ti, tf in records:
        canonical.extend(bytes((table, 0, 0, 0)))
        canonical.extend(pair_id.to_bytes(8, "little"))
        canonical.extend(ordinal.to_bytes(4, "little"))
        canonical.extend(si.to_bytes(4, "little"))
        canonical.extend(sf.to_bytes(4, "little"))
        canonical.extend(ti.to_bytes(4, "little"))
        canonical.extend(tf.to_bytes(4, "little"))

    parsed, parsed_sha = parse_canonical_records(bytes(canonical))
    assert parsed == records
    assert parsed_sha == source_sha

    # New graph IDs: old feature nodes [(1,7),(1,8),(2,3),(2,4)] -> [2,0,3,1].
    features_by_new_node = [(1, 8), (2, 4), (1, 7), (2, 3)]
    final_arcs = [(0, 1), (2, 3)]
    arc_sequence = [1, 1, 0]
    groups = [(0, 2_147_483_649, 2), (1, 2_147_483_649, 1)]
    sidecar = encode_direct_mapping_v2(
        features_by_new_node, groups, arc_sequence, len(final_arcs), source_sha
    )
    decoded = decode_direct_mapping(sidecar)
    assert decoded.features == features_by_new_node
    restored = restore_canonical_from_permuted_arcs(sidecar, final_arcs)
    assert restored == bytes(canonical)
