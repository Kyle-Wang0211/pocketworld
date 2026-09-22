#include "pwofficial_dense_c.h"

#include <atomic>
#include <cfloat>
#include <cstring>
#include <exception>
#include <string>

#include "backend_contract.h"

namespace {

using pocketworld::official_dense::ffi::BackendReadiness;
using pocketworld::official_dense::ffi::BackendRunRequest;
using pocketworld::official_dense::ffi::BackendRunResult;

thread_local std::string g_last_error;
std::atomic<bool> g_cancel_requested{false};

void ClearError() { g_last_error.clear(); }

void SetError(const char* message) {
  try {
    g_last_error = message == nullptr ? "unknown error" : message;
  } catch (...) {
    g_last_error.clear();
  }
}

void SetError(const std::string& message) {
  try {
    g_last_error = message;
  } catch (...) {
    g_last_error.clear();
  }
}

std::string MissingGateMessage(const BackendReadiness& readiness) {
  std::string message = "official dense backend unavailable; missing:";
  if (!readiness.source_hash_ready) message += " source-hash";
  if (!readiness.vulkan_loader_caps_ready) message += " vulkan-loader-caps";
  if (!readiness.xorwow_ready) message += " xorwow";
  if (!readiness.texture_parity_ready) message += " texture-parity";
  if (!readiness.shader_dispatch_ready) message += " shader-dispatch";
  if (!readiness.fusion_ready) message += " fusion";
  return message;
}

bool IsNonEmpty(const char* value) {
  return value != nullptr && value[0] != '\0';
}

bool HasTerminator(const char* value, const std::size_t capacity) {
  return std::memchr(value, '\0', capacity) != nullptr;
}

bool IsFlag(const int32_t value) { return value == 0 || value == 1; }

bool OptionsLayoutIsValid(const pwofficial_dense_options_t* options) {
  if (options == nullptr || options->struct_size != sizeof(*options) ||
      options->abi_version != PW_OFFICIAL_DENSE_ABI_VERSION) {
    return false;
  }
  if (!HasTerminator(options->gpu_index, sizeof(options->gpu_index)) ||
      !HasTerminator(options->mask_path, sizeof(options->mask_path))) {
    return false;
  }
  return IsFlag(options->geom_consistency) && IsFlag(options->filter) &&
         IsFlag(options->allow_missing_files) &&
         IsFlag(options->write_consistency_graph) &&
         IsFlag(options->use_cache);
}

pwofficial_dense_result_t InternalException(const char* message) {
  SetError(message);
  return PW_OFFICIAL_DENSE_INTERNAL_ERROR;
}

}  // namespace

extern "C" uint32_t pwofficial_dense_version(void) {
  return PW_OFFICIAL_DENSE_ABI_VERSION;
}

extern "C" const char* pwofficial_dense_last_error(void) {
  return g_last_error.c_str();
}

extern "C" pwofficial_dense_result_t pwofficial_dense_default_options(
    pwofficial_dense_options_t* options) {
  try {
    ClearError();
    if (options == nullptr) {
      SetError("options is null");
      return PW_OFFICIAL_DENSE_INVALID_ARGUMENT;
    }

    std::memset(options, 0, sizeof(*options));
    options->struct_size = sizeof(*options);
    options->abi_version = PW_OFFICIAL_DENSE_ABI_VERSION;

    options->depth_min = -1.0;
    options->depth_max = -1.0;
    options->sigma_spatial = -1.0;
    options->sigma_color = 0.2;
    options->ncc_sigma = 0.6;
    options->min_triangulation_angle = 1.0;
    options->incident_angle_sigma = 0.9;
    options->geom_consistency_regularizer = 0.3;
    options->geom_consistency_max_cost = 3.0;
    options->filter_min_ncc = 0.1;
    options->filter_min_triangulation_angle = 3.0;
    options->filter_geom_consistency_max_cost = 1.0;
    options->patch_match_cache_size = 32.0;
    std::memcpy(options->gpu_index, "-1", 3);
    options->patch_match_max_image_size = -1;
    options->window_radius = 5;
    options->window_step = 1;
    options->num_samples = 15;
    options->num_iterations = 5;
    options->filter_min_num_consistent = 2;
    options->patch_match_num_threads = -1;
    options->geom_consistency = 1;
    options->filter = 1;
    options->allow_missing_files = 0;
    options->write_consistency_graph = 0;

    options->mask_path[0] = '\0';
    options->fusion_num_threads = -1;
    options->fusion_max_image_size = -1;
    options->min_num_pixels = 5;
    options->max_num_pixels = 10000;
    options->max_traversal_depth = 100;
    options->max_reproj_error = 2.0;
    options->max_depth_error = 0.01;
    options->max_normal_error = 10.0;
    options->check_num_images = 50;
    options->use_cache = 0;
    options->fusion_cache_size = 32.0;
    for (int index = 0; index < 3; ++index) {
      options->bounding_box_min[index] = -FLT_MAX;
      options->bounding_box_max[index] = FLT_MAX;
    }
    return PW_OFFICIAL_DENSE_OK;
  } catch (const std::exception& error) {
    return InternalException(error.what());
  } catch (...) {
    return InternalException("unknown exception in default_options");
  }
}

extern "C" int32_t pwofficial_dense_is_available(void) {
  try {
    ClearError();
    const BackendReadiness readiness =
        pocketworld::official_dense::ffi::QueryBackendReadiness();
    if (!readiness.AllReady()) {
      SetError(MissingGateMessage(readiness));
      return 0;
    }
    return 1;
  } catch (const std::exception& error) {
    SetError(error.what());
    return 0;
  } catch (...) {
    SetError("unknown exception in is_available");
    return 0;
  }
}

extern "C" pwofficial_dense_result_t pwofficial_dense_run(
    const char* workspace_path,
    const char* output_ply,
    const pwofficial_dense_options_t* options) {
  try {
    ClearError();
    if (!IsNonEmpty(workspace_path)) {
      SetError("workspace_path is null or empty");
      return PW_OFFICIAL_DENSE_INVALID_ARGUMENT;
    }
    if (!IsNonEmpty(output_ply)) {
      SetError("output_ply is null or empty");
      return PW_OFFICIAL_DENSE_INVALID_ARGUMENT;
    }
    if (!OptionsLayoutIsValid(options)) {
      SetError("options layout, version, string, or flag is invalid");
      return PW_OFFICIAL_DENSE_INVALID_ARGUMENT;
    }

    const BackendReadiness readiness =
        pocketworld::official_dense::ffi::QueryBackendReadiness();
    if (!readiness.AllReady()) {
      SetError(MissingGateMessage(readiness));
      return PW_OFFICIAL_DENSE_UNAVAILABLE;
    }

    g_cancel_requested.store(false, std::memory_order_release);
    const BackendRunRequest request{
        workspace_path, output_ply, options, &g_cancel_requested};
    const BackendRunResult result =
        pocketworld::official_dense::ffi::RunBackend(request);
    if (result.code != PW_OFFICIAL_DENSE_OK) SetError(result.message);
    return result.code;
  } catch (const std::exception& error) {
    return InternalException(error.what());
  } catch (...) {
    return InternalException("unknown exception in run");
  }
}

extern "C" pwofficial_dense_result_t pwofficial_dense_cancel(void) {
  try {
    ClearError();
    g_cancel_requested.store(true, std::memory_order_release);
    pocketworld::official_dense::ffi::CancelBackend();
    return PW_OFFICIAL_DENSE_OK;
  } catch (const std::exception& error) {
    return InternalException(error.what());
  } catch (...) {
    return InternalException("unknown exception in cancel");
  }
}
