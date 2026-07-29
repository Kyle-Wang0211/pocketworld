#include "pw_zpaq_bridge.h"

#include <atomic>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <memory>
#include <new>
#include <stdexcept>
#include <string>

#include <libzpaq.h>
#include <unistd.h>

namespace {

constexpr char kVersion[] = "7.15";
constexpr char kRevision[] =
    "e85ec2529eb0ba22ceaeabd461e55357ef099b80f61c14f377b429ea3d49d418";

std::atomic<uint64_t> g_cancellation_generation{0};
thread_local std::string g_last_error;

class ZpaqFailure final : public std::runtime_error {
 public:
  explicit ZpaqFailure(const std::string& message)
      : std::runtime_error(message) {}
};

class ZpaqCancelled final : public std::exception {};

void CheckCancellation(const uint64_t expected_generation) {
  if (g_cancellation_generation.load(std::memory_order_acquire) !=
      expected_generation) {
    throw ZpaqCancelled();
  }
}

struct FileCloser {
  void operator()(FILE* file) const {
    if (file != nullptr) {
      std::fclose(file);
    }
  }
};

using FilePtr = std::unique_ptr<FILE, FileCloser>;

int32_t SetSystemError(const char* operation, const int32_t status) {
  g_last_error = std::string(operation) + ": " + std::strerror(errno);
  return status;
}

class FileReader final : public libzpaq::Reader {
 public:
  FileReader(FILE* file, const uint64_t cancellation_generation)
      : file_(file), cancellation_generation_(cancellation_generation) {}

  int get() override {
    CheckCancellation(cancellation_generation_);
    const int value = std::fgetc(file_);
    if (value == EOF) {
      if (std::ferror(file_)) {
        throw ZpaqFailure("fgetc input failed");
      }
      return -1;
    }
    return value;
  }

  int read(char* buffer, const int size) override {
    CheckCancellation(cancellation_generation_);
    const size_t count =
        std::fread(buffer, 1, static_cast<size_t>(size), file_);
    if (std::ferror(file_)) {
      throw ZpaqFailure("fread input failed");
    }
    CheckCancellation(cancellation_generation_);
    return static_cast<int>(count);
  }

 private:
  FILE* file_;
  uint64_t cancellation_generation_;
};

class FileWriter final : public libzpaq::Writer {
 public:
  FileWriter(FILE* file, const uint64_t cancellation_generation)
      : file_(file), cancellation_generation_(cancellation_generation) {}

  void put(const int value) override {
    CheckCancellation(cancellation_generation_);
    if (std::fputc(value, file_) == EOF) {
      throw ZpaqFailure("fputc output failed");
    }
  }

  void write(const char* buffer, const int size) override {
    CheckCancellation(cancellation_generation_);
    const size_t wanted = static_cast<size_t>(size);
    if (wanted != 0 && std::fwrite(buffer, 1, wanted, file_) != wanted) {
      throw ZpaqFailure("fwrite output failed");
    }
    CheckCancellation(cancellation_generation_);
  }

