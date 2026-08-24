#!/bin/bash
set -e
cd "/Users/kaidongwang/Developer/Aether3D-cross/pocketworld_research_benchmarks/tools/python/sfm_cmp/sfm_dsp"
echo "PROD START $(date +%H:%M:%S)"
colmap matches_importer --database_path db.db --match_list_path pairs.txt --match_type pairs   --SiftMatching.max_ratio 0.7 --FeatureMatching.use_gpu 0 > match_prod.log 2>&1
echo "PROD MATCH DONE $(date +%H:%M:%S)"
rm -rf sparse_prod; mkdir -p sparse_prod
"/Users/kaidongwang/Developer/Aether3D-cross/pocketworld_research_benchmarks/tools/python/sfm_cmp/glomap/build/glomap/glomap" mapper --database_path db.db --image_path "/Users/kaidongwang/Developer/Aether3D-cross/pocketworld_research_benchmarks/data/official_da3_base_k35_strict_seq_2026_06_02/capture_seq_k35_strict/photos_highres" --output_path sparse_prod > glomap_prod.log 2>&1
GD=$(ls -d sparse_prod/0 2>/dev/null || echo sparse_prod)
colmap model_converter --input_path "$GD" --output_path glomap_hd_raw.ply --output_type PLY
mkdir -p txt_glomap; colmap model_converter --input_path "$GD" --output_path txt_glomap --output_type TXT
echo "PROD GLOMAP DONE $(date +%H:%M:%S)"
/opt/homebrew/bin/python3.11 "/Users/kaidongwang/Developer/Aether3D-cross/pocketworld_research_benchmarks/tools/python/sfm_cmp/sfm_dsp/align_prod.py"
echo "PROD ALL DONE $(date +%H:%M:%S)"; ls -la glomap_prod.ply
