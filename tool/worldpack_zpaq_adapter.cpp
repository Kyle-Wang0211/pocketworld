#include "worldpack_zpaq_adapter.h"

#include <cerrno>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

#include <libzpaq.h>
#include <unistd.h>

namespace {

constexpr char kVersion[] = "7.15";
constexpr char kSourceSha256[] =
    "e85ec2529eb0ba22ceaeabd461e55357ef099b80f61c14f377b429ea3d49d418";

class ZpaqFailure final : public std::runtime_error {
 public:
  explicit ZpaqFailure(const std::string& message)
      : std::runtime_error(message) {}
};

struct FileCloser {
  void operator()(std::FILE* file) const {
    if (file != nullptr) {
      std::fclose(file);
    }
  }
};

using FilePtr = std::unique_ptr<std::FILE, FileCloser>;

class FileReader final : public libzpaq::Reader {
 public:
  explicit FileReader(std::FILE* file) : file_(file) {}

  int get() override {
    const int value = std::fgetc(file_);
    if (value == EOF && std::ferror(file_)) {
      throw ZpaqFailure("input read failed");
    }
    return value == EOF ? -1 : value;
  }

  int read(char* buffer, const int size) override {
    const std::size_t count =
        std::fread(buffer, 1, static_cast<std::size_t>(size), file_);
    if (std::ferror(file_)) {
      throw ZpaqFailure("input read failed");
    }
    return static_cast<int>(count);
  }

 private:
  std::FILE* file_;
};

class FileWriter final : public libzpaq::Writer {
 public:
  explicit FileWriter(std::FILE* file) : file_(file) {}

  void put(const int value) override {
    if (std::fputc(value, file_) == EOF) {
      throw ZpaqFailure("output write failed");
    }
  }

  void write(const char* buffer, const int size) override {
    const std::size_t wanted = static_cast<std::size_t>(size);
    if (wanted != 0 && std::fwrite(buffer, 1, wanted, file_) != wanted) {
      throw ZpaqFailure("output write failed");
    }
  }

 private:
  std::FILE* file_;
};

struct TemporaryOutput {
  FilePtr file;
  std::filesystem::path path;
};

TemporaryOutput OpenTemporaryOutput(const std::filesystem::path& output_path) {
  std::string pattern = output_path.string() + ".tmp.XXXXXX";
  std::vector<char> writable(pattern.begin(), pattern.end());
  writable.push_back('\0');
  const int descriptor = mkstemp(writable.data());
  if (descriptor < 0) {
    throw ZpaqFailure(std::string("temporary output creation failed: ") +
                      std::strerror(errno));
  }
  std::FILE* file = fdopen(descriptor, "wb");
  if (file == nullptr) {
    const int saved_errno = errno;
    close(descriptor);
    unlink(writable.data());
    throw ZpaqFailure(std::string("temporary output open failed: ") +
                      std::strerror(saved_errno));
  }
  return {FilePtr(file), std::filesystem::path(writable.data())};
}

void FinishOutput(TemporaryOutput* output,
                  const std::filesystem::path& final_path) {
  if (std::fflush(output->file.get()) != 0 ||
      fsync(fileno(output->file.get())) != 0) {
    throw ZpaqFailure(std::string("output synchronization failed: ") +
                      std::strerror(errno));
  }
  std::FILE* file = output->file.release();
  if (std::fclose(file) != 0) {
    throw ZpaqFailure(std::string("output close failed: ") +
                      std::strerror(errno));
  }
  std::error_code rename_error;
  std::filesystem::rename(output->path, final_path, rename_error);
  if (rename_error) {
    throw ZpaqFailure("atomic output publication failed: " +
                      rename_error.message());
  }
  output->path.clear();
}

void RemoveTemporary(const std::filesystem::path& path) {
  if (path.empty()) {
    return;
  }
  std::error_code ignored;
  std::filesystem::remove(path, ignored);
}

bool Run(const std::filesystem::path& input_path,
         const std::filesystem::path& output_path,
         const bool compress,
         pw::worldpack::zpaq::Result* result,
         std::string* error) {
  if (result == nullptr || error == nullptr || input_path.empty() ||
      output_path.empty()) {
    return false;
  }
  *result = {};
  error->clear();
  std::error_code output_exists_error;
  const bool output_exists =
      std::filesystem::exists(output_path, output_exists_error);
  if (output_exists_error) {
    *error = "output existence check failed: " + output_exists_error.message();
    return false;
  }
  if (output_exists) {
    *error = "output path already exists";
    return false;
  }
  TemporaryOutput output;
  bool published = false;
  try {
    std::error_code size_error;
    const std::uint64_t input_bytes =
        std::filesystem::file_size(input_path, size_error);
    if (size_error) {
      throw ZpaqFailure("input size failed: " + size_error.message());
    }
    FilePtr input(std::fopen(input_path.c_str(), "rb"));
    if (!input) {
      throw ZpaqFailure(std::string("input open failed: ") +
                        std::strerror(errno));
    }
    output = OpenTemporaryOutput(output_path);
    FileReader reader(input.get());
    FileWriter writer(output.file.get());
    const auto started = std::chrono::steady_clock::now();
    if (compress) {
      libzpaq::compress(&reader, &writer, "5", nullptr, nullptr, true);
    } else {
      libzpaq::decompress(&reader, &writer);
    }
    FinishOutput(&output, output_path);
    published = true;
    const auto finished = std::chrono::steady_clock::now();
    const std::uint64_t output_bytes =
        std::filesystem::file_size(output_path, size_error);
    if (size_error) {
      throw ZpaqFailure("output size failed: " + size_error.message());
    }
    result->input_bytes = input_bytes;
    result->complete_persisted_bytes = output_bytes;
    result->elapsed_microseconds = static_cast<std::uint64_t>(
        std::chrono::duration_cast<std::chrono::microseconds>(finished - started)
            .count());
    return true;
  } catch (const std::bad_alloc&) {
    *error = "ZPAQ allocation failed";
  } catch (const std::exception& caught) {
    *error = caught.what();
  } catch (...) {
    *error = "unknown ZPAQ failure";
  }
  output.file.reset();
  RemoveTemporary(output.path);
  if (published) {
    std::error_code ignored;
    std::filesystem::remove(output_path, ignored);
  }
  return false;
}

}  // namespace

namespace libzpaq {

void error(const char* message) {
  throw ZpaqFailure(message == nullptr ? "libzpaq error" : message);
}

}  // namespace libzpaq

namespace pw::worldpack::zpaq {

const char* Version() { return kVersion; }

const char* SourceSha256() { return kSourceSha256; }

bool CompressFile(const std::string& input_path,
                  const std::string& archive_path,
                  const int method,
                  Result* result,
                  std::string* error) {
  if (method != 5) {
    if (result != nullptr) {
      *result = {};
    }
    if (error != nullptr) {
      *error = "only frozen ZPAQ method 5 is supported";
    }
    return false;
  }
  return Run(input_path, archive_path, true, result, error);
}

bool DecompressFile(const std::string& archive_path,
                    const std::string& output_path,
                    Result* result,
                    std::string* error) {
  return Run(archive_path, output_path, false, result, error);
}

}  // namespace pw::worldpack::zpaq
