#include <cstdio>
#include <cstring>
#include <exception>
#include <memory>
#include <stdexcept>
#include <string>

#include <libzpaq.h>

namespace {

constexpr char kVersion[] = "7.15";
constexpr char kRevision[] =
    "e85ec2529eb0ba22ceaeabd461e55357ef099b80f61c14f377b429ea3d49d418";

class ZpaqError final : public std::runtime_error {
 public:
  explicit ZpaqError(const std::string& message)
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
      throw ZpaqError("input read failed");
    }
    return value == EOF ? -1 : value;
  }

  int read(char* buffer, const int size) override {
    const std::size_t count =
        std::fread(buffer, 1, static_cast<std::size_t>(size), file_);
    if (std::ferror(file_)) {
      throw ZpaqError("input read failed");
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
      throw ZpaqError("output write failed");
    }
  }

  void write(const char* buffer, const int size) override {
    const std::size_t wanted = static_cast<std::size_t>(size);
    if (wanted != 0 && std::fwrite(buffer, 1, wanted, file_) != wanted) {
      throw ZpaqError("output write failed");
    }
  }

 private:
  std::FILE* file_;
};

int Run(const bool compress, const char* input_path, const char* output_path) {
  try {
    FilePtr input(std::fopen(input_path, "rb"));
    if (!input) {
      throw ZpaqError(std::string("cannot open input: ") + std::strerror(errno));
    }
    FilePtr output(std::fopen(output_path, "wb"));
    if (!output) {
      throw ZpaqError(std::string("cannot open output: ") + std::strerror(errno));
    }
    FileReader reader(input.get());
    FileWriter writer(output.get());
    if (compress) {
      libzpaq::compress(&reader, &writer, "5", nullptr, nullptr, true);
    } else {
      libzpaq::decompress(&reader, &writer);
    }
    if (std::fflush(output.get()) != 0) {
      throw ZpaqError("output flush failed");
    }
    return 0;
  } catch (const std::exception& error) {
    std::fprintf(stderr, "zpaq_file_tool: %s\n", error.what());
    std::remove(output_path);
    return 1;
  }
}

}  // namespace

namespace libzpaq {

void error(const char* message) {
  throw ZpaqError(message == nullptr ? "libzpaq error" : message);
}

}  // namespace libzpaq

int main(const int argc, char** argv) {
  if (argc == 2 && std::strcmp(argv[1], "version") == 0) {
    std::printf("%s %s\n", kVersion, kRevision);
    return 0;
  }
  if (argc != 4) {
    std::fprintf(
        stderr,
        "usage: zpaq_file_tool version | compress INPUT OUTPUT | "
        "decompress INPUT OUTPUT\n");
    return 2;
  }
  if (std::strcmp(argv[1], "compress") == 0) {
    return Run(true, argv[2], argv[3]);
  }
  if (std::strcmp(argv[1], "decompress") == 0) {
    return Run(false, argv[2], argv[3]);
  }
  std::fprintf(stderr, "zpaq_file_tool: unsupported operation\n");
  return 2;
}
