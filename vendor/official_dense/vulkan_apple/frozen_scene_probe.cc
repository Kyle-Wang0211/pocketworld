// Copyright (c) 2026, PocketWorld contributors.
// SPDX-License-Identifier: BSD-3-Clause

#include "frozen_scene_probe.h"

#include <algorithm>
#include <array>
#include <cerrno>
#include <chrono>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <cstdio>
#include <filesystem>
#include <limits>
#include <memory>
#include <string>
#include <vector>

#include "frozen_scene_loader.h"
#include "diagnostic_map_export.h"
#include "moltenvk_loader.h"
#include "../vulkan_batch_executor/batch_executor.h"
#include "../vulkan_host/dispatch_plan.h"
#include "../vulkan_resource_arena/resource_arena.h"
#include "../vulkan_shader_bundle/shader_bundle.h"
#include "../workspace_io/workspace_io.h"

namespace pocketworld::official_dense::vulkan {
namespace {

namespace arena = resource_arena;
namespace executor = batch_executor;
namespace shader = shader_bundle;
namespace fs = std::filesystem;

constexpr std::size_t kReferenceSlot = 0U;
constexpr float kDegreesToRadians = 0.01745329251994329577F;

struct ProbeTotals final {
  std::size_t requested_references = 0U;
  std::size_t completed_photometric_references = 0U;
  std::size_t completed_geometric_references = 0U;
  std::size_t recorded_plan_steps = 0U;
  std::size_t dispatch_count = 0U;
  std::size_t partition_submit_count = 0U;
  std::size_t queue_submit_count = 0U;
  std::uint64_t execution_milliseconds = 0U;
  std::uint64_t peak_device_local_bytes = 0U;
  std::uint64_t peak_host_upload_bytes = 0U;
  std::uint64_t peak_host_readback_bytes = 0U;
  std::uint64_t peak_host_values_bytes = 0U;
  std::uint64_t peak_planned_bytes = 0U;
};

struct PreparedImage final {
  arena::ResourceArenaImageInput input{};
  std::vector<std::uint32_t> reference;
  std::vector<std::uint32_t> source_gray_u32;
  std::vector<std::uint8_t> source_gray_u8;
  std::vector<runtime::CameraCalibrationInput> source_cameras;
  std::vector<arena::SourceResourceRef> sources;
  // [BATCH-REF 2026-08-31] 融合批:N 个 reference 各自的标定。
  // input.batch_calibrations 指向这里,生命周期必须与 PreparedImage 同。
  std::vector<runtime::CalibrationBuildInput> batch_calibrations;
  std::vector<arena::SourceResourceRef> batch_sources;
};

// [BATCH-REF 2026-08-30] 一次 dispatch 覆盖的 reference 数。
// arena 的 batch_count 与 runtime 的 grid.y 必须取自**同一处**,
// 两边各解析一次 env 迟早会走偏。
std::uint32_t ProbeBatchCount() noexcept {
  static const std::uint32_t value = []() -> std::uint32_t {
    if (const char* const raw = std::getenv("PW_DENSE_BATCH_N")) {
      const long parsed = std::strtol(raw, nullptr, 10);
      if (parsed >= 1 && parsed <= 16)
        return static_cast<std::uint32_t>(parsed);
    }
    return 1U;
  }();
  return value;
}

bool ParseReferenceSlot(const char* const text,
                        const std::size_t limit,
                        std::size_t* const slot) noexcept {
  if (text == nullptr || text[0] == '\0' || slot == nullptr || limit == 0U) {
    return false;
  }
  errno = 0;
  char* end = nullptr;
  const unsigned long long value = std::strtoull(text, &end, 10);
  if (errno != 0 || end == text || end == nullptr || end[0] != '\0' ||
      value >= limit) {
    return false;
  }
  *slot = static_cast<std::size_t>(value);
  return true;
}

runtime::CameraCalibrationInput Camera(
    const FrozenSceneImage& image) noexcept {
  return {image.K, image.R, image.T};
}

PatchPC Patch(const FrozenSceneImage& image,
              const std::uint32_t source_count) noexcept {
  PatchPC patch{};
  patch.width = image.width;
  patch.height = image.height;
  patch.num_sources = source_count;
  patch.workspace_max_dim = std::max(image.width, image.height);
  patch.source_width = image.width;
  patch.source_height = image.height;
  patch.perturbation = 0.5F;
  patch.depth_min = image.depth_min;
  patch.depth_max = image.depth_max;
  patch.num_samples = 15;
  patch.sigma_spatial = 5.0F;
  patch.sigma_color = 0.2F;
  patch.ncc_sigma = 0.6F;
  patch.min_triangulation_angle_rad = 1.0F * kDegreesToRadians;
  patch.incident_angle_sigma = 0.9F;
  patch.prev_sel_prob_weight = 0.9F;
  patch.geom_consistency_regularizer = 0.3F;
  patch.geom_consistency_max_cost = 3.0F;
  patch.filter_min_ncc = 0.1F;
  patch.filter_min_triangulation_angle_rad = 3.0F * kDegreesToRadians;
  patch.filter_min_num_consistent = 2;
  patch.filter_geom_consistency_max_cost = 1.0F;
  return patch;
}

fs::path GrayPath(const fs::path& root, const FrozenSceneImage& image) {
  return root / "gray_pgm" /
         fs::path(image.image_name).replace_extension(".pgm").filename();
}

bool LoadPixels(const fs::path& root,
                const FrozenSceneImage& image,
                std::vector<std::uint8_t>* out,
                std::string* detail) noexcept {
  return LoadFrozenGrayPgm(GrayPath(root, image), image.width, image.height,
                           out, detail);
}

const char* PhaseName(const PlanPhase phase) noexcept {
  switch (phase) {
    case PlanPhase::kPhotometricOnly:
      return "photometric";
    case PlanPhase::kGeometricOnly:
      return "geometric";
    case PlanPhase::kFull:
      return "full";
  }
  return "invalid";
}

bool LoadPersistedPhotometricState(
    const fs::path& workspace_root,
    const FrozenSceneImage& image,
    FloatMatrix* const depth,
    FloatMatrix* const normal,
    std::string* const detail) noexcept {
  if (depth == nullptr || image.image_name.empty() ||
      fs::path(image.image_name).filename() != fs::path(image.image_name)) {
    if (detail != nullptr) *detail = "invalid persisted photometric request";
    return false;
  }
  try {
    const fs::path stereo = workspace_root / "stereo";
    const std::string filename = image.image_name + ".photometric.bin";
    const Status depth_status = ReadFloatMatrix(
        stereo / "depth_maps" / filename, depth);
    if (!depth_status.ok()) {
      if (detail != nullptr) *detail = depth_status.message;
      return false;
    }
    if (depth->width != image.width || depth->height != image.height ||
        depth->depth != 1U) {
      if (detail != nullptr) *detail = "persisted photometric depth shape mismatch";
      return false;
    }
    if (normal != nullptr) {
      const Status normal_status = ReadFloatMatrix(
          stereo / "normal_maps" / filename, normal);
      if (!normal_status.ok()) {
        if (detail != nullptr) *detail = normal_status.message;
        return false;
      }
      if (normal->width != image.width || normal->height != image.height ||
          normal->depth != 3U) {
        if (detail != nullptr) {
          *detail = "persisted photometric normal shape mismatch";
        }
        return false;
      }
    }
    if (detail != nullptr) detail->clear();
    return true;
  } catch (...) {
    if (detail != nullptr) *detail = "persisted photometric read threw";
    return false;
  }
}

bool PrepareFusedBatch(const fs::path& root,
                       const FrozenScene& scene,
                       const std::vector<std::size_t>& slots,
                       const PlanPhase phase,
                       const float* source_depth_f32,
                       std::size_t source_depth_f32_count,
                       const float* reference_depth_f32,
                       std::size_t reference_depth_f32_count,
                       const float* reference_normal_f32,
                       std::size_t reference_normal_f32_count,
                       PreparedImage* prepared,
                       arena::ResourceArenaImageInput* input,
                       std::string* detail) noexcept;

bool PrepareInputsMulti(const fs::path& root,
                        const FrozenScene& scene,
                        const std::vector<std::size_t>& slots,
                        const PlanPhase phase,
                        const float* source_depth_f32,
                        std::size_t source_depth_f32_count,
                        const float* reference_depth_f32,
                        std::size_t reference_depth_f32_count,
                        const float* reference_normal_f32,
                        std::size_t reference_normal_f32_count,
                        std::vector<PreparedImage>* prepared,
                        std::vector<arena::ResourceArenaImageInput>* inputs,
                        std::string* detail) noexcept;

// [BATCH-REF 2026-08-31] 融合批:把 N 个 reference 拼成**一个** arena 输入,
// 一次 dispatch 用 gl_WorkGroupID.y 覆盖全部 N(A 方案)。
//
// 与 PrepareInputsMulti 的区别:那个是 N 个**独立** arena(B 方案交错,
// 实测零加速,因为 MoltenVK 把 compute encoder 串行化了);这里是 1 个
// arena、N 个平面。
//
// 拼接顺序必须与 shader 的 stride 约定逐字对应:
//   reference_u32 : [ref0 的 W*H][ref1 的 W*H]...          ← PixelIndex()
//   source_gray_* : [ref0 的 S 个源][ref1 的 S 个源]...     ← SourceLayer()
//   batch_calib   : 每 ref 一份,arena 散布成 [rotation][ref] ← PoseIndex()
// num_sources 仍是**每 reference** 的源数(它是 shader 的 stride),不乘 N。
bool PrepareFusedBatch(const fs::path& root,
                       const FrozenScene& scene,
                       const std::vector<std::size_t>& slots,
                       const PlanPhase phase,
                       const float* const source_depth_f32,
                       const std::size_t source_depth_f32_count,
                       const float* const reference_depth_f32,
                       const std::size_t reference_depth_f32_count,
                       const float* const reference_normal_f32,
                       const std::size_t reference_normal_f32_count,
                       PreparedImage* const prepared,
                       arena::ResourceArenaImageInput* const input,
                       std::string* const detail) noexcept {
  if (prepared == nullptr || input == nullptr || slots.empty() ||
      scene.images.empty()) {
    if (detail != nullptr) *detail = "invalid fused batch request";
    return false;
  }
  const FrozenSceneImage& first = scene.images[slots[0]];
  const std::size_t source_count = first.source_indices.size();
  if (source_count == 0U || source_count > 32U) {
    if (detail != nullptr) *detail = "fused batch reference has no sources";
    return false;
  }
  for (const std::size_t slot : slots) {
    if (slot >= scene.images.size()) {
      if (detail != nullptr) *detail = "fused batch slot out of range";
      return false;
    }
    const FrozenSceneImage& image = scene.images[slot];
    // 一批里的分辨率与源数必须一致 —— 它们是 push constant 里的 stride,
    // 全批共用一份。冻结场景实测只有 1 种分辨率,这里 fail-closed 兜底。
    if (image.width != first.width || image.height != first.height ||
        image.source_indices.size() != source_count) {
      if (detail != nullptr)
        *detail = "fused batch requires identical dimensions and source count";
      return false;
    }
  }

  PreparedImage& item = *prepared;
  item = PreparedImage{};
  item.source_cameras.reserve(slots.size() * source_count);
  item.batch_calibrations.reserve(slots.size());

  for (const std::size_t slot : slots) {
    const FrozenSceneImage& image = scene.images[slot];
    std::vector<std::uint8_t> pixels;
    if (!LoadPixels(root, image, &pixels, detail)) return false;
    for (const std::uint8_t value : pixels) item.reference.push_back(value);
    for (const std::int32_t source_index : image.source_indices) {
      if (source_index < 0 ||
          static_cast<std::size_t>(source_index) >= scene.images.size()) {
        if (detail != nullptr) *detail = "fused batch source out of range";
        return false;
      }
      const FrozenSceneImage& source =
          scene.images[static_cast<std::size_t>(source_index)];
      std::vector<std::uint8_t> source_pixels;
      if (!LoadPixels(root, source, &source_pixels, detail)) return false;
      item.source_cameras.push_back(Camera(source));
      for (const std::uint8_t value : source_pixels) {
        item.source_gray_u8.push_back(value);
        item.source_gray_u32.push_back(value);
      }
    }
  }

  const std::uint32_t sources_u32 = static_cast<std::uint32_t>(source_count);
  const bool streams_source_depth = source_depth_f32 != nullptr;
  // sources[] 是**每 reference** 的那一份(ValidInput 要求它等于 num_sources);
  // batch_sources 是 N 份首尾相接,喂一致性图的源索引表与逐层拷贝清单。
  //
  // photometric 不读源深度,占位 owner 指向本输入自己(image_slot = 0,
  // image_index = 本输入的 image_index)——ValidInput 会核对这一对。
  // geometric 走外部流入的源深度,owner 是 UINT32_MAX,image_index 则是
  // 那个源自己的真实 index。
  item.batch_sources.reserve(slots.size() * source_count);
  for (const std::size_t slot : slots) {
    const FrozenSceneImage& image = scene.images[slot];
    for (const std::int32_t source_index : image.source_indices) {
      const FrozenSceneImage& source_image =
          scene.images[static_cast<std::size_t>(source_index)];
      item.batch_sources.push_back(
          {streams_source_depth ? UINT32_MAX : 0U,
           streams_source_depth ? static_cast<std::int32_t>(source_image.index)
                                : static_cast<std::int32_t>(first.index),
           source_image.width, source_image.height});
    }
  }
  item.sources.assign(item.batch_sources.begin(),
                      item.batch_sources.begin() + source_count);
  for (std::size_t index = 0U; index < slots.size(); ++index) {
    const FrozenSceneImage& image = scene.images[slots[index]];
    item.batch_calibrations.push_back(
        {Patch(image, sources_u32), Camera(image),
         item.source_cameras.data() + index * source_count, source_count});
  }

  item.input.image_index = static_cast<std::int32_t>(first.index);
  item.input.resources = {first.width,
                          first.height,
                          first.width,
                          first.height,
                          sources_u32,
                          std::max(first.width, first.height),
                          phase,
                          streams_source_depth,
                          reference_depth_f32 != nullptr,
                          static_cast<std::uint64_t>(slots.size())};
  item.input.calibration = item.batch_calibrations[0];
  item.input.batch_calibrations = item.batch_calibrations.data();
  item.input.batch_calibration_count = item.batch_calibrations.size();
  item.input.reference_u32 = item.reference.data();
  item.input.reference_u32_count = item.reference.size();
  item.input.source_gray_u32 = item.source_gray_u32.data();
  item.input.source_gray_u32_count = item.source_gray_u32.size();
  item.input.source_gray_u8 = item.source_gray_u8.data();
  item.input.source_gray_u8_count = item.source_gray_u8.size();
  item.input.sources = item.sources.data();
  item.input.source_count = item.sources.size();
  item.input.batch_sources = item.batch_sources.data();
  item.input.batch_source_count = item.batch_sources.size();
  item.input.source_depth_f32 = source_depth_f32;
  item.input.source_depth_f32_count = source_depth_f32_count;
  item.input.reference_depth_f32 = reference_depth_f32;
  item.input.reference_depth_f32_count = reference_depth_f32_count;
  item.input.reference_normal_f32 = reference_normal_f32;
  item.input.reference_normal_f32_count = reference_normal_f32_count;
  if (reference_depth_f32 != nullptr) {
    item.input.reference_depth_content_identity = 150000U + first.index;
    item.input.reference_normal_content_identity = 160000U + first.index;
  }
  // identity 沿用本文件既有的数值约定(见 PrepareInputsMulti),
  // 融合批用 first.index 作基,批内容不同 ⇒ 基值不同即可区分。
  item.input.reference_content_identity = 100000U + first.index;
  item.input.source_depth_content_identity = 200000U + first.index;
  item.input.source_gray_content_identity = 300000U + first.index;
  item.input.pose_content_identities = {
      400000U + first.index * 4U, 400001U + first.index * 4U,
      400002U + first.index * 4U, 400003U + first.index * 4U};
  *input = item.input;
  return true;
}

// 单 reference 包装:保持既有调用点零改动。
bool PrepareInputs(const fs::path& root,
                   const FrozenScene& scene,
                   const std::size_t reference_slot,
                   const PlanPhase phase,
                   const float* const source_depth_f32,
                   const std::size_t source_depth_f32_count,
                   const float* const reference_depth_f32,
                   const std::size_t reference_depth_f32_count,
                   const float* const reference_normal_f32,
                   const std::size_t reference_normal_f32_count,
                   std::vector<PreparedImage>* prepared,
                   std::vector<arena::ResourceArenaImageInput>* inputs,
                   std::string* detail) noexcept {
  return PrepareInputsMulti(root, scene, {reference_slot}, phase,
                            source_depth_f32, source_depth_f32_count,
                            reference_depth_f32, reference_depth_f32_count,
                            reference_normal_f32, reference_normal_f32_count,
                            prepared, inputs, detail);
}

// [INTERLEAVE 2026-08-30] 批处理入口:slots 里每一项是一个**独立的
// PatchMatch 状态**(不是 source —— 见下方原注释)。N>1 时 dispatch plan
// 走交错形态,N 个 reference 的 sweep 并排在同一个 barrier 前,把
// workgroup 数从 63 抬到 N×63,填上 Metal 微基准量到的那 85% 闲置。
bool PrepareInputsMulti(const fs::path& root,
                   const FrozenScene& scene,
                   const std::vector<std::size_t>& slots,
                   const PlanPhase phase,
                   const float* const source_depth_f32,
                   const std::size_t source_depth_f32_count,
                   const float* const reference_depth_f32,
                   const std::size_t reference_depth_f32_count,
                   const float* const reference_normal_f32,
                   const std::size_t reference_normal_f32_count,
                   std::vector<PreparedImage>* prepared,
                   std::vector<arena::ResourceArenaImageInput>* inputs,
                   std::string* detail) noexcept {
  if (scene.images.empty() || slots.empty() ||
      prepared == nullptr || inputs == nullptr ||
      ((source_depth_f32 == nullptr) != (source_depth_f32_count == 0U)) ||
      ((reference_depth_f32 == nullptr) !=
       (reference_depth_f32_count == 0U)) ||
      ((reference_normal_f32 == nullptr) !=
       (reference_normal_f32_count == 0U)) ||
      ((reference_depth_f32 == nullptr) !=
       (reference_normal_f32 == nullptr)) ||
      (phase == PlanPhase::kPhotometricOnly &&
       (source_depth_f32 != nullptr || reference_depth_f32 != nullptr)) ||
      (phase == PlanPhase::kGeometricOnly &&
       (source_depth_f32 == nullptr || reference_depth_f32 == nullptr)) ||
      (phase == PlanPhase::kFull && reference_depth_f32 != nullptr)) {
    return false;
  }
  for (const std::size_t slot : slots) {
    if (slot >= scene.images.size()) return false;
  }
  const FrozenSceneImage& reference = scene.images[slots[0]];
  const std::size_t reference_pixels =
      static_cast<std::size_t>(reference.width) * reference.height;
  if (reference_depth_f32 != nullptr &&
      (reference_depth_f32_count != reference_pixels ||
       reference_normal_f32_count != reference_pixels * 3U)) {
    return false;
  }
  const std::size_t source_count = reference.source_indices.size();
  if (source_count == 0U || source_count > 32U) return false;

  // This is deliberately a one-reference arena. In COLMAP's first pass the
  // selected sources are input images only; they are not independent
  // PatchMatch states. Their photometric maps are generated by later
  // iterations of this same one-reference submission sequence.
  prepared->clear();
  prepared->resize(slots.size());
  inputs->clear();
  inputs->resize(slots.size());
  for (std::size_t slot = 0U; slot < slots.size(); ++slot) {
    PreparedImage& item = prepared->at(slot);
    const FrozenSceneImage& image = scene.images[slots[slot]];
    std::vector<std::uint8_t> pixels;
    if (!LoadPixels(root, image, &pixels, detail)) return false;
    item.reference.reserve(pixels.size());
    for (const std::uint8_t value : pixels) item.reference.push_back(value);

    const std::vector<std::int32_t>& selected_sources = image.source_indices;
    item.source_cameras.reserve(selected_sources.size());
    item.sources.reserve(selected_sources.size());
    for (const std::int32_t source_index : selected_sources) {
      if (source_index < 0 ||
          static_cast<std::size_t>(source_index) >= scene.images.size()) {
        return false;
      }
      const FrozenSceneImage& source = scene.images[static_cast<std::size_t>(source_index)];
      std::vector<std::uint8_t> source_pixels;
      if (!LoadPixels(root, source, &source_pixels, detail)) return false;
      item.source_cameras.push_back(Camera(source));
      // A photometric-only pass never reads source depth, so its placeholder
      // owner is the one active arena. The full pass instead streams the
      // already completed official source maps in this exact source order.
      //
      // [INTERLEAVE 2026-08-30] 🔴 photometric 的占位 owner 必须指向
      // **本 slot 自己**,不能写死 0。ValidInput 会核对
      //   sources[i].image_index == all_inputs[sources[i].image_slot].image_index
      // 单 reference 时 slot 恒为 0 且 image_index 就是自己,写死 0 恰好自洽;
      // 批处理时 slot 1 若仍指向 0,就会拿 slot 0 的 image_index 来比,必然失败
      // (实测:N=2 报 "resource arena validation failed")。
      item.sources.push_back({
          source_depth_f32 == nullptr
              ? static_cast<std::uint32_t>(slot)
              : UINT32_MAX,
          source_depth_f32 == nullptr
              ? static_cast<std::int32_t>(image.index)
              : static_cast<std::int32_t>(source.index),
          source.width,
          source.height});
      for (const std::uint8_t value : source_pixels) {
        item.source_gray_u8.push_back(value);
        item.source_gray_u32.push_back(value);
      }
    }
    const std::uint32_t image_source_count =
        static_cast<std::uint32_t>(item.sources.size());
    item.input.image_index = static_cast<std::int32_t>(image.index);
    // [BATCH-REF 2026-08-30] PW_DENSE_BATCH_N=N ⇒ 一次 dispatch 覆盖 N 个
    // reference(gl_WorkGroupID.y 当批索引)。当前 N 个槽装同一份输入,
    // 于是 N 个输出平面每一个都必须与单跑基线逐字节相同——这既是验收,
    // 也让加速比数字保持真实(工作量与访存形态与真跑 N 个 reference 一致)。
    item.input.resources = {image.width, image.height, image.width,
                            image.height, image_source_count,
                            std::max(image.width, image.height),
                            phase, source_depth_f32 != nullptr,
                            reference_depth_f32 != nullptr,
                            // 融合批走 PrepareFusedBatch;这条路径永远是单份。
                            1U};
    item.input.calibration = {Patch(image, image_source_count), Camera(image),
                              item.source_cameras.data(),
                              item.source_cameras.size()};
    item.input.reference_u32 = item.reference.data();
    item.input.reference_u32_count = item.reference.size();
    item.input.source_gray_u32 = item.source_gray_u32.data();
    item.input.source_gray_u32_count = item.source_gray_u32.size();
    item.input.source_gray_u8 = item.source_gray_u8.data();
    item.input.source_gray_u8_count = item.source_gray_u8.size();
    item.input.source_depth_f32 = source_depth_f32;
    item.input.source_depth_f32_count = source_depth_f32_count;
    item.input.reference_depth_f32 = reference_depth_f32;
    item.input.reference_depth_f32_count = reference_depth_f32_count;
    item.input.reference_normal_f32 = reference_normal_f32;
    item.input.reference_normal_f32_count = reference_normal_f32_count;
    item.input.reference_content_identity = 100000U + image.index;
    item.input.reference_depth_content_identity = 150000U + image.index;
    item.input.reference_normal_content_identity = 160000U + image.index;
    item.input.source_depth_content_identity = 200000U + image.index;
    item.input.source_gray_content_identity = 300000U + image.index;
    item.input.pose_content_identities = {
        400000U + image.index * 4U, 400001U + image.index * 4U,
        400002U + image.index * 4U, 400003U + image.index * 4U};
    item.input.sources = item.sources.data();
    item.input.source_count = item.sources.size();
    inputs->at(slot) = item.input;
  }
  return true;
}

bool FindImageSlot(const FrozenScene& scene,
                   const std::int32_t image_index,
                   std::size_t* const slot) noexcept {
  if (image_index < 0 || slot == nullptr) return false;
  for (std::size_t candidate = 0U; candidate < scene.images.size(); ++candidate) {
    if (scene.images[candidate].index ==
        static_cast<std::uint32_t>(image_index)) {
      *slot = candidate;
      return true;
    }
  }
  return false;
}

bool ExecuteReference(
    const fs::path& root,
    const FrozenScene& scene,
    const std::size_t reference_slot,
    const PlanPhase phase,
    const float* const source_depth_f32,
    const std::size_t source_depth_f32_count,
    const float* const reference_depth_f32,
    const std::size_t reference_depth_f32_count,
    const float* const reference_normal_f32,
    const std::size_t reference_normal_f32_count,
    VulkanHost* const host,
    const ExternalLoader& loader,
    const fs::path& output_root,
    const bool export_full_maps,
    std::vector<float>* const photometric_depth,
    std::vector<float>* const photometric_normal,
    ProbeTotals* const totals,
    runtime::RecordResult* const last_record,
    std::string* const detail) noexcept {
  if (host == nullptr || totals == nullptr || last_record == nullptr ||
      reference_slot >= scene.images.size()) {
    return false;
  }
  try {
    std::vector<PreparedImage> prepared;
    std::vector<arena::ResourceArenaImageInput> inputs;
    // [BATCH-REF 2026-08-31] N>1 且 photometric ⇒ 融合批:一个 arena、
    // N 个 reference 平面。默认取 reference_slot 起的连续 N 帧
    // (**N 份不同的输入**);PW_DENSE_BATCH_SAME=1 则装 N 份同一帧,
    // 那是回归用的形态 —— N 个输出平面必须全部等于单跑基线。
    const std::uint32_t reference_batch = ProbeBatchCount();
    if (reference_batch > 1U) {
      const char* const same_raw = std::getenv("PW_DENSE_BATCH_SAME");
      const bool same = same_raw != nullptr && same_raw[0] == '1';
      std::vector<std::size_t> slots;
      slots.reserve(reference_batch);
      for (std::uint32_t index = 0U; index < reference_batch; ++index) {
        const std::size_t slot =
            same ? reference_slot
                 : (reference_slot + index) % scene.images.size();
        slots.push_back(slot);
      }
      prepared.resize(1U);
      inputs.resize(1U);
      if (!PrepareFusedBatch(root, scene, slots, phase, source_depth_f32,
                             source_depth_f32_count, reference_depth_f32,
                             reference_depth_f32_count, reference_normal_f32,
                             reference_normal_f32_count, &prepared[0],
                             &inputs[0], detail)) {
        return false;
      }
    } else if (!PrepareInputs(root, scene, reference_slot, phase,
                              source_depth_f32, source_depth_f32_count,
                              reference_depth_f32, reference_depth_f32_count,
                              reference_normal_f32, reference_normal_f32_count,
                              &prepared, &inputs, detail)) {
      return false;
    }
    arena::ResourceArenaPlan audit_plan;
    arena::ResourceArenaMemorySummary memory;
    if (!arena::BuildResourceArenaPlan(inputs[0].resources, &audit_plan) ||
        !arena::SummarizeResourceArenaMemory(audit_plan, &memory)) {
      if (detail != nullptr) *detail = "resource memory audit failed";
      return false;
    }
    totals->peak_device_local_bytes =
        std::max(totals->peak_device_local_bytes, memory.device_local_bytes);
    totals->peak_host_upload_bytes =
        std::max(totals->peak_host_upload_bytes, memory.host_upload_bytes);
    totals->peak_host_readback_bytes =
        std::max(totals->peak_host_readback_bytes,
                 memory.host_readback_bytes);
    totals->peak_host_values_bytes =
        std::max(totals->peak_host_values_bytes, memory.host_values_bytes);
    totals->peak_planned_bytes =
        std::max(totals->peak_planned_bytes, memory.total_bytes);
    arena::VulkanHostResourceAllocationProvider provider(host);
    arena::ResourceArenaBatch batch;
    const FrozenSceneImage& reference = scene.images[reference_slot];
    std::fprintf(stderr,
                 "{\"probe_stage\":\"before_arena\",\"reference_slot\":%zu,"
                 "\"reference_index\":%u,\"width\":%u,\"height\":%u,"
                 "\"sources\":%zu,\"phase\":\"%s\","
                 "\"device_local_bytes\":%llu,\"host_upload_bytes\":%llu,"
                 "\"host_readback_bytes\":%llu,\"host_values_bytes\":%llu,"
                 "\"planned_bytes\":%llu}\n",
                 reference_slot, reference.index, reference.width,
                 reference.height, inputs[0].source_count,
                 PhaseName(phase),
                 static_cast<unsigned long long>(memory.device_local_bytes),
                 static_cast<unsigned long long>(memory.host_upload_bytes),
                 static_cast<unsigned long long>(memory.host_readback_bytes),
                 static_cast<unsigned long long>(memory.host_values_bytes),
                 static_cast<unsigned long long>(memory.total_bytes));
    std::fflush(stderr);
    if (!arena::BuildResourceArenaBatch(inputs.data(), inputs.size(), &provider,
                                        &batch, detail)) {
      return false;
    }
    std::fprintf(stderr,
                 "{\"probe_stage\":\"before_submit\","
                 "\"reference_index\":%u,\"phase\":\"%s\","
                 "\"expected_queue_submits\":%zu}\n",
                 reference.index,
                 PhaseName(phase),
                 runtime::FrozenReferenceQueueSubmitCount(
                     reference.width, reference.height, phase));
    std::fflush(stderr);
    const NativeHandles native = host->native_handles();
    executor::BatchExecuteRequest request;
    request.arena = &batch;
    request.native = {native.instance, native.device, native.command_buffer,
                      native.queue, loader.get_instance_proc_addr};
    request.shaders = shader::CanonicalShaderBundle();
    request.plan_options = {5U, phase != PlanPhase::kPhotometricOnly,
                            phase != PlanPhase::kPhotometricOnly, phase};
    // [BATCH-REF] 必须与 ResourceArenaInput::batch_count 一致(同一个 env)。
    request.batch_count = ProbeBatchCount();
    const auto started = std::chrono::steady_clock::now();
    *last_record = executor::ExecuteResourceArenaBatchForDiagnostic(request);
    const std::uint64_t elapsed_ms = static_cast<std::uint64_t>(
        std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now() - started)
            .count());
    totals->recorded_plan_steps += last_record->recorded_plan_steps;
    totals->dispatch_count += last_record->dispatch_count;
    totals->partition_submit_count += last_record->partition_submit_count;
    totals->queue_submit_count += last_record->queue_submit_count;
    totals->execution_milliseconds += elapsed_ms;
    std::fprintf(stderr,
                 "{\"probe_stage\":\"after_submit\","
                 "\"reference_index\":%u,\"phase\":\"%s\","
                 "\"runtime_status\":%u,\"elapsed_ms\":%llu,"
                 "\"partition_submits\":%zu,\"queue_submits\":%zu}\n",
                 reference.index,
                 PhaseName(phase),
                 static_cast<unsigned int>(last_record->status),
                 static_cast<unsigned long long>(elapsed_ms),
                 last_record->partition_submit_count,
                 last_record->queue_submit_count);
    std::fflush(stderr);
    const std::size_t expected_queue_submits =
        runtime::FrozenReferenceQueueSubmitCount(reference.width,
                                                 reference.height, phase);
    if (last_record->recorded() &&
        last_record->queue_submit_count != expected_queue_submits) {
      if (detail != nullptr) *detail = "queue submit accounting mismatch";
      return false;
    }
    arena::DiagnosticImageReadback readback;
    if (!last_record->recorded() ||
        !batch.DiagnosticReadbackForImage(0U, &readback)) {
      if (detail != nullptr) *detail = last_record->detail;
      return false;
    }
    if (photometric_depth != nullptr) {
      const std::size_t pixel_count =
          static_cast<std::size_t>(readback.width) * readback.height;
      photometric_depth->assign(readback.photometric_depth,
                                readback.photometric_depth + pixel_count);
    }
    if (photometric_normal != nullptr) {
      const std::size_t value_count =
          static_cast<std::size_t>(readback.width) * readback.height * 3U;
      photometric_normal->assign(readback.photometric_normal,
                                 readback.photometric_normal + value_count);
    }
    arena::DiagnosticImageReadback export_readback = readback;
    if (export_full_maps) {
      export_readback.photometric_depth = reference_depth_f32;
      export_readback.photometric_normal = reference_normal_f32;
    }
    const bool wrote = export_full_maps
        ? WriteDiagnosticColmapMaps(output_root, reference.image_name,
                                    export_readback, detail)
        : WriteDiagnosticPhotometricMaps(output_root, reference.image_name,
                                          readback, detail);
    if (!wrote) return false;
    // [BATCH-REF 2026-08-30] 批处理时回读缓冲里是 N 个平面首尾相接,
    // 上面只写了第 0 个。把 1..N-1 也写出来 —— 验收要求**每一个** reference
    // 的产物都与单跑逐字节相同,只验第 0 个等于没验跨 reference 的越界。
    // (法线索引的那个 bug 就是 reference 1 越界砸回 reference 0 才暴露的。)
    {
      const std::uint32_t batch = ProbeBatchCount();
      const std::size_t plane =
          static_cast<std::size_t>(readback.width) * readback.height;
      for (std::uint32_t slot = 1U; slot < batch; ++slot) {
        // 🔴 基准必须是 export_readback,不是 readback:geometric 导出时
        // photometric 的两份来自**流入的输入**(reference_depth/normal_f32),
        // 不是回读缓冲。用错基准会让 WriteDiagnosticColmapMaps 拿到空指针,
        // 报 "incomplete diagnostic readback"。
        arena::DiagnosticImageReadback extra = export_readback;
        if (export_readback.photometric_depth != nullptr)
          extra.photometric_depth =
              export_readback.photometric_depth + plane * slot;
        if (export_readback.photometric_normal != nullptr)
          extra.photometric_normal =
              export_readback.photometric_normal + plane * 3U * slot;
        // geometric 的三份产物同样按 reference 取片。
        if (readback.geometric_depth != nullptr)
          extra.geometric_depth = readback.geometric_depth + plane * slot;
        if (readback.geometric_normal != nullptr)
          extra.geometric_normal = readback.geometric_normal + plane * 3U * slot;
        if (readback.geometric_mask != nullptr)
          extra.geometric_mask =
              readback.geometric_mask + plane * readback.source_count * slot;
        if (readback.consistency_graph_values != nullptr &&
            slot < readback.consistency_graph_batch_count) {
          extra.consistency_graph_values =
              readback.consistency_graph_values +
              readback.consistency_graph_value_capacity_per_reference * slot;
          extra.consistency_graph_value_count =
              readback.consistency_graph_value_counts[slot];
        }
        const std::string name =
            reference.image_name + ".ref" + std::to_string(slot);
        const bool extra_wrote =
            export_full_maps
                ? WriteDiagnosticColmapMaps(output_root, name, extra, detail)
                : WriteDiagnosticPhotometricMaps(output_root, name, extra,
                                                 detail);
        if (!extra_wrote) return false;
      }
    }
    if (phase == PlanPhase::kPhotometricOnly) {
      ++totals->completed_photometric_references;
    } else if (phase == PlanPhase::kGeometricOnly) {
      ++totals->completed_geometric_references;
    }
    return true;
  } catch (...) {
    if (detail != nullptr) *detail = "reference execution threw";
    return false;
  }
}

bool HasPersistedPhotometricMaps(
    const fs::path& workspace_root,
    const FrozenSceneImage& image) noexcept {
  try {
    FloatMatrix depth;
    FloatMatrix normal;
    std::string ignored_detail;
    return LoadPersistedPhotometricState(workspace_root, image, &depth,
                                         &normal, &ignored_detail);
  } catch (...) {
    return false;
  }
}

bool HasPersistedGeometricMaps(
    const fs::path& workspace_root,
    const FrozenSceneImage& image) noexcept {
  try {
    const fs::path stereo = workspace_root / "stereo";
    const std::string filename = image.image_name + ".geometric.bin";
    FloatMatrix depth;
    FloatMatrix normal;
    ConsistencyGraph graph;
    const Status depth_status = ReadFloatMatrix(
        stereo / "depth_maps" / filename, &depth);
    const Status normal_status = ReadFloatMatrix(
        stereo / "normal_maps" / filename, &normal);
    const Status graph_status = ReadConsistencyGraph(
        stereo / "consistency_graphs" / filename, &graph);
    return depth_status.ok() && normal_status.ok() && graph_status.ok() &&
           depth.width == image.width && depth.height == image.height &&
           depth.depth == 1U && normal.width == image.width &&
           normal.height == image.height && normal.depth == 3U &&
           graph.width == image.width && graph.height == image.height;
  } catch (...) {
    return false;
  }
}

// [INTERLEAVE 2026-08-30] 批执行 N 个 reference 的 photometric 阶段。
//
// 与 ExecuteReference 的唯一差别:一次准备 N 个 PatchMatch 状态,让
// CreateDispatchPlan(N) 走交错形态。每个 reference 的步骤序列、rotation
// 推进、RNG、资源都与单独跑时逐字相同,只是它们的 sweep 在时间上并排,
// 共享同一个 barrier ⇒ 输出必然逐字节相同,由 cmp 对拍验证。
bool ExecuteReferenceBatch(
    const fs::path& root,
    const FrozenScene& scene,
    const std::vector<std::size_t>& slots,
    VulkanHost* const host,
    const ExternalLoader& loader,
    const fs::path& output_root,
    ProbeTotals* const totals,
    runtime::RecordResult* const last_record,
    std::string* const detail) noexcept {
  if (host == nullptr || totals == nullptr || last_record == nullptr ||
      slots.empty()) {
    return false;
  }
  try {
    std::vector<PreparedImage> prepared;
    std::vector<arena::ResourceArenaImageInput> inputs;
    if (!PrepareInputsMulti(root, scene, slots, PlanPhase::kPhotometricOnly,
                            nullptr, 0U, nullptr, 0U, nullptr, 0U,
                            &prepared, &inputs, detail)) {
      return false;
    }
    arena::ResourceArenaPlan audit_plan;
    arena::ResourceArenaMemorySummary memory;
    if (!arena::BuildResourceArenaPlan(inputs[0].resources, &audit_plan) ||
        !arena::SummarizeResourceArenaMemory(audit_plan, &memory)) {
      if (detail != nullptr) *detail = "resource memory audit failed";
      return false;
    }
    // 峰值按 N 份计
    totals->peak_planned_bytes =
        std::max(totals->peak_planned_bytes, memory.total_bytes * slots.size());
    std::fprintf(stderr,
                 "{\"probe_stage\":\"batch_before_arena\",\"batch_size\":%zu,"
                 "\"planned_bytes_total\":%llu}\n",
                 slots.size(),
                 static_cast<unsigned long long>(memory.total_bytes *
                                                 slots.size()));
    std::fflush(stderr);
    arena::VulkanHostResourceAllocationProvider provider(host);
    arena::ResourceArenaBatch batch;
    if (!arena::BuildResourceArenaBatch(inputs.data(), inputs.size(),
                                        &provider, &batch, detail)) {
      return false;
    }
    const NativeHandles native = host->native_handles();
    executor::BatchExecuteRequest request;
    request.arena = &batch;
    request.native = {native.instance, native.device, native.command_buffer,
                      native.queue, loader.get_instance_proc_addr};
    request.shaders = shader::CanonicalShaderBundle();
    request.plan_options = {5U, false, false, PlanPhase::kPhotometricOnly};
    const auto started = std::chrono::steady_clock::now();
    *last_record = executor::ExecuteResourceArenaBatchForDiagnostic(request);
    const std::uint64_t elapsed_ms = static_cast<std::uint64_t>(
        std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now() - started).count());
    totals->execution_milliseconds += elapsed_ms;
    std::fprintf(stderr,
                 "{\"probe_stage\":\"batch_after_submit\",\"batch_size\":%zu,"
                 "\"runtime_status\":%u,\"elapsed_ms\":%llu,"
                 "\"per_ref_ms\":%llu,\"queue_submits\":%zu}\n",
                 slots.size(),
                 static_cast<unsigned int>(last_record->status),
                 static_cast<unsigned long long>(elapsed_ms),
                 static_cast<unsigned long long>(elapsed_ms / slots.size()),
                 last_record->queue_submit_count);
    std::fflush(stderr);
    if (!last_record->recorded()) {
      if (detail != nullptr) *detail = last_record->detail;
      return false;
    }
    for (std::size_t i = 0; i < slots.size(); ++i) {
      arena::DiagnosticImageReadback readback;
      if (!batch.DiagnosticReadbackForImage(static_cast<std::uint32_t>(i),
                                            &readback)) {
        if (detail != nullptr) *detail = "batch readback failed";
        return false;
      }
      if (!WriteDiagnosticPhotometricMaps(
              output_root, scene.images[slots[i]].image_name, readback,
              detail)) {
        return false;
      }
      ++totals->completed_photometric_references;
    }
    return true;
  } catch (...) {
    if (detail != nullptr) *detail = "batch execution threw";
    return false;
  }
}

