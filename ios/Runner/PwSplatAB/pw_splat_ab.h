// pw_splat_ab.h — C entry points of the splat / points / cloud WebGPU benches (bench-only).
// Verbatim from pw_splat_ab_bench Sources/Bridging.h @ b792d57, minus its first include
// (`lod/pw_lod_bench.h`): arloopbench already declares pwlod_run through
// vendor/aether_lod/include/pw_lod_bench.h (PwLodSurface.h), and re-including the copy
// from that repo would declare the same types twice.
#pragma once
#ifdef __cplusplus
extern "C" {
#endif
// 返回结果 JSON 的落盘路径(失败时返回诊断串)。
const char* pwsplat_ab_run(const char* out_dir, int K, int R, int warmup);
// 裸点云台架(bench_points.mm)。cell_sel: -1=全跑,0=1M,1=4M,2=6.92M。
// radius_tenths: quad 半径,单位 0.1 px(15 = 1.5 px)。
const char* pwpoints_run(const char* out_dir, int K, int R, int warmup,
                         int cell_sel, int radius_tenths, const char* tag);
// 真实聚簇点云 + 透视缩放台架(bench_cloud.mm)。
// cam_sel: 0=拟合 1=拟合/4 2=对角线/4;base_tenths: baseScale(0.1 px)
// arm_mask bit: 0=RN 1=RM 2=RM2 3=RR 4=UM 5=UR
const char* pwcloud_run(const char* out_dir, const char* cloud_path,
                        int K, int R, int warmup, int cam_sel,
                        int base_tenths, int arm_mask, const char* tag);
#ifdef __cplusplus
}
#endif
