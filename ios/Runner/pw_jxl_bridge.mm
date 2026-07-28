#import "pw_jxl_bridge.h"

#import <Foundation/Foundation.h>

#include <algorithm>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <memory>
#include <string>
#include <vector>

#include <jxl/decode.h>
#include <jxl/encode.h>
#include <jxl/thread_parallel_runner.h>
#include <jxl/version.h>
#include <mach/mach.h>
#include <malloc/malloc.h>
#include <sys/sysctl.h>

namespace {

using Clock = std::chrono::steady_clock;

struct EncoderDeleter {
  void operator()(JxlEncoder* encoder) const {
    JxlEncoderDestroy(encoder);
  }
};

struct DecoderDeleter {
  void operator()(JxlDecoder* decoder) const {
    JxlDecoderDestroy(decoder);
  }
};

struct RunnerDeleter {
  void operator()(void* runner) const {
    JxlThreadParallelRunnerDestroy(runner);
  }
};

using EncoderPtr = std::unique_ptr<JxlEncoder, EncoderDeleter>;
using DecoderPtr = std::unique_ptr<JxlDecoder, DecoderDeleter>;
using RunnerPtr = std::unique_ptr<void, RunnerDeleter>;

void ResetBuffer(PWJXLBuffer* output) {
  if (output != nullptr) {
    output->data = nullptr;
    output->size = 0;
  }
}

uint64_t ElapsedMicroseconds(const Clock::time_point start) {
  return static_cast<uint64_t>(
      std::chrono::duration_cast<std::chrono::microseconds>(Clock::now() - start)
          .count());
}

int32_t CopyOutput(const std::vector<uint8_t>& source, PWJXLBuffer* output) {
  if (source.empty()) {
    return PW_JXL_DECODER_OUTPUT_FAILED;
  }
  auto* bytes = static_cast<uint8_t*>(std::malloc(source.size()));
  if (bytes == nullptr) {
    return PW_JXL_ALLOCATION_FAILED;
  }
  std::memcpy(bytes, source.data(), source.size());
  output->data = bytes;
  output->size = source.size();
  return PW_JXL_OK;
}

RunnerPtr CreateRunner() {
  const size_t worker_count =
      JxlThreadParallelRunnerDefaultNumWorkerThreads();
  return RunnerPtr(JxlThreadParallelRunnerCreate(nullptr, worker_count));
}

bool ReadFile(const char* path, std::vector<uint8_t>* output) {
  if (path == nullptr || output == nullptr) {
    return false;
  }
  std::ifstream stream(path, std::ios::binary | std::ios::ate);
  if (!stream) {
    return false;
  }
  const std::streamoff size = stream.tellg();
  if (size <= 0) {
    return false;
  }
  output->resize(static_cast<size_t>(size));
  stream.seekg(0, std::ios::beg);
  return static_cast<bool>(
      stream.read(reinterpret_cast<char*>(output->data()), size));
}

bool WriteFile(const char* path, const uint8_t* data, const size_t size) {
  if (path == nullptr || data == nullptr || size == 0) {
    return false;
  }
  std::ofstream stream(path, std::ios::binary | std::ios::trunc);
  if (!stream) {
    return false;
  }
  stream.write(reinterpret_cast<const char*>(data),
               static_cast<std::streamsize>(size));
  stream.flush();
  return static_cast<bool>(stream);
}

uint64_t ReadTaskMetric(const bool peak) {
  task_vm_info_data_t info = {};
  mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
  const kern_return_t status =
      task_info(mach_task_self(), TASK_VM_INFO,
                reinterpret_cast<task_info_t>(&info), &count);
  if (status != KERN_SUCCESS) {
    return 0;
  }
  if (peak && count >= TASK_VM_INFO_REV4_COUNT) {
    return static_cast<uint64_t>(info.ledger_phys_footprint_peak);
  }
  return static_cast<uint64_t>(info.phys_footprint);
}

}  // namespace