bool RunAllPhotometricReferences(
    const fs::path& root,
    const FrozenScene& scene,
    VulkanHost* const host,
    const ExternalLoader& loader,
    const fs::path& output_root,
    ProbeTotals* const totals,
    runtime::RecordResult* const last_record,
    std::string* const detail) noexcept {
  if (host == nullptr || totals == nullptr || last_record == nullptr ||
      scene.images.empty()) {
    if (detail != nullptr) *detail = "invalid all-photometric request";
    return false;
  }
  for (std::size_t reference_slot = 0U;
       reference_slot < scene.images.size(); ++reference_slot) {
    const FrozenSceneImage& reference = scene.images[reference_slot];
    if (HasPersistedPhotometricMaps(output_root, reference)) {
      ++totals->completed_photometric_references;
      std::fprintf(stderr,
                   "{\"probe_stage\":\"photometric_resume_skip\","
                   "\"reference_index\":%u}\n",
                   reference.index);
      std::fflush(stderr);
      continue;
    }
    if (!ExecuteReference(root, scene, reference_slot,
                          PlanPhase::kPhotometricOnly, nullptr, 0U, nullptr,
                          0U, nullptr, 0U, host, loader, output_root, false,
                          nullptr, nullptr, totals, last_record, detail)) {
      return false;
    }
  }
  std::fprintf(stderr,
               "{\"probe_stage\":\"full_scene_photometric_complete\","
               "\"references\":%zu}\n",
               totals->completed_photometric_references);
  std::fflush(stderr);
  return true;
}

