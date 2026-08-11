import hashlib
import json
import os
from pathlib import Path
import random
import subprocess
import tempfile
import unittest

import numpy as np

from cross_photo_estimator import (
    ArchiveFrame,
    CoefficientComponent,
    JpegCoefficientData,
    REQUIRED_RESULT_KEYS,
    adjacent_pairs,
    apply_block_prediction,
    build_prediction_mappings,
    build_result,
    decode_group_payload,
    decode_coefficient_tokens,
    encode_group_payload,
    encode_coefficient_tokens,
    invert_block_prediction,
    load_binary_ply_xyz,
    load_registered_poses,
    make_groups,
    parse_pwc,
    project_point,
    ratio_threshold_impossible,
    serialize_pwc,
    select_consecutive_sample,
    vote_block_map,
)


SOURCE_ROOT = Path(
    "/private/tmp/pw_archive_gate_refresh_20260730_4b0e3dd/"
    "before/Documents/captures_official/cap_1785155296535863"
)


class SampleContractTest(unittest.TestCase):
    def test_selects_registered_100_mib_prefix(self) -> None:
        sample = select_consecutive_sample(
            SOURCE_ROOT / "official_photo_bundle.json",
            SOURCE_ROOT / "photos_highres",
            100 * 1024 * 1024,
        )

        self.assertEqual(len(sample), 37)
        self.assertEqual(sum(item.bytes for item in sample), 105_908_333)
        self.assertEqual(sample[0].name, "official_tap-24.jpg")
        self.assertEqual(sample[-1].name, "official_tap-712.jpg")

    def test_groups_bound_random_access(self) -> None:
        for group_size in (4, 8):
            groups = make_groups(list(range(37)), group_size)
            self.assertEqual(
                [item for group in groups for item in group],
                list(range(37)),
            )
            self.assertLessEqual(max(map(len, groups)), group_size)
            rng = random.Random(20260730)
            for requested in rng.sample(range(37), 10):
                containing = [group for group in groups if requested in group]
                self.assertEqual(len(containing), 1)
                self.assertLessEqual(len(containing[0]), group_size)

    def test_adjacent_pairs_have_equal_zip_lengths(self) -> None:
        self.assertEqual(
            adjacent_pairs([0, 1, 2, 3]),
            [(0, 1), (1, 2), (2, 3)],
        )
        self.assertEqual(adjacent_pairs([0]), [])

    def test_ratio_threshold_impossible_uses_zero_byte_remainder_bound(self) -> None:
        self.assertFalse(
            ratio_threshold_impossible(
                source_total_bytes=1000,
                archive_bytes_so_far=400,
                minimum_ratio=2.0,
            )
        )
        self.assertTrue(
            ratio_threshold_impossible(
                source_total_bytes=1000,
                archive_bytes_so_far=501,
                minimum_ratio=2.0,
            )
        )