 private:
  FILE* file_;
  uint64_t cancellation_generation_;
};

int32_t FinishOutput(FILE* output) {
  if (std::fflush(output) != 0) {
    return SetSystemError("fflush", PW_ZPAQ_SYNC_FAILED);
  }
  if (fsync(fileno(output)) != 0) {
    return SetSystemError("fsync", PW_ZPAQ_SYNC_FAILED);
  }
  return PW_ZPAQ_OK;
}

int32_t RunZpaq(const char* input_path,
                const char* output_path,
                const bool compress,
                const uint64_t cancellation_generation) {
  g_last_error.clear();
  try {
    CheckCancellation(cancellation_generation);
    FilePtr input(std::fopen(input_path, "rb"));
    if (!input) {
      return SetSystemError("fopen input", PW_ZPAQ_INPUT_OPEN_FAILED);
    }
    FilePtr output(std::fopen(output_path, "wb"));
    if (!output) {
      return SetSystemError("fopen output", PW_ZPAQ_OUTPUT_OPEN_FAILED);
    }

    FileReader reader(input.get(), cancellation_generation);
    FileWriter writer(output.get(), cancellation_generation);
    if (compress) {
      libzpaq::compress(&reader, &writer, "5", nullptr, nullptr, true);
    } else {
      libzpaq::decompress(&reader, &writer);
    }
    CheckCancellation(cancellation_generation);
    return FinishOutput(output.get());
  } catch (const ZpaqCancelled&) {
    g_last_error = "operation cancelled by foreground activity";
    return PW_ZPAQ_CANCELLED;
  } catch (const std::bad_alloc&) {
    g_last_error = "libzpaq allocation failed";
    return PW_ZPAQ_ALLOCATION_FAILED;
  } catch (const ZpaqFailure& error) {
    g_last_error = error.what();
    return PW_ZPAQ_CODEC_FAILED;
  } catch (const std::exception& error) {
    g_last_error = error.what();
    return PW_ZPAQ_CODEC_FAILED;
  } catch (...) {
    g_last_error = "unknown libzpaq failure";
    return PW_ZPAQ_CODEC_FAILED;
  }
}

}  // namespace

namespace libzpaq {

void error(const char* message) {
  throw ZpaqFailure(message == nullptr ? "libzpaq error" : message);
}

}  // namespace libzpaq

const char* pw_zpaq_version(void) { return kVersion; }

const char* pw_zpaq_revision(void) { return kRevision; }

const char* pw_zpaq_error_message(const int32_t status) {
  switch (status) {
    case PW_ZPAQ_OK:
      return "success";
    case PW_ZPAQ_INVALID_ARGUMENT:
      return "invalid argument";
    case PW_ZPAQ_UNSUPPORTED_METHOD:
      return "unsupported ZPAQ method";
    case PW_ZPAQ_INPUT_OPEN_FAILED:
      return "input file could not be opened";
    case PW_ZPAQ_OUTPUT_OPEN_FAILED:
      return "output file could not be opened";
    case PW_ZPAQ_INPUT_READ_FAILED:
      return "input file could not be read";
    case PW_ZPAQ_OUTPUT_WRITE_FAILED:
      return "output file could not be written";
    case PW_ZPAQ_CODEC_FAILED:
      return "libzpaq codec operation failed";
    case PW_ZPAQ_SYNC_FAILED:
      return "output file could not be durably synchronized";
    case PW_ZPAQ_ALLOCATION_FAILED:
      return "libzpaq allocation failed";
    case PW_ZPAQ_CANCELLED:
      return "operation cancelled";
    default:
      return "unknown libzpaq bridge error";
  }
}

const char* pw_zpaq_last_error(void) { return g_last_error.c_str(); }

int32_t pw_zpaq_compress_file(const char* input_path,
                              const char* output_path,
                              const int32_t method,
                              const uint64_t cancellation_generation) {
  if (input_path == nullptr || output_path == nullptr) {
    return PW_ZPAQ_INVALID_ARGUMENT;
  }
  if (method != 5) {
    return PW_ZPAQ_UNSUPPORTED_METHOD;
  }
  return RunZpaq(input_path, output_path, true, cancellation_generation);
}

int32_t pw_zpaq_decompress_file(const char* input_path,
                                const char* output_path,
                                const uint64_t cancellation_generation) {
  if (input_path == nullptr || output_path == nullptr) {
    return PW_ZPAQ_INVALID_ARGUMENT;
  }
  return RunZpaq(input_path, output_path, false, cancellation_generation);
}

uint64_t pw_zpaq_cancellation_generation(void) {
  return g_cancellation_generation.load(std::memory_order_acquire);
}

void pw_zpaq_request_cancel(void) {
  g_cancellation_generation.fetch_add(1, std::memory_order_acq_rel);
}