bool LoadLayeredSourceDepths(
    const fs::path& workspace_root,
    const FrozenScene& scene,
    const FrozenSceneImage& reference,
    std::vector<float>* const layered_source_depth,
    std::string* const detail) noexcept {
  if (layered_source_depth == nullptr || reference.source_indices.empty()) {
    if (detail != nullptr) *detail = "invalid layered source depth request";
    return false;
  }
  try {
    layered_source_depth->clear();
    const std::size_t pixels =
        static_cast<std::size_t>(reference.width) * reference.height;
    if (pixels > std::numeric_limits<std::size_t>::max() /
                     reference.source_indices.size()) {
      if (detail != nullptr) *detail = "layered source depth size overflow";
      return false;
    }
    const std::size_t expected_values =
        pixels * reference.source_indices.size();
    layered_source_depth->reserve(expected_values);
    for (const std::int32_t source_index : reference.source_indices) {
      std::size_t source_slot = 0U;
      FloatMatrix source_depth;
      if (!FindImageSlot(scene, source_index, &source_slot)) {
        if (detail != nullptr) *detail = "cannot resolve frozen source image";
        return false;
      }
      const FrozenSceneImage& source = scene.images[source_slot];
      if (source.width != reference.width || source.height != reference.height) {
        if (detail != nullptr) {
          *detail = "frozen Vulkan source dimensions differ from reference";
        }
        return false;
      }
      if (!LoadPersistedPhotometricState(workspace_root, source, &source_depth,
                                         nullptr, detail)) {
        return false;
      }
      layered_source_depth->insert(layered_source_depth->end(),
                                   source_depth.values.begin(),
                                   source_depth.values.end());
    }
    if (layered_source_depth->size() != expected_values) {
      if (detail != nullptr) {
        *detail = "source depth dimensions do not match frozen reference";
      }
      return false;
    }
    return true;
  } catch (...) {
    if (detail != nullptr) *detail = "layered source depth load threw";
    return false;
  }
}

