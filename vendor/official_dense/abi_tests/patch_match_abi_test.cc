#include "official_dense/patch_match_abi.h"

#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <type_traits>

namespace abi = pocketworld::official_dense::vulkan;

static_assert(std::is_standard_layout_v<abi::PatchPC>);
static_assert(sizeof(abi::PatchPC) == 128);
static_assert(alignof(abi::PatchPC) == 4);

#define CHECK_PATCH_PC_OFFSET(member, expected) \
  static_assert(offsetof(abi::PatchPC, member) == expected)

CHECK_PATCH_PC_OFFSET(width, 0);
CHECK_PATCH_PC_OFFSET(height, 4);
CHECK_PATCH_PC_OFFSET(num_sources, 8);
CHECK_PATCH_PC_OFFSET(workspace_max_dim, 12);
CHECK_PATCH_PC_OFFSET(source_width, 16);
CHECK_PATCH_PC_OFFSET(source_height, 20);
CHECK_PATCH_PC_OFFSET(rotation_0_to_3, 24);
CHECK_PATCH_PC_OFFSET(reserved, 28);
CHECK_PATCH_PC_OFFSET(ref_K_fx, 32);
CHECK_PATCH_PC_OFFSET(ref_K_cx, 36);
CHECK_PATCH_PC_OFFSET(ref_K_fy, 40);
CHECK_PATCH_PC_OFFSET(ref_K_cy, 44);
CHECK_PATCH_PC_OFFSET(ref_inv_fx, 48);
CHECK_PATCH_PC_OFFSET(ref_inv_neg_cx_fx, 52);
CHECK_PATCH_PC_OFFSET(ref_inv_fy, 56);
CHECK_PATCH_PC_OFFSET(ref_inv_neg_cy_fy, 60);
CHECK_PATCH_PC_OFFSET(perturbation, 64);
CHECK_PATCH_PC_OFFSET(depth_min, 68);
CHECK_PATCH_PC_OFFSET(depth_max, 72);
CHECK_PATCH_PC_OFFSET(num_samples, 76);
CHECK_PATCH_PC_OFFSET(sigma_spatial, 80);
CHECK_PATCH_PC_OFFSET(sigma_color, 84);
CHECK_PATCH_PC_OFFSET(ncc_sigma, 88);
CHECK_PATCH_PC_OFFSET(min_triangulation_angle_rad, 92);
CHECK_PATCH_PC_OFFSET(incident_angle_sigma, 96);
CHECK_PATCH_PC_OFFSET(prev_sel_prob_weight, 100);
CHECK_PATCH_PC_OFFSET(geom_consistency_regularizer, 104);
CHECK_PATCH_PC_OFFSET(geom_consistency_max_cost, 108);
CHECK_PATCH_PC_OFFSET(filter_min_ncc, 112);
CHECK_PATCH_PC_OFFSET(filter_min_triangulation_angle_rad, 116);
CHECK_PATCH_PC_OFFSET(filter_min_num_consistent, 120);
CHECK_PATCH_PC_OFFSET(filter_geom_consistency_max_cost, 124);

#undef CHECK_PATCH_PC_OFFSET

static_assert(static_cast<std::uint32_t>(abi::Binding::kDepth) == 0);
static_assert(static_cast<std::uint32_t>(abi::Binding::kNormal) == 1);
static_assert(static_cast<std::uint32_t>(abi::Binding::kCost) == 2);
static_assert(static_cast<std::uint32_t>(abi::Binding::kSelProb) == 3);
static_assert(static_cast<std::uint32_t>(abi::Binding::kPrevSelProb) == 4);
static_assert(static_cast<std::uint32_t>(abi::Binding::kConsistencyMask) == 5);
static_assert(static_cast<std::uint32_t>(abi::Binding::kRngState) == 6);
static_assert(static_cast<std::uint32_t>(abi::Binding::kWorkspace) == 7);
static_assert(static_cast<std::uint32_t>(abi::Binding::kRawRefBytes) == 8);
static_assert(static_cast<std::uint32_t>(abi::Binding::kFilteredRefBytes) == 9);
static_assert(static_cast<std::uint32_t>(abi::Binding::kRefWeightedSum) == 10);
static_assert(
    static_cast<std::uint32_t>(abi::Binding::kRefWeightedSquaredSum) == 11);
