// Copyright (c) 2026, PocketWorld contributors.
// SPDX-License-Identifier: BSD-3-Clause

#include "shader_bundle.h"

#include <array>
#include <cstdint>

namespace pocketworld::official_dense::vulkan::shader_bundle {
namespace {

#include "shader_bundle_data.inc"

constexpr std::array<FrozenShaderIdentity, runtime::kShaderCount>
    kFrozenShaderManifest = {{
        {runtime::PipelineKind::kReferenceFilter,
         "ref_filter/filter_u8.comp",
         "1c4509178d96df841d64b0c0263b2ebee6915a40f46448be5ba3336aa4d317c7",
         "76fc218d29b687c8aeec4bf5e16321343b93fd01f8e0c58c0774f8f03606108b",
         kShaderWords0.size()},
        {runtime::PipelineKind::kOpenMvsPcgInitialize,
         "rng/init_openmvs_pcg.comp",
         "5eb75c051603b345022f34023be5162e0c49c025b4c477d21e860094f0eaa03a",
         "302ebac4f548cf82d8a5bf9a802ffd075ea7815d2063a217ce43d6a7d5f30bd5",
         kShaderWords1.size()},
        {runtime::PipelineKind::kNormalInitialize,
         "normal_ops/init_normal_openmvs_pcg.comp",
         "9618000ea831ff3bfa320ee1d7229a11995eccb3111fb8cae3ef1889cc727d2c",
         "0c22b933e6b97e535d313ed4915adcba27ef9de6dd6232a974a7feacf55c79e2",
         kShaderWords2.size()},
        {runtime::PipelineKind::kInitialCost,
         "initial_cost/compute_initial_cost.comp",
         "46b10170e6458567f35e765f4ff0fa1360dd450e2713e7d7e85e20627a73c031",
         "dbc5ae3c6eef1b4eea88142dac320ccf408cf8987ff873d8e151262320e5923b",
         kShaderWords3.size()},
        {runtime::PipelineKind::kFullSweep,
         "sweep/sweep_full_openmvs_pcg.comp",
         "08dfb3bbdb01815b268c9df499a8e7a1550b5f5750a790d127d549d39710fccd",
         "08c91449b3db423d12e2f93cb47554196b8c8f096d137ad922797d0d0ba2ccfb",
         kShaderWords4.size()},
        {runtime::PipelineKind::kRotateF32,
         "mat_ops/rotate_f32.comp",
         "c43fcf5352d3d19b62941552c71ca2b859dd88b295acc5dd10d1d5321e536875",
         "79d470e058b178fee1fc562e27c9f92a3d720f2423d28064979077fae5fea693",
         kShaderWords5.size()},
        {runtime::PipelineKind::kTransposeF32,
         "mat_ops/transpose_f32.comp",
         "2a077c8a0181f1d8f28b3de6402e9245448d37523167c1686a981113af419dd7",
         "5dfae3d47e84f9d99a1d9ea8855cd5b8b524911b2f37d75a6162ae8966f0c64f",
         kShaderWords6.size()},
        {runtime::PipelineKind::kFlipHorizontalF32,
         "mat_ops/flip_horizontal_f32.comp",
         "536cd7273d9c322d005600549d0e6e0f0138e8cff03681ffc14d1d193d629550",
         "64e37d36d8ea3df31f230c25dfcaa9d25449071a4be7b97e9f37114f689c06b8",
         kShaderWords7.size()},
        {runtime::PipelineKind::kRotateNormalF32,
         "normal_ops/rotate_normal_f32.comp",
         "79a8f655932415a14f0dbf52e1b35839b23a0a85f09f34b9b75e1e0848e1b5bd",
         "9cd47fc696e92f1564309ad7dba395f5b2b126258736c2c47c8a8d1d463401a4",
         kShaderWords8.size()},
        {runtime::PipelineKind::kOpenMvsPcgDepthInitialize,
         "depth_ops/init_depth_openmvs_pcg.comp",
         "6b1016d9dfe2d669d73a8746efe0e83f94886e55febea2fe58f6591c018f5182",
         "b546f066db24189b6e3ab1afb0d4a8230add1d74a0d4df210f6b8b75799add86",
         kShaderWords9.size()},
        {runtime::PipelineKind::kRotateU32,
         "mat_ops/rotate_u32.comp",
         "aed3b6a644898a3255828b58e5a7d0a1a16aad6fa2324dd6396a2623fc003d16",
         "c9cd296fbfd321fdd3cb67fcb007624fd9692451a1ce93d3e023ccca994a472a",
         kShaderWords10.size()},
    }};

constexpr runtime::ShaderBundle kCanonicalBundle = {{
    {{runtime::PipelineKind::kReferenceFilter, kShaderWords0.data(),
      kShaderWords0.size(), kFrozenShaderManifest[0].source_sha256},
     {runtime::PipelineKind::kOpenMvsPcgInitialize, kShaderWords1.data(),
      kShaderWords1.size(), kFrozenShaderManifest[1].source_sha256},
     {runtime::PipelineKind::kNormalInitialize, kShaderWords2.data(),
      kShaderWords2.size(), kFrozenShaderManifest[2].source_sha256},
     {runtime::PipelineKind::kInitialCost, kShaderWords3.data(),
      kShaderWords3.size(), kFrozenShaderManifest[3].source_sha256},
     {runtime::PipelineKind::kFullSweep, kShaderWords4.data(),
      kShaderWords4.size(), kFrozenShaderManifest[4].source_sha256},
     {runtime::PipelineKind::kRotateF32, kShaderWords5.data(),
      kShaderWords5.size(), kFrozenShaderManifest[5].source_sha256},
     {runtime::PipelineKind::kTransposeF32, kShaderWords6.data(),
      kShaderWords6.size(), kFrozenShaderManifest[6].source_sha256},
     {runtime::PipelineKind::kFlipHorizontalF32, kShaderWords7.data(),
      kShaderWords7.size(), kFrozenShaderManifest[7].source_sha256},
     {runtime::PipelineKind::kRotateNormalF32, kShaderWords8.data(),
      kShaderWords8.size(), kFrozenShaderManifest[8].source_sha256},
     {runtime::PipelineKind::kOpenMvsPcgDepthInitialize, kShaderWords9.data(),
      kShaderWords9.size(), kFrozenShaderManifest[9].source_sha256},
     {runtime::PipelineKind::kRotateU32, kShaderWords10.data(),
      kShaderWords10.size(), kFrozenShaderManifest[10].source_sha256}}}};

}  // namespace

const std::array<FrozenShaderIdentity, runtime::kShaderCount> &
FrozenShaderManifest() noexcept {
  return kFrozenShaderManifest;
}

const runtime::ShaderBundle &CanonicalShaderBundle() noexcept {
  return kCanonicalBundle;
}

}  // namespace pocketworld::official_dense::vulkan::shader_bundle