bool RunAllGeometricReferences(
    const fs::path& root,
    const FrozenScene& scene,
    VulkanHost* const host,
    const ExternalLoader& loader,
    const fs::path& output_root,
    ProbeTotals* const totals,
    runtime::RecordResult* const last_record,
    std::string* const detail) noexcept {
  if (host == nullptr || totals == nullptr || last_record == nullptr ||
      scene.images.empty()) {
    if (detail != nullptr) *detail = "invalid all-geometric request";
    return false;
  }
  try {
    for (std::size_t reference_slot = 0U;
         reference_slot < scene.images.size(); ++reference_slot) {
      const FrozenSceneImage& reference = scene.images[reference_slot];
      if (HasPersistedGeometricMaps(output_root, reference)) {
        ++totals->completed_geometric_references;
        std::fprintf(stderr,
                     "{\"probe_stage\":\"geometric_resume_skip\","
                     "\"reference_index\":%u}\n",
                     reference.index);
        std::fflush(stderr);
        continue;
      }
      std::vector<float> layered_source_depth;
      if (!LoadLayeredSourceDepths(output_root, scene, reference,
                                   &layered_source_depth, detail)) {
        return false;
      }
      FloatMatrix reference_depth;
      FloatMatrix reference_normal;
      if (!LoadPersistedPhotometricState(output_root, reference,
                                         &reference_depth, &reference_normal,
                                         detail)) {
        return false;
      }
      if (!ExecuteReference(
              root, scene, reference_slot, PlanPhase::kGeometricOnly,
              layered_source_depth.data(), layered_source_depth.size(),
              reference_depth.values.data(), reference_depth.values.size(),
              reference_normal.values.data(), reference_normal.values.size(),
              host, loader, output_root, true, nullptr, nullptr, totals,
              last_record, detail)) {
        return false;
      }
    }
  } catch (...) {
    if (detail != nullptr) *detail = "all-geometric execution threw";
    return false;
  }
  std::fprintf(stderr,
               "{\"probe_stage\":\"full_scene_geometric_complete\","
               "\"references\":%zu}\n",
               totals->completed_geometric_references);
  std::fflush(stderr);
  return true;
}