static_assert(static_cast<std::uint32_t>(abi::Binding::kSourceDepth) == 12);
static_assert(static_cast<std::uint32_t>(abi::Binding::kActivePoseTable) == 13);
static_assert(static_cast<std::uint32_t>(abi::Binding::kSourceGrayImage) == 14);
static_assert(abi::kBindingCount == 15);

static_assert(abi::kPoseFloatCount == 43);
static_assert(abi::kPoseIntrinsicsOffset == 0);
static_assert(abi::kPoseRotationOffset == 4);
static_assert(abi::kPoseTranslationOffset == 13);
static_assert(abi::kPoseProjectionCenterOffset == 16);
static_assert(abi::kPoseProjectionMatrixOffset == 19);
static_assert(abi::kPoseInverseProjectionMatrixOffset == 31);

namespace {

void ExpectEqual(const std::size_t actual,
                 const std::size_t expected,
                 const char* const label) {
  if (actual != expected) {
    std::cerr << label << ": expected " << expected << ", got " << actual
              << '\n';
    std::exit(EXIT_FAILURE);
  }
}

}  // namespace

int main() {
  constexpr std::size_t kWidth = 7;
  constexpr std::size_t kHeight = 5;
  constexpr std::size_t kPlaneSize = kWidth * kHeight;

  ExpectEqual(abi::GpuMatIndex(0, 0, 0, kWidth, kHeight), 0,
              "GpuMat first element");
  ExpectEqual(abi::GpuMatIndex(0, kHeight - 1, kWidth - 1, kWidth, kHeight),
              kPlaneSize - 1, "GpuMat first plane last element");
  ExpectEqual(abi::GpuMatIndex(1, 0, 0, kWidth, kHeight), kPlaneSize,
              "GpuMat plane boundary");
  ExpectEqual(abi::GpuMatIndex(2, kHeight - 1, kWidth - 1, kWidth, kHeight),
              3 * kPlaneSize - 1, "normal three-plane last element");
  ExpectEqual(abi::NormalIndex(0, 0, 0, kWidth, kHeight), 0,
              "normal x-plane first element");
  ExpectEqual(abi::NormalIndex(1, 0, 0, kWidth, kHeight), kPlaneSize,
              "normal y-plane boundary");
  ExpectEqual(abi::NormalIndex(2, 0, 0, kWidth, kHeight), 2 * kPlaneSize,
              "normal z-plane boundary");

  constexpr std::size_t kSourceWidth = 11;
  constexpr std::size_t kSourceHeight = 9;
  constexpr std::size_t kSourcePlaneSize = kSourceWidth * kSourceHeight;
  ExpectEqual(abi::SourceIndex(0, 0, 0, kSourceWidth, kSourceHeight), 0,
              "source first element");
  ExpectEqual(abi::SourceIndex(1, 0, 0, kSourceWidth, kSourceHeight),
              kSourcePlaneSize, "source layer boundary");
  ExpectEqual(abi::SourceIndex(2, kSourceHeight - 1, kSourceWidth - 1,
                               kSourceWidth, kSourceHeight),
              3 * kSourcePlaneSize - 1, "source last element");

  constexpr std::size_t kWorkspaceMaxDim = 13;
  constexpr std::size_t kNumSources = 4;
  constexpr std::size_t kWorkspacePlaneSize =
      kWorkspaceMaxDim * kNumSources;
  ExpectEqual(abi::WorkspaceIndex(0, 0, 0, kWorkspaceMaxDim, kNumSources), 0,
              "workspace first element");
  ExpectEqual(abi::WorkspaceIndex(0, kWorkspaceMaxDim - 1,
                                  kNumSources - 1, kWorkspaceMaxDim,
                                  kNumSources),
              kWorkspacePlaneSize - 1, "workspace first kind last element");
  ExpectEqual(abi::WorkspaceIndex(1, 0, 0, kWorkspaceMaxDim, kNumSources),
              kWorkspacePlaneSize, "workspace kind boundary");
  ExpectEqual(abi::WorkspaceIndex(1, kWorkspaceMaxDim - 1,
                                  kNumSources - 1, kWorkspaceMaxDim,
                                  kNumSources),
              2 * kWorkspacePlaneSize - 1, "workspace last element");

  return EXIT_SUCCESS;
}
