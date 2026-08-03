import hashlib

import pytest

from joint_group import (
    JointGroupBuilder,
    JointGroupCorruption,
    JointGroupReader,
    corrupt_registered_field,
)


@pytest.fixture()
def valid_group():
    builder = JointGroupBuilder()
    root = builder.add_member("root_jpeg", b"root-jxl", dependencies=())
    graph = builder.add_member("prediction_graph", b"graph", dependencies=(root,))
    compensation = builder.add_member(
        "compensation_state", b"selectors", dependencies=(graph,)
    )
    frequency = builder.add_member(
        "frequency_selectors", b"frequency", dependencies=(graph,)
    )
    builder.add_member(
        "coefficient_residuals",
        b"residuals",
        dependencies=(graph, compensation, frequency),
    )
    builder.add_member(
        "jpeg_side_information", b"header", dependencies=(graph,)
    )
    return builder.build()


def test_complete_size_counts_every_decoder_dependency(valid_group):
    assert valid_group.complete_persisted_bytes == len(valid_group.data)
    assert valid_group.complete_persisted_bytes == (
        valid_group.header_bytes
        + sum(member.payload_bytes for member in valid_group.members)
        + valid_group.index_bytes
        + valid_group.footer_bytes
    )
    assert {member.kind for member in valid_group.members} >= {
        "root_jpeg",
        "prediction_graph",
        "compensation_state",
        "frequency_selectors",
        "coefficient_residuals",
        "jpeg_side_information",
    }
    reader = JointGroupReader(valid_group.data)
    assert reader.read_member(0) == b"root-jxl"
    assert hashlib.sha256(reader.read_member(4)).hexdigest() == hashlib.sha256(
        b"residuals"
    ).hexdigest()


@pytest.mark.parametrize("field", ["payload", "index", "dependency", "hash"])
def test_corruption_fails_before_output(valid_group, field):
    damaged = corrupt_registered_field(valid_group.data, field)
    with pytest.raises(JointGroupCorruption):
        JointGroupReader(damaged).read_member(4)