void SetResult(FrozenSceneProbeResult* out,
               const bool ok,
               const char* stage,
               const runtime::RuntimeStatus status,
               const runtime::RecordResult* record,
               const ProbeTotals* totals,
               const char* detail) noexcept {
  std::snprintf(
      out->json.data(), out->json.size(),
      "{\"ok\":%s,\"stage\":\"%s\",\"runtime_status\":%u,"
      "\"reference_index\":0,\"reference_sources\":10,"
      "\"not_cuda_parity\":true,\"requested_references\":%zu,"
      "\"photometric_references\":%zu,\"geometric_references\":%zu,"
      "\"execution_ms\":%llu,"
      "\"peak_device_local_bytes\":%llu,"
      "\"peak_host_upload_bytes\":%llu,"
      "\"peak_host_readback_bytes\":%llu,"
      "\"peak_host_values_bytes\":%llu,"
      "\"peak_planned_bytes\":%llu,"
      "\"recorded_plan_steps\":%zu,"
      "\"dispatch_count\":%zu,\"partition_submit_count\":%zu,"
      "\"queue_submit_count\":%zu,"
      "\"detail\":\"%s\"}",
      ok ? "true" : "false", stage, static_cast<unsigned int>(status),
      totals == nullptr ? 0U : totals->requested_references,
      totals == nullptr ? 0U : totals->completed_photometric_references,
      totals == nullptr ? 0U : totals->completed_geometric_references,
      static_cast<unsigned long long>(
          totals == nullptr ? 0U : totals->execution_milliseconds),
      static_cast<unsigned long long>(
          totals == nullptr ? 0U : totals->peak_device_local_bytes),
      static_cast<unsigned long long>(
          totals == nullptr ? 0U : totals->peak_host_upload_bytes),
      static_cast<unsigned long long>(
          totals == nullptr ? 0U : totals->peak_host_readback_bytes),
      static_cast<unsigned long long>(
          totals == nullptr ? 0U : totals->peak_host_values_bytes),
      static_cast<unsigned long long>(
          totals == nullptr ? 0U : totals->peak_planned_bytes),
      totals == nullptr
          ? (record == nullptr ? 0U : record->recorded_plan_steps)
          : totals->recorded_plan_steps,
      totals == nullptr ? (record == nullptr ? 0U : record->dispatch_count)
                        : totals->dispatch_count,
      totals == nullptr
          ? (record == nullptr ? 0U : record->partition_submit_count)
          : totals->partition_submit_count,
      totals == nullptr
          ? (record == nullptr ? 0U : record->queue_submit_count)
          : totals->queue_submit_count,
      detail == nullptr ? "" : detail);
  out->ok = ok;
}

}  // namespace

