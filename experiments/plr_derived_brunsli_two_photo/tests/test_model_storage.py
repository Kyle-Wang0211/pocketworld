import pytest

from pw_plr.model_storage import decode_model_storage, encode_model_storage


def test_model_storage_counts_codec_manifest_and_payload_in_one_envelope() -> None:
    original = b"exact deployment model artifact" * 11
    compressed = b"registered compressed payload"
    document = encode_model_storage(
        codec_id="zstd_1_5_7_level22",
        model_artifact=original,
        encoded_payload=compressed,
    )

    decoded = decode_model_storage(document)
    assert decoded.codec_id == "zstd_1_5_7_level22"
    assert decoded.model_bytes == len(original)
    assert decoded.encoded_payload == compressed
    assert len(document) > len(compressed)


def test_model_storage_rejects_manifest_or_payload_corruption() -> None:
    document = bytearray(
        encode_model_storage(
            codec_id="raw",
            model_artifact=b"model",
            encoded_payload=b"model",
        )
    )
    document[-1] ^= 1
    with pytest.raises(ValueError, match="SHA-256"):
        decode_model_storage(bytes(document))


@pytest.mark.parametrize("codec_id", ["", "white space", "../zpaq", "A" * 65])
def test_model_storage_rejects_ambiguous_codec_identity(codec_id: str) -> None:
    with pytest.raises(ValueError, match="codec"):
        encode_model_storage(
            codec_id=codec_id,
            model_artifact=b"model",
            encoded_payload=b"payload",
        )

