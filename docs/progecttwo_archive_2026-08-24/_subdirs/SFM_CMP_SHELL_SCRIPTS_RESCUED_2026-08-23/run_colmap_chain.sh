#!/bin/bash
cd "/Users/kaidongwang/Developer/Aether3D-cross/pocketworld_research_benchmarks/tools/python/sfm_cmp"
# 1. wait for matcher (pid 4819) to finish
while ps -p 4819 >/dev/null 2>&1; do sleep 15; done
echo "MATCH DONE $(date +%H:%M)"
# 2. incremental mapper -> COLMAP sparse
mkdir -p sparse_colmap
colmap mapper --database_path db.db --image_path "/Users/kaidongwang/Developer/Aether3D-cross/pocketworld_research_benchmarks/data/official_da3_base_k35_strict_seq_2026_06_02/capture_seq_k35_strict/photos_highres" --output_path sparse_colmap >> /tmp/colmap_map.log 2>&1
echo "MAPPER DONE $(date +%H:%M)"
# 3. export COLMAP (version 1)
colmap model_converter --input_path sparse_colmap/0 --output_path colmap.ply --output_type PLY 2>>/tmp/colmap_map.log
# 4. extra global BA -> COLMAP+BA (version 2)
mkdir -p sparse_colmap_ba
colmap bundle_adjuster --input_path sparse_colmap/0 --output_path sparse_colmap_ba >> /tmp/colmap_map.log 2>&1
colmap model_converter --input_path sparse_colmap_ba --output_path colmap_ba.ply --output_type PLY 2>>/tmp/colmap_map.log
echo "COLMAP CHAIN DONE $(date +%H:%M)  pts: $(grep -c '^' colmap.ply 2>/dev/null)"
ls -la colmap.ply colmap_ba.ply 2>/dev/null
