#!/bin/bash
set -e
cd "/Users/kaidongwang/Developer/Aether3D-cross/pocketworld_research_benchmarks/tools/python/sfm_cmp/sfm_hd"
echo "GHD START $(date +%H:%M)"
colmap feature_extractor --database_path db.db --image_path "/Users/kaidongwang/Developer/Aether3D-cross/pocketworld_research_benchmarks/data/official_da3_base_k35_strict_seq_2026_06_02/capture_seq_k35_strict/photos_highres"   --ImageReader.single_camera 0 --ImageReader.camera_model SIMPLE_RADIAL   --SiftExtraction.max_image_size 3840 --SiftExtraction.max_num_features 32768   --SiftExtraction.peak_threshold 0.004 --SiftExtraction.edge_threshold 15   --SiftExtraction.estimate_affine_shape 1 --SiftExtraction.domain_size_pooling 1   --FeatureExtraction.use_gpu 0 > feat.log 2>&1
echo "GHD FEAT DONE $(date +%H:%M)"
colmap exhaustive_matcher --database_path db.db --SiftMatching.max_ratio 0.7   --FeatureMatching.guided_matching 1 --FeatureMatching.use_gpu 0 > match.log 2>&1
echo "GHD MATCH DONE $(date +%H:%M)"
"/Users/kaidongwang/Developer/Aether3D-cross/pocketworld_research_benchmarks/tools/python/sfm_cmp/glomap/build/glomap/glomap" mapper --database_path db.db --image_path "/Users/kaidongwang/Developer/Aether3D-cross/pocketworld_research_benchmarks/data/official_da3_base_k35_strict_seq_2026_06_02/capture_seq_k35_strict/photos_highres" --output_path sparse_glomap > glomap.log 2>&1
GD=$(ls -d sparse_glomap/0 2>/dev/null || echo sparse_glomap)
colmap model_converter --input_path "$GD" --output_path glomap_hd_raw.ply --output_type PLY
mkdir -p txt_glomap; colmap model_converter --input_path "$GD" --output_path txt_glomap --output_type TXT
echo "GHD GLOMAP DONE $(date +%H:%M)"
/opt/homebrew/bin/python3.11 "/Users/kaidongwang/Developer/Aether3D-cross/pocketworld_research_benchmarks/tools/python/sfm_cmp/sfm_hd/align_hd.py"
echo "GHD ALL DONE $(date +%H:%M)"; ls -la *.ply
