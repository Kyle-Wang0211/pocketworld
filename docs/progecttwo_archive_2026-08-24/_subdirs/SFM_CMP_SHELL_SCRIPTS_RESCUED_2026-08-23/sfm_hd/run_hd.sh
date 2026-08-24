#!/bin/bash
set -e
cd "/Users/kaidongwang/Developer/Aether3D-cross/pocketworld_research_benchmarks/tools/python/sfm_cmp/sfm_hd"
echo "HD START $(date +%H:%M)"
# 1. high-density feature extraction (full-res, 32768, low peak, high edge, DSP-SIFT)
colmap feature_extractor --database_path db.db --image_path "/Users/kaidongwang/Developer/Aether3D-cross/pocketworld_research_benchmarks/data/official_da3_base_k35_strict_seq_2026_06_02/capture_seq_k35_strict/photos_highres"   --ImageReader.single_camera 1 --ImageReader.camera_model SIMPLE_RADIAL   --SiftExtraction.max_image_size 3840 --SiftExtraction.max_num_features 32768   --SiftExtraction.peak_threshold 0.004 --SiftExtraction.edge_threshold 15   --SiftExtraction.estimate_affine_shape 1 --SiftExtraction.domain_size_pooling 1   --FeatureExtraction.use_gpu 0 > feat.log 2>&1
echo "FEAT DONE $(date +%H:%M)"
# 2. exhaustive matching, tighter ratio 0.7 + guided
colmap exhaustive_matcher --database_path db.db --SiftMatching.max_ratio 0.7   --FeatureMatching.guided_matching 1 --FeatureMatching.use_gpu 0 > match.log 2>&1
echo "MATCH DONE $(date +%H:%M)"
# 3. COLMAP mapper (re-triangulation: lower angle, keep two-view tracks)
mkdir -p sparse; colmap mapper --database_path db.db --image_path "/Users/kaidongwang/Developer/Aether3D-cross/pocketworld_research_benchmarks/data/official_da3_base_k35_strict_seq_2026_06_02/capture_seq_k35_strict/photos_highres" --output_path sparse   --Mapper.tri_min_angle 1.0 --Mapper.tri_ignore_two_view_tracks 0 > map.log 2>&1
# pick largest model
best=""; bestn=0
for d in sparse/*/; do n=$(colmap model_analyzer --path "$d" 2>&1 | grep -oE "Registered images: [0-9]+" | grep -oE "[0-9]+"); n=${n:-0}; if [ "$n" -gt "$bestn" ]; then bestn=$n; best=$d; fi; done
echo "MAPPER DONE $(date +%H:%M) best=$best ($bestn imgs)"
colmap model_converter --input_path "$best" --output_path colmap_hd.ply --output_type PLY
colmap model_converter --input_path "$best" --output_path txt_colmap --output_type TXT 2>/dev/null || (mkdir -p txt_colmap && colmap model_converter --input_path "$best" --output_path txt_colmap --output_type TXT)
# 4. GLOMAP on same db
"/Users/kaidongwang/Developer/Aether3D-cross/pocketworld_research_benchmarks/tools/python/sfm_cmp/glomap/build/glomap/glomap" mapper --database_path db.db --image_path "/Users/kaidongwang/Developer/Aether3D-cross/pocketworld_research_benchmarks/data/official_da3_base_k35_strict_seq_2026_06_02/capture_seq_k35_strict/photos_highres" --output_path sparse_glomap > glomap.log 2>&1
GD=$(ls -d sparse_glomap/0 2>/dev/null || echo sparse_glomap)
colmap model_converter --input_path "$GD" --output_path glomap_hd_raw.ply --output_type PLY
mkdir -p txt_glomap; colmap model_converter --input_path "$GD" --output_path txt_glomap --output_type TXT
echo "GLOMAP DONE $(date +%H:%M)"
# 5. align glomap_hd -> colmap_hd frame
/opt/homebrew/bin/python3.11 "/Users/kaidongwang/Developer/Aether3D-cross/pocketworld_research_benchmarks/tools/python/sfm_cmp/sfm_hd/align_hd.py" || echo "align failed"
echo "HD ALL DONE $(date +%H:%M)"
ls -la *.ply