const char* pw_jxl_version(void) {
  static const std::string version =
      std::to_string(JPEGXL_MAJOR_VERSION) + "." +
      std::to_string(JPEGXL_MINOR_VERSION) + "." +
      std::to_string(JPEGXL_PATCH_VERSION);
  return version.c_str();
}

const char* pw_jxl_revision(void) {
  return "a7a9c787341cf703dede03c2009fa460cae5e5df";
}

const char* pw_jxl_error_message(const int32_t status) {
  switch (status) {
    case PW_JXL_OK:
      return "success";
    case PW_JXL_INVALID_ARGUMENT:
      return "invalid argument";
    case PW_JXL_ALLOCATION_FAILED:
      return "allocation failed";
    case PW_JXL_ENCODER_CREATE_FAILED:
      return "encoder creation failed";
    case PW_JXL_ENCODER_RUNNER_FAILED:
      return "encoder thread runner failed";
    case PW_JXL_ENCODER_CONFIG_FAILED:
      return "encoder configuration failed";
    case PW_JXL_ENCODER_FRAME_FAILED:
      return "JPEG frame could not be encoded losslessly";
    case PW_JXL_ENCODER_OUTPUT_FAILED:
      return "encoder output failed";
    case PW_JXL_DECODER_CREATE_FAILED:
      return "decoder creation failed";
    case PW_JXL_DECODER_RUNNER_FAILED:
      return "decoder thread runner failed";
    case PW_JXL_DECODER_INPUT_FAILED:
      return "decoder input failed";
    case PW_JXL_DECODER_OUTPUT_FAILED:
      return "JPEG reconstruction output failed";
    case PW_JXL_NO_JPEG_RECONSTRUCTION:
      return "JXL has no JPEG reconstruction data";
    case PW_JXL_FILE_IO_FAILED:
      return "file input/output failed";
    default:
      return "unknown libjxl bridge error";
  }
}

int32_t pw_jxl_encode_jpeg_file(const char* jpeg_path,
                                const char* jxl_path,
                                const int32_t effort,
                                uint64_t* elapsed_microseconds) {
  std::vector<uint8_t> input;
  if (!ReadFile(jpeg_path, &input)) {
    return PW_JXL_FILE_IO_FAILED;
  }
  PWJXLBuffer encoded = {};
  const int32_t status =
      pw_jxl_encode_jpeg(input.data(), input.size(), effort, &encoded,
                         elapsed_microseconds);
  if (status != PW_JXL_OK) {
    pw_jxl_buffer_free(&encoded);
    malloc_zone_pressure_relief(nullptr, 0);
    return status;
  }
  const bool wrote = WriteFile(jxl_path, encoded.data, encoded.size);
  pw_jxl_buffer_free(&encoded);
  malloc_zone_pressure_relief(nullptr, 0);
  return wrote ? PW_JXL_OK : PW_JXL_FILE_IO_FAILED;
}

int32_t pw_jxl_reconstruct_jpeg_file(const char* jxl_path,
                                     const char* jpeg_path,
                                     uint64_t* elapsed_microseconds) {
  std::vector<uint8_t> input;
  if (!ReadFile(jxl_path, &input)) {
    return PW_JXL_FILE_IO_FAILED;
  }
  PWJXLBuffer reconstructed = {};
  const int32_t status =
      pw_jxl_reconstruct_jpeg(input.data(), input.size(), &reconstructed,
                             elapsed_microseconds);
  if (status != PW_JXL_OK) {
    pw_jxl_buffer_free(&reconstructed);
    malloc_zone_pressure_relief(nullptr, 0);
    return status;
  }
  const bool wrote =
      WriteFile(jpeg_path, reconstructed.data, reconstructed.size);
  pw_jxl_buffer_free(&reconstructed);
  malloc_zone_pressure_relief(nullptr, 0);
  return wrote ? PW_JXL_OK : PW_JXL_FILE_IO_FAILED;
}