class GeometryContractTest(unittest.TestCase):
    def test_projects_identity_camera(self) -> None:
        pose = np.eye(4, dtype=np.float64)
        projected = project_point(
            pose,
            (100.0, 100.0, 50.0, 40.0),
            np.array((0.0, 0.0, 2.0), dtype=np.float64),
        )
        self.assertEqual(projected, (50.0, 40.0, 2.0))

    def test_sparse_ply_and_registered_poses_are_real(self) -> None:
        xyz = load_binary_ply_xyz(SOURCE_ROOT / "official_sfm_sparse.ply")
        poses = load_registered_poses(
            SOURCE_ROOT / "official_sfm_sparse_meta.json"
        )

        self.assertEqual(xyz.shape, (80_467, 3))
        self.assertGreaterEqual(len(poses), 37)
        self.assertTrue(all(index in poses for index in range(37)))

    def test_block_vote_is_deterministic(self) -> None:
        target = np.array(((0, 0), (0, 0), (1, 0)), dtype=np.int32)
        reference = np.array(((2, 1), (2, 1), (3, 1)), dtype=np.int32)

        mapping, covered = vote_block_map(
            target,
            reference,
            target_width_blocks=3,
            target_height_blocks=2,
            reference_width_blocks=5,
            reference_height_blocks=3,
        )

        self.assertEqual(covered, 2)
        self.assertEqual(tuple(mapping[0, 0]), (2, 1))
        self.assertEqual(tuple(mapping[0, 1]), (3, 1))
        self.assertEqual(tuple(mapping[1, 2]), (2, 1))

    def test_identity_geometry_maps_each_component_block_to_itself(self) -> None:
        points = np.array(
            (
                (4.0, 4.0, 1.0),
                (12.0, 4.0, 1.0),
                (4.0, 12.0, 1.0),
                (12.0, 12.0, 1.0),
            ),
            dtype=np.float64,
        )
        component = CoefficientComponent(
            width_blocks=2,
            height_blocks=2,
            coefficients=np.zeros((4, 64), dtype=np.int16),
        )

        mappings, valid_projections, covered_blocks, total_blocks = (
            build_prediction_mappings(
                points,
                target_pose=np.eye(4),
                reference_pose=np.eye(4),
                target_intrinsics=(1.0, 1.0, 0.0, 0.0),
                reference_intrinsics=(1.0, 1.0, 0.0, 0.0),
                image_width=16,
                image_height=16,
                target_components=(component,),
                reference_components=(component,),
            )
        )

        np.testing.assert_array_equal(
            mappings[0],
            np.array(
                (((0, 0), (1, 0)), ((0, 1), (1, 1))),
                dtype=np.int32,
            ),
        )
        self.assertEqual(valid_projections, 4)
        self.assertEqual(covered_blocks, 4)
        self.assertEqual(total_blocks, 4)


class CoefficientTokenContractTest(unittest.TestCase):
    def test_token_round_trip(self) -> None:
        coefficients = np.zeros((5, 64), dtype=np.int16)
        coefficients[0, 0] = 17
        coefficients[1, 1] = -3
        coefficients[3, 63] = 22

        encoded = encode_coefficient_tokens(coefficients)
        decoded = decode_coefficient_tokens(encoded, block_count=5)

        np.testing.assert_array_equal(decoded, coefficients)

    def test_prediction_round_trip(self) -> None:
        reference = np.arange(4 * 64, dtype=np.int16).reshape(4, 64)
        target = reference.copy()
        target[2, 7] += 9
        mapping = np.array(((0, 0), (1, 0), (0, 1), (1, 1)), dtype=np.int32)

        residual = apply_block_prediction(
            target,
            reference,
            mapping,
            target_width_blocks=2,
            reference_width_blocks=2,
        )
        restored = invert_block_prediction(
            residual,
            reference,
            mapping,
            target_width_blocks=2,
            reference_width_blocks=2,
        )

        np.testing.assert_array_equal(restored, target)


