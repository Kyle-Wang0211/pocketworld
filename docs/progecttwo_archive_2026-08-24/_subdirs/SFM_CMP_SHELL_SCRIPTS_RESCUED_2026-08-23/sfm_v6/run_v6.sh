#!/bin/bash
set -e
cd "/Users/kaidongwang/Developer/Aether3D-cross/pocketworld_research_benchmarks/tools/python/sfm_cmp/sfm_v6"
echo "V6 START $(date +%H:%M:%S)"
colmap feature_extractor --database_path db.db --image_path "/Users/kaidongwang/Developer/Aether3D-cross/pocketworld_research_benchmarks/data/official_da3_base_k35_strict_seq_2026_06_02/capture_seq_k35_strict/photos_highres"   --ImageReader.single_camera 0 --ImageReader.camera_model SIMPLE_RADIAL   --SiftExtraction.max_image_size 2048 --SiftExtraction.max_num_features 8192   --SiftExtraction.peak_threshold 0.004 --SiftExtraction.edge_threshold 15   --SiftExtraction.estimate_affine_shape 1 --SiftExtraction.domain_size_pooling 1   --FeatureExtraction.use_gpu 0 > feat.log 2>&1
echo "V6 FEAT DONE $(date +%H:%M:%S)"
colmap matches_importer --database_path db.db --match_list_path pairs.txt --match_type pairs   --SiftMatching.max_ratio 0.7 --FeatureMatching.use_gpu 0 > match.log 2>&1
echo "V6 MATCH DONE $(date +%H:%M:%S)"
rm -rf sparse_glomap; mkdir -p sparse_glomap
"/Users/kaidongwang/Developer/Aether3D-cross/pocketworld_research_benchmarks/tools/python/sfm_cmp/glomap/build/glomap/glomap" mapper --database_path db.db --image_path "/Users/kaidongwang/Developer/Aether3D-cross/pocketworld_research_benchmarks/data/official_da3_base_k35_strict_seq_2026_06_02/capture_seq_k35_strict/photos_highres" --output_path sparse_glomap > glomap.log 2>&1
GD=$(ls -d sparse_glomap/0 2>/dev/null || echo sparse_glomap)
echo "V6 GLOMAP DONE $(date +%H:%M:%S)"
# re-triangulate denser on GLOMAP poses: low angle + keep two-view tracks
rm -rf sparse_dense; mkdir -p sparse_dense
colmap point_triangulator --database_path db.db --image_path "/Users/kaidongwang/Developer/Aether3D-cross/pocketworld_research_benchmarks/data/official_da3_base_k35_strict_seq_2026_06_02/capture_seq_k35_strict/photos_highres" --input_path "$GD" --output_path sparse_dense   --Mapper.tri_min_angle 0.5 --Mapper.tri_ignore_two_view_tracks 0 > tri.log 2>&1
echo "V6 RETRI DONE $(date +%H:%M:%S)"
colmap model_converter --input_path sparse_dense --output_path glomap_hd_raw.ply --output_type PLY
mkdir -p txt_glomap; colmap model_converter --input_path sparse_dense --output_path txt_glomap --output_type TXT
/opt/homebrew/bin/python3.11 "/Users/kaidongwang/Developer/Aether3D-cross/pocketworld_research_benchmarks/tools/python/sfm_cmp/sfm_v6/align_v6.py"
echo "V6 ALL DONE $(date +%H:%M:%S)"
echo "points: $(colmap model_analyzer --path sparse_dense 2>&1 | grep -oE 'Points: [0-9]+|Registered images: [0-9]+|Mean reprojection error: [0-9.]+px')"
