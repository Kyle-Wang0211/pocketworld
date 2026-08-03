from pathlib import Path

from collection_slice import Edge, extract_collection_slice, maximum_feature_tree


HERE = Path(__file__).resolve().parents[1]


def test_maximum_tree_uses_every_node_once() -> None:
    edges = (
        Edge(0, 1, 9, 3.0),
        Edge(1, 2, 8, 2.0),
        Edge(0, 2, 1, 1.0),
    )

    tree = maximum_feature_tree((0, 1, 2), edges, {0: 30, 1: 20, 2: 10})

    assert tree.root == 1
    assert {(edge.parent, edge.child) for edge in tree.edges} == {(1, 0), (1, 2)}
    assert tree.maximum_dependency_photos == 2


def test_edge_ties_are_broken_by_descriptor_distance_then_ids() -> None:
    edges = (
        Edge(0, 1, 8, 4.0),
        Edge(0, 2, 8, 2.0),
        Edge(1, 2, 8, 3.0),
    )

    tree = maximum_feature_tree((0, 1, 2), edges, {0: 12, 1: 11, 2: 10})

    assert tree.root == 2
    assert {(edge.parent, edge.child) for edge in tree.edges} == {(2, 0), (2, 1)}


def test_frozen_collection_has_complete_graph_and_registered_tree() -> None:
    value = extract_collection_slice(HERE / "input-manifest.yaml")

    assert tuple(photo.ordinal for photo in value.photos) == tuple(range(8))
    assert len(value.edges) == 28
    assert sum(edge.verified_rows for edge in value.edges) == 11_546
    assert value.tree.root == 2
    assert {
        tuple(sorted((edge.parent, edge.child))) + (edge.verified_rows,)
        for edge in value.tree.edges
    } == {
        (1, 2, 1395),
        (2, 3, 890),
        (7, 8, 733),
        (3, 8, 583),
        (6, 7, 473),
        (3, 5, 438),
        (3, 4, 435),
    }
    assert value.tree.maximum_dependency_photos <= 8
