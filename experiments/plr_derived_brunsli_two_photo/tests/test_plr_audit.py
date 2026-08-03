from pw_plr.plr_audit import audit_class_source


def test_audit_class_source_finds_stale_codec_members() -> None:
    source = """
class Candidate(Base):
    def __init__(self):
        self.trained = object()

    def helper(self):
        return None

    def forward(self, y, cb, cr):
        return self.trained(y)

    def compress(self, y, cb, cr):
        return self.stale.compress(y), self.helper()

    def decompress(self, stream):
        return self.stale.decompress(stream)
"""

    result = audit_class_source(source, "Candidate")

    assert result["constructor_attributes"] == ["trained"]
    assert result["compress_undefined_attributes"] == ["stale"]
    assert result["decompress_undefined_attributes"] == ["stale"]
    assert result["forward_reads_gaussian_cbcr"] is False