int32_t pw_jxl_encode_jpeg(const uint8_t* jpeg_data,
                           const size_t jpeg_size,
                           const int32_t effort,
                           PWJXLBuffer* output,
                           uint64_t* elapsed_microseconds) {
  ResetBuffer(output);
  if (jpeg_data == nullptr || jpeg_size == 0 || output == nullptr ||
      effort < 1 || effort > 10) {
    return PW_JXL_INVALID_ARGUMENT;
  }

  const auto started = Clock::now();
  EncoderPtr encoder(JxlEncoderCreate(nullptr));
  if (!encoder) {
    return PW_JXL_ENCODER_CREATE_FAILED;
  }
  RunnerPtr runner = CreateRunner();
  if (!runner ||
      JxlEncoderSetParallelRunner(encoder.get(), JxlThreadParallelRunner,
                                  runner.get()) != JXL_ENC_SUCCESS) {
    return PW_JXL_ENCODER_RUNNER_FAILED;
  }
  if (JxlEncoderUseContainer(encoder.get(), JXL_TRUE) != JXL_ENC_SUCCESS ||
      JxlEncoderStoreJPEGMetadata(encoder.get(), JXL_TRUE) != JXL_ENC_SUCCESS) {
    return PW_JXL_ENCODER_CONFIG_FAILED;
  }

  JxlEncoderFrameSettings* frame =
      JxlEncoderFrameSettingsCreate(encoder.get(), nullptr);
  if (frame == nullptr ||
      JxlEncoderFrameSettingsSetOption(
          frame, JXL_ENC_FRAME_SETTING_EFFORT, effort) != JXL_ENC_SUCCESS) {
    return PW_JXL_ENCODER_CONFIG_FAILED;
  }
  if (JxlEncoderAddJPEGFrame(frame, jpeg_data, jpeg_size) != JXL_ENC_SUCCESS) {
    return PW_JXL_ENCODER_FRAME_FAILED;
  }
  JxlEncoderCloseInput(encoder.get());

  std::vector<uint8_t> encoded(std::max<size_t>(jpeg_size / 2, 65536));
  size_t used = 0;
  for (;;) {
    uint8_t* next_output = encoded.data() + used;
    size_t available = encoded.size() - used;
    const JxlEncoderStatus status =
        JxlEncoderProcessOutput(encoder.get(), &next_output, &available);
    used = encoded.size() - available;
    if (status == JXL_ENC_SUCCESS) {
      encoded.resize(used);
      break;
    }
    if (status != JXL_ENC_NEED_MORE_OUTPUT) {
      return PW_JXL_ENCODER_OUTPUT_FAILED;
    }
    encoded.resize(encoded.size() * 2);
  }

  const int32_t copy_status = CopyOutput(encoded, output);
  if (copy_status != PW_JXL_OK) {
    return copy_status;
  }
  if (elapsed_microseconds != nullptr) {
    *elapsed_microseconds = ElapsedMicroseconds(started);
  }
  return PW_JXL_OK;
}