FrozenSceneProbeResult RunFrozenSceneInputProbe(
    const char* const executable_path) noexcept {
  FrozenSceneProbeResult output;
  try {
    if (executable_path == nullptr || executable_path[0] == '\0') {
      SetResult(&output, false, "bundle_path", runtime::RuntimeStatus::kInvalidRequest,
                nullptr, nullptr, "missing executable path");
      return output;
    }
    const fs::path root = fs::path(executable_path).parent_path() / "FrozenB28";
    FrozenScene scene;
    std::string detail;
    if (!LoadFrozenScene(root / "b28_selection.packet", &scene, &detail)) {
      SetResult(&output, false, "fixture_load", runtime::RuntimeStatus::kInvalidRequest,
                nullptr, nullptr, detail.c_str());
      return output;
    }
    if (scene.images.size() <= kReferenceSlot ||
        scene.images[kReferenceSlot].source_indices.empty()) {
      SetResult(&output, false, "input_prepare",
                runtime::RuntimeStatus::kInvalidRequest, nullptr, nullptr,
                "missing frozen reference sources");
      return output;
    }
    const ExternalLoader loader = MoltenVkExternalLoader();
    const CreateOptions options{loader};
    CapabilityReport created;
    std::unique_ptr<VulkanHost> host = VulkanHost::Create(options, &created);
    if (host == nullptr || !created.ready()) {
      SetResult(&output, false, "host_create",
                runtime::RuntimeStatus::kVulkanFunctionUnavailable, nullptr, nullptr,
                created.detail.c_str());
      return output;
    }
    const char* const output_override =
        std::getenv("PW_DENSE_PROBE_OUTPUT_ROOT");
    const char* const home = std::getenv("HOME");
    if ((output_override == nullptr || output_override[0] == '\0') &&
        (home == nullptr || home[0] == '\0')) {
      SetResult(&output, false, "map_export",
                runtime::RuntimeStatus::kInvalidRequest, nullptr, nullptr,
                "missing output root and sandbox home");
      return output;
    }
    const fs::path output_base =
        output_override != nullptr && output_override[0] != '\0'
            ? fs::path(output_override)
            : fs::path(home) / "Documents";
    const fs::path output_root = output_base /
                                 "DenseProbeFrozenB28_full_reference0";
    ProbeTotals totals;
    totals.requested_references = 1U;
    runtime::RecordResult record;
    const char* const requested_mode = std::getenv("PW_DENSE_PROBE_REAL_MODE");
    if (requested_mode != nullptr &&
        std::string(requested_mode) == "photo_ref0") {
      std::vector<float> benchmark_depth;
      const bool completed = ExecuteReference(
          root, scene, kReferenceSlot, PlanPhase::kPhotometricOnly, nullptr,
          0U, nullptr, 0U, nullptr, 0U, host.get(), loader,
          output_base /
              "DenseProbeFrozenB28_fast_benchmark_ref0",
          false, &benchmark_depth, nullptr, &totals, &record, &detail);
      SetResult(&output, completed,
                completed ? "real_input_photo_ref0_benchmark_complete"
                          : "real_input_photo_ref0_benchmark_failed",
                record.status, &record, &totals,
                completed ? record.detail : detail.c_str());
      return output;
    }
    // [INTERLEAVE 2026-08-30] photo_batch:交错批处理 N 个 reference。
    // N 由 PW_DENSE_PROBE_BATCH_SIZE 给(默认 2)。
    // 内存 = N × 3.31GB,调用方负责不超机器上限。
    if (requested_mode != nullptr &&
        std::string(requested_mode) == "photo_batch") {
      std::size_t batch_size = 2U;
      if (const char* const raw = std::getenv("PW_DENSE_PROBE_BATCH_SIZE")) {
        const long parsed = std::strtol(raw, nullptr, 10);
        if (parsed >= 1 && static_cast<std::size_t>(parsed) <=
                               scene.images.size()) {
          batch_size = static_cast<std::size_t>(parsed);
        }
      }
      std::vector<std::size_t> slots;
      slots.reserve(batch_size);
      for (std::size_t i = 0; i < batch_size; ++i) slots.push_back(i);
      totals.requested_references = slots.size();
      const bool completed = ExecuteReferenceBatch(
          root, scene, slots, host.get(), loader,
          output_base / "DenseProbeFrozenB28_batch", &totals, &record,
          &detail);
      SetResult(&output, completed,
                completed ? "photo_batch_complete" : "photo_batch_failed",
                record.status, &record, &totals,
                completed ? record.detail : detail.c_str());
      return output;
    }
    if (requested_mode != nullptr &&
        std::string(requested_mode) == "full_scene") {
      const fs::path full_scene_output = output_base /
          "DenseProbeFrozenB28_full_scene";
      totals.requested_references = scene.images.size();
      if (!RunAllPhotometricReferences(root, scene, host.get(), loader,
                                       full_scene_output, &totals, &record,
                                       &detail)) {
        SetResult(&output, false, "full_scene_photometric_failed",
                  record.status, &record, &totals, detail.c_str());
        return output;
      }
      const bool completed = RunAllGeometricReferences(
          root, scene, host.get(), loader, full_scene_output, &totals,
          &record, &detail);
      SetResult(&output, completed,
                completed ? "full_scene_geometric_complete"
                          : "full_scene_geometric_failed",
                record.status, &record, &totals,
                completed ? record.detail : detail.c_str());
      return output;
    }
    if (requested_mode != nullptr &&
        (std::string(requested_mode) == "photo_ref" ||
         std::string(requested_mode) == "geo_ref")) {
      std::size_t requested_slot = 0U;
      if (!ParseReferenceSlot(std::getenv("PW_DENSE_PROBE_REFERENCE_SLOT"),
                              scene.images.size(), &requested_slot)) {
        SetResult(&output, false, "reference_slot",
                  runtime::RuntimeStatus::kInvalidRequest, nullptr, &totals,
                  "invalid PW_DENSE_PROBE_REFERENCE_SLOT");
        return output;
      }
      const fs::path full_scene_output =
          output_base / "DenseProbeFrozenB28_full_scene";
      const FrozenSceneImage& requested_reference =
          scene.images[requested_slot];
      totals.requested_references = 1U;
      if (std::string(requested_mode) == "photo_ref") {
        const bool completed = ExecuteReference(
            root, scene, requested_slot, PlanPhase::kPhotometricOnly, nullptr,
            0U, nullptr, 0U, nullptr, 0U, host.get(), loader,
            full_scene_output, false, nullptr, nullptr, &totals, &record,
            &detail);
        SetResult(&output, completed,
                  completed ? "photo_reference_complete"
                            : "photo_reference_failed",
                  record.status, &record, &totals,
                  completed ? record.detail : detail.c_str());
        return output;
      }
      // [BATCH-REF 2026-08-31] geometric 的融合批:流入的三份数据也要按
      // N 个 reference 首尾相接,顺序与 PrepareFusedBatch 的槽顺序一致:
      //   source_depth     : [ref0 的 S 个源平面][ref1 的 S 个源平面]...
      //   reference_depth  : [ref0 的 W*H][ref1 的 W*H]...
      //   reference_normal : [ref0 的 3*W*H][ref1 的 3*W*H]...
      // PW_DENSE_BATCH_SAME=1 时 N 个槽都是 requested_slot(回归形态)。
      const std::uint32_t geometric_batch = ProbeBatchCount();
      const char* const geo_same_raw = std::getenv("PW_DENSE_BATCH_SAME");
      const bool geo_same = geo_same_raw != nullptr && geo_same_raw[0] == '1';
      std::vector<float> source_depth;
      std::vector<float> reference_depth_values;
      std::vector<float> reference_normal_values;
      for (std::uint32_t index = 0U; index < geometric_batch; ++index) {
        const std::size_t slot =
            geo_same ? requested_slot
                     : (requested_slot + index) % scene.images.size();
        const FrozenSceneImage& image = scene.images[slot];
        std::vector<float> slot_source_depth;
        FloatMatrix slot_depth;
        FloatMatrix slot_normal;
        if (!LoadLayeredSourceDepths(full_scene_output, scene, image,
                                     &slot_source_depth, &detail) ||
            !LoadPersistedPhotometricState(full_scene_output, image,
                                           &slot_depth, &slot_normal,
                                           &detail)) {
          SetResult(&output, false, "geometric_input_load_failed",
                    runtime::RuntimeStatus::kInvalidRequest, &record, &totals,
                    detail.c_str());
          return output;
        }
        source_depth.insert(source_depth.end(), slot_source_depth.begin(),
                            slot_source_depth.end());
        reference_depth_values.insert(reference_depth_values.end(),
                                      slot_depth.values.begin(),
                                      slot_depth.values.end());
        reference_normal_values.insert(reference_normal_values.end(),
                                       slot_normal.values.begin(),
                                       slot_normal.values.end());
      }
      const bool completed = ExecuteReference(
          root, scene, requested_slot, PlanPhase::kGeometricOnly,
          source_depth.data(), source_depth.size(),
          reference_depth_values.data(), reference_depth_values.size(),
          reference_normal_values.data(), reference_normal_values.size(),
          host.get(), loader,
          full_scene_output, true, nullptr, nullptr, &totals, &record, &detail);
      SetResult(&output, completed,
                completed ? "geometric_reference_complete"
                          : "geometric_reference_failed",
                record.status, &record, &totals,
                completed ? record.detail : detail.c_str());
      return output;
    }
    std::vector<float> layered_source_depth;
    const FrozenSceneImage& reference = scene.images[kReferenceSlot];
    for (const std::int32_t source_index : reference.source_indices) {
      std::size_t source_slot = 0U;
      if (!FindImageSlot(scene, source_index, &source_slot) ||
          !ExecuteReference(root, scene, source_slot,
                            PlanPhase::kPhotometricOnly, nullptr, 0U,
                            nullptr, 0U, nullptr, 0U,
                            host.get(), loader, output_root, false,
                            nullptr, nullptr, &totals, &record, &detail)) {
        SetResult(&output, false, "source_photometric_failed",
                  record.status, &record, &totals, detail.c_str());
        return output;
      }
    }
    if (!ExecuteReference(
            root, scene, kReferenceSlot, PlanPhase::kPhotometricOnly, nullptr,
            0U, nullptr, 0U, nullptr, 0U, host.get(), loader, output_root,
            false, nullptr, nullptr, &totals, &record, &detail)) {
      SetResult(&output, false, "reference_photometric_failed", record.status,
                &record, &totals, detail.c_str());
      return output;
    }
    if (!LoadLayeredSourceDepths(output_root, scene, reference,
                                 &layered_source_depth, &detail)) {
      SetResult(&output, false, "source_photometric_reload_failed",
                runtime::RuntimeStatus::kInvalidRequest, &record, &totals,
                detail.c_str());
      return output;
    }
    FloatMatrix reference_depth_matrix;
    FloatMatrix reference_normal_matrix;
    if (!LoadPersistedPhotometricState(output_root, reference,
                                       &reference_depth_matrix,
                                       &reference_normal_matrix, &detail)) {
      SetResult(&output, false, "reference_photometric_reload_failed",
                runtime::RuntimeStatus::kInvalidRequest, &record, &totals,
                detail.c_str());
      return output;
    }
    const std::vector<float>& reference_photometric_depth =
        reference_depth_matrix.values;
    const std::vector<float>& reference_photometric_normal =
        reference_normal_matrix.values;
    const std::size_t expected_reference_depth_count =
        static_cast<std::size_t>(reference.width) * reference.height;
    if (reference_photometric_depth.size() !=
            expected_reference_depth_count ||
        reference_photometric_normal.size() !=
            expected_reference_depth_count * 3U) {
      SetResult(&output, false, "reference_state_layout",
                runtime::RuntimeStatus::kInvalidRequest, &record, &totals,
                "reference photometric depth/normal dimensions mismatch");
      return output;
    }
    const bool completed = ExecuteReference(
        root, scene, kReferenceSlot, PlanPhase::kGeometricOnly,
        layered_source_depth.data(), layered_source_depth.size(),
        reference_photometric_depth.data(),
        reference_photometric_depth.size(),
        reference_photometric_normal.data(),
        reference_photometric_normal.size(), host.get(), loader, output_root,
        true, nullptr, nullptr, &totals, &record, &detail);
    SetResult(&output, completed,
              completed ? "real_input_split_reference0_complete"
                        : "real_input_split_reference0_failed",
              record.status, &record, &totals,
              completed ? record.detail : detail.c_str());
    return output;
  } catch (...) {
    SetResult(&output, false, "exception", runtime::RuntimeStatus::kInvalidRequest,
              nullptr, nullptr, "real-input probe threw");
    return output;
  }
}

}  // namespace pocketworld::official_dense::vulkan