class JpegCoefficientToolContractTest(unittest.TestCase):
    def test_real_jpeg_round_trip_is_byte_exact(self) -> None:
        tool = Path(os.environ["PW_JPEG_COEFF_TOOL"])
        source = SOURCE_ROOT / "photos_highres/official_tap-24.jpg"
        with tempfile.TemporaryDirectory(
            prefix="pw-coeff-roundtrip-", dir="/private/tmp"
        ) as directory:
            coefficient_file = Path(directory) / "frame.pwc"
            restored = Path(directory) / "restored.jpg"
            subprocess.run(
                [tool, "extract", source, coefficient_file],
                check=True,
            )
            subprocess.run(
                [tool, "restore", coefficient_file, restored],
                check=True,
            )

            self.assertEqual(source.read_bytes(), restored.read_bytes())
            self.assertEqual(
                hashlib.sha256(source.read_bytes()).hexdigest(),
                hashlib.sha256(restored.read_bytes()).hexdigest(),
            )

    def test_truncated_coefficient_container_is_rejected(self) -> None:
        tool = Path(os.environ["PW_JPEG_COEFF_TOOL"])
        source = SOURCE_ROOT / "photos_highres/official_tap-24.jpg"
        with tempfile.TemporaryDirectory(
            prefix="pw-coeff-corrupt-", dir="/private/tmp"
        ) as directory:
            coefficient_file = Path(directory) / "frame.pwc"
            truncated = Path(directory) / "truncated.pwc"
            restored = Path(directory) / "restored.jpg"
            subprocess.run(
                [tool, "extract", source, coefficient_file],
                check=True,
            )
            data = coefficient_file.read_bytes()
            truncated.write_bytes(data[: len(data) // 2])

            result = subprocess.run(
                [tool, "restore", truncated, restored],
                check=False,
                capture_output=True,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(restored.exists())

    def test_pwc_parser_round_trip_preserves_container(self) -> None:
        tool = Path(os.environ["PW_JPEG_COEFF_TOOL"])
        source = SOURCE_ROOT / "photos_highres/official_tap-24.jpg"
        with tempfile.TemporaryDirectory(
            prefix="pw-coeff-parse-", dir="/private/tmp"
        ) as directory:
            coefficient_file = Path(directory) / "frame.pwc"
            subprocess.run(
                [tool, "extract", source, coefficient_file],
                check=True,
            )
            original = coefficient_file.read_bytes()

            parsed = parse_pwc(original)

            self.assertEqual(serialize_pwc(parsed), original)


class GroupArchiveContractTest(unittest.TestCase):
    def _frames_and_mappings(
        self,
    ) -> tuple[list[ArchiveFrame], list[list[np.ndarray]]]:
        first = np.zeros((4, 64), dtype=np.int16)
        first[:, 0] = (10, 20, 30, 40)
        second = first.copy()
        second[1, 7] = -4
        component_one = CoefficientComponent(
            width_blocks=2,
            height_blocks=2,
            coefficients=first,
        )
        component_two = CoefficientComponent(
            width_blocks=2,
            height_blocks=2,
            coefficients=second,
        )
        frames = [
            ArchiveFrame(
                index=0,
                name="first.jpg",
                source_bytes=100,
                source_sha256="00" * 32,
                jpeg=JpegCoefficientData(
                    restart_interval=7,
                    header=b"\xff\xd8header-one",
                    components=(component_one,),
                ),
            ),
            ArchiveFrame(
                index=1,
                name="second.jpg",
                source_bytes=101,
                source_sha256="11" * 32,
                jpeg=JpegCoefficientData(
                    restart_interval=7,
                    header=b"\xff\xd8header-two",
                    components=(component_two,),
                ),
            ),
        ]
        identity = np.array(
            (((0, 0), (1, 0)), ((0, 1), (1, 1))),
            dtype=np.int32,
        )
        return frames, [[identity]]

    def test_group_payload_is_deterministic_and_reversible(self) -> None:
        frames, mappings = self._frames_and_mappings()

        encoded = encode_group_payload(frames, mappings)
        restored = decode_group_payload(encoded, mappings)

        self.assertEqual(encoded, encode_group_payload(frames, mappings))
        self.assertEqual(
            [serialize_pwc(frame.jpeg) for frame in restored],
            [serialize_pwc(frame.jpeg) for frame in frames],
        )
        self.assertEqual(
            [(frame.name, frame.source_bytes, frame.source_sha256) for frame in restored],
            [(frame.name, frame.source_bytes, frame.source_sha256) for frame in frames],
        )

    def test_group_payload_corruption_is_rejected(self) -> None:
        frames, mappings = self._frames_and_mappings()
        encoded = bytearray(encode_group_payload(frames, mappings))
        encoded[len(encoded) // 2] ^= 1

        with self.assertRaisesRegex(ValueError, "digest"):
            decode_group_payload(bytes(encoded), mappings)


class ResultContractTest(unittest.TestCase):
    def test_result_contains_measurement_contract(self) -> None:
        result = build_result(
            source_jpeg_bytes=1000,
            archive_bytes=400,
            exactness_failures=0,
            input_hash_failures=0,
            valid_sparse_projections=12,
            random_access_group_overflow=0,
            mapped_block_fraction=0.25,
            encode_elapsed_ms=10,
            decode_elapsed_ms=4,
            peak_rss_bytes=123,
        )

        self.assertEqual(set(REQUIRED_RESULT_KEYS) - set(result), set())
        self.assertEqual(result["photo_ratio"], 2.5)
        self.assertGreaterEqual(result["photo_ratio"], 2.165)


if __name__ == "__main__":
    unittest.main()