int32_t pw_jxl_reconstruct_jpeg(const uint8_t* jxl_data,
                                const size_t jxl_size,
                                PWJXLBuffer* output,
                                uint64_t* elapsed_microseconds) {
  ResetBuffer(output);
  if (jxl_data == nullptr || jxl_size == 0 || output == nullptr) {
    return PW_JXL_INVALID_ARGUMENT;
  }

  const auto started = Clock::now();
  DecoderPtr decoder(JxlDecoderCreate(nullptr));
  if (!decoder) {
    return PW_JXL_DECODER_CREATE_FAILED;
  }
  RunnerPtr runner = CreateRunner();
  if (!runner ||
      JxlDecoderSetParallelRunner(decoder.get(), JxlThreadParallelRunner,
                                  runner.get()) != JXL_DEC_SUCCESS) {
    return PW_JXL_DECODER_RUNNER_FAILED;
  }
  if (JxlDecoderSubscribeEvents(
          decoder.get(),
          JXL_DEC_JPEG_RECONSTRUCTION | JXL_DEC_FULL_IMAGE) !=
      JXL_DEC_SUCCESS) {
    return PW_JXL_DECODER_INPUT_FAILED;
  }
  if (JxlDecoderSetInput(decoder.get(), jxl_data, jxl_size) != JXL_DEC_SUCCESS) {
    return PW_JXL_DECODER_INPUT_FAILED;
  }
  JxlDecoderCloseInput(decoder.get());

  std::vector<uint8_t> reconstructed(
      std::max<size_t>(jxl_size * 2, 65536));
  size_t used = 0;
  bool reconstruction_available = false;
  bool buffer_is_set = false;

  for (;;) {
    const JxlDecoderStatus status = JxlDecoderProcessInput(decoder.get());
    if (status == JXL_DEC_JPEG_RECONSTRUCTION) {
      reconstruction_available = true;
      if (JxlDecoderSetJPEGBuffer(decoder.get(), reconstructed.data(),
                                  reconstructed.size()) != JXL_DEC_SUCCESS) {
        return PW_JXL_DECODER_OUTPUT_FAILED;
      }
      buffer_is_set = true;
      continue;
    }
    if (status == JXL_DEC_JPEG_NEED_MORE_OUTPUT) {
      if (!buffer_is_set) {
        return PW_JXL_DECODER_OUTPUT_FAILED;
      }
      const size_t remaining = JxlDecoderReleaseJPEGBuffer(decoder.get());
      used = reconstructed.size() - remaining;
      reconstructed.resize(reconstructed.size() * 2);
      if (JxlDecoderSetJPEGBuffer(decoder.get(), reconstructed.data() + used,
                                  reconstructed.size() - used) !=
          JXL_DEC_SUCCESS) {
        return PW_JXL_DECODER_OUTPUT_FAILED;
      }
      buffer_is_set = true;
      continue;
    }
    if (status == JXL_DEC_FULL_IMAGE) {
      if (!reconstruction_available || !buffer_is_set) {
        return PW_JXL_NO_JPEG_RECONSTRUCTION;
      }
      const size_t remaining = JxlDecoderReleaseJPEGBuffer(decoder.get());
      used = reconstructed.size() - remaining;
      reconstructed.resize(used);
      break;
    }
    if (status == JXL_DEC_SUCCESS) {
      if (!reconstruction_available) {
        return PW_JXL_NO_JPEG_RECONSTRUCTION;
      }
      if (buffer_is_set) {
        const size_t remaining = JxlDecoderReleaseJPEGBuffer(decoder.get());
        used = reconstructed.size() - remaining;
      }
      reconstructed.resize(used);
      break;
    }
    if (status == JXL_DEC_ERROR || status == JXL_DEC_NEED_MORE_INPUT) {
      return PW_JXL_DECODER_INPUT_FAILED;
    }
  }

  const int32_t copy_status = CopyOutput(reconstructed, output);
  if (copy_status != PW_JXL_OK) {
    return copy_status;
  }
  if (elapsed_microseconds != nullptr) {
    *elapsed_microseconds = ElapsedMicroseconds(started);
  }
  return PW_JXL_OK;
}

void pw_jxl_buffer_free(PWJXLBuffer* buffer) {
  if (buffer == nullptr) {
    return;
  }
  std::free(buffer->data);
  ResetBuffer(buffer);
}

uint64_t pw_process_resident_bytes(void) {
  return ReadTaskMetric(false);
}

uint64_t pw_process_peak_resident_bytes(void) {
  return ReadTaskMetric(true);
}

int32_t pw_process_thermal_state(void) {
  return static_cast<int32_t>(NSProcessInfo.processInfo.thermalState);
}

const char* pw_documents_path(void) {
  static thread_local std::string path;
  @autoreleasepool {
    NSArray<NSString*>* paths =
        NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                            NSUserDomainMask, YES);
    path = paths.firstObject.UTF8String ?: "";
  }
  return path.c_str();
}

const char* pw_device_model(void) {
  static thread_local std::string model;
  size_t size = 0;
  if (sysctlbyname("hw.machine", nullptr, &size, nullptr, 0) != 0 || size == 0) {
    model = "unknown";
    return model.c_str();
  }
  std::vector<char> value(size);
  if (sysctlbyname("hw.machine", value.data(), &size, nullptr, 0) != 0) {
    model = "unknown";
    return model.c_str();
  }
  model.assign(value.data());
  return model.c_str();
}
