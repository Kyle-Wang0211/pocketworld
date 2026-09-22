#include "workspace_io.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <charconv>
#include <climits>
#include <cstring>
#include <fstream>
#include <iomanip>
#include <limits>
#include <sstream>
#include <system_error>

#include <unistd.h>

namespace pocketworld::official_dense {
namespace {

namespace fs = std::filesystem;

constexpr std::array<std::uint32_t, 64> kSha256RoundConstants = {
    0x428a2f98U, 0x71374491U, 0xb5c0fbcfU, 0xe9b5dba5U,
    0x3956c25bU, 0x59f111f1U, 0x923f82a4U, 0xab1c5ed5U,
    0xd807aa98U, 0x12835b01U, 0x243185beU, 0x550c7dc3U,
    0x72be5d74U, 0x80deb1feU, 0x9bdc06a7U, 0xc19bf174U,
    0xe49b69c1U, 0xefbe4786U, 0x0fc19dc6U, 0x240ca1ccU,
    0x2de92c6fU, 0x4a7484aaU, 0x5cb0a9dcU, 0x76f988daU,
    0x983e5152U, 0xa831c66dU, 0xb00327c8U, 0xbf597fc7U,
    0xc6e00bf3U, 0xd5a79147U, 0x06ca6351U, 0x14292967U,
    0x27b70a85U, 0x2e1b2138U, 0x4d2c6dfcU, 0x53380d13U,
    0x650a7354U, 0x766a0abbU, 0x81c2c92eU, 0x92722c85U,
    0xa2bfe8a1U, 0xa81a664bU, 0xc24b8b70U, 0xc76c51a3U,
    0xd192e819U, 0xd6990624U, 0xf40e3585U, 0x106aa070U,
    0x19a4c116U, 0x1e376c08U, 0x2748774cU, 0x34b0bcb5U,
    0x391c0cb3U, 0x4ed8aa4aU, 0x5b9cca4fU, 0x682e6ff3U,
    0x748f82eeU, 0x78a5636fU, 0x84c87814U, 0x8cc70208U,
    0x90befffaU, 0xa4506cebU, 0xbef9a3f7U, 0xc67178f2U,
};

constexpr std::uint32_t RotateRight(const std::uint32_t value,
                                    const unsigned int count) {
  return (value >> count) | (value << (32U - count));
}

class Sha256 final {
 public:
  void Update(const std::uint8_t* data, std::size_t size) {
    total_bytes_ += size;
    while (size > 0) {
      const std::size_t copy_size =
          std::min(size, block_.size() - block_size_);
      std::memcpy(block_.data() + block_size_, data, copy_size);
      block_size_ += copy_size;
      data += copy_size;
      size -= copy_size;
      if (block_size_ == block_.size()) {
        Transform(block_.data());
        block_size_ = 0;
      }
    }
  }

  std::string FinalHex() {
    const std::uint64_t bit_count =
        static_cast<std::uint64_t>(total_bytes_) * 8U;
    block_[block_size_++] = 0x80U;
    if (block_size_ > 56) {
      while (block_size_ < block_.size()) block_[block_size_++] = 0;
      Transform(block_.data());
      block_size_ = 0;
    }
    while (block_size_ < 56) block_[block_size_++] = 0;
    for (int shift = 56; shift >= 0; shift -= 8) {
      block_[block_size_++] =
          static_cast<std::uint8_t>((bit_count >> shift) & 0xffU);
    }
    Transform(block_.data());

    std::ostringstream output;
    output << std::hex << std::setfill('0');
    for (const std::uint32_t word : state_) {
      output << std::setw(8) << word;
    }
    return output.str();
  }

 private:
  void Transform(const std::uint8_t* block) {
    std::array<std::uint32_t, 64> words{};
    for (std::size_t i = 0; i < 16; ++i) {
      words[i] = (static_cast<std::uint32_t>(block[i * 4]) << 24U) |
                 (static_cast<std::uint32_t>(block[i * 4 + 1]) << 16U) |
                 (static_cast<std::uint32_t>(block[i * 4 + 2]) << 8U) |
                 static_cast<std::uint32_t>(block[i * 4 + 3]);
    }
    for (std::size_t i = 16; i < words.size(); ++i) {
      const std::uint32_t s0 = RotateRight(words[i - 15], 7) ^
                               RotateRight(words[i - 15], 18) ^
                               (words[i - 15] >> 3U);
      const std::uint32_t s1 = RotateRight(words[i - 2], 17) ^
                               RotateRight(words[i - 2], 19) ^
                               (words[i - 2] >> 10U);
      words[i] = words[i - 16] + s0 + words[i - 7] + s1;
    }

    std::uint32_t a = state_[0];
    std::uint32_t b = state_[1];
    std::uint32_t c = state_[2];
    std::uint32_t d = state_[3];
    std::uint32_t e = state_[4];
    std::uint32_t f = state_[5];
    std::uint32_t g = state_[6];
    std::uint32_t h = state_[7];
    for (std::size_t i = 0; i < words.size(); ++i) {
      const std::uint32_t sum1 = RotateRight(e, 6) ^ RotateRight(e, 11) ^
                                 RotateRight(e, 25);
      const std::uint32_t choose = (e & f) ^ ((~e) & g);
      const std::uint32_t temp1 =
          h + sum1 + choose + kSha256RoundConstants[i] + words[i];
      const std::uint32_t sum0 = RotateRight(a, 2) ^ RotateRight(a, 13) ^
                                 RotateRight(a, 22);
      const std::uint32_t majority = (a & b) ^ (a & c) ^ (b & c);
      const std::uint32_t temp2 = sum0 + majority;
      h = g;
      g = f;
      f = e;
      e = d + temp1;
      d = c;
      c = b;
      b = a;
      a = temp1 + temp2;
    }
    state_[0] += a;
    state_[1] += b;
    state_[2] += c;
    state_[3] += d;
    state_[4] += e;
    state_[5] += f;
    state_[6] += g;
    state_[7] += h;
  }

  std::array<std::uint32_t, 8> state_ = {
      0x6a09e667U, 0xbb67ae85U, 0x3c6ef372U, 0xa54ff53aU,
      0x510e527fU, 0x9b05688cU, 0x1f83d9abU, 0x5be0cd19U,
  };
  std::array<std::uint8_t, 64> block_{};
  std::size_t block_size_ = 0;
  std::uintmax_t total_bytes_ = 0;
};

Status FileIdentity(const fs::path& path,
                    std::uintmax_t* byte_size,
                    std::string* sha256) {
  std::error_code error;
  const fs::file_status link_status = fs::symlink_status(path, error);
  if (error || link_status.type() != fs::file_type::regular) {
    return Status::Error("not a direct regular file: " + path.string());
  }
  if (!fs::is_regular_file(path, error) || error) {
    return Status::Error("not a regular file: " + path.string());
  }
  const std::uintmax_t size = fs::file_size(path, error);
  if (error) return Status::Error("cannot stat file: " + path.string());
  std::ifstream stream(path, std::ios::binary);
  if (!stream) return Status::Error("cannot open file: " + path.string());
  Sha256 hash;
  std::array<std::uint8_t, 64 * 1024> buffer{};
  while (stream) {
    stream.read(reinterpret_cast<char*>(buffer.data()), buffer.size());
    const auto count = stream.gcount();
    if (count > 0) hash.Update(buffer.data(), static_cast<std::size_t>(count));
  }
  if (!stream.eof()) return Status::Error("cannot read file: " + path.string());
  *byte_size = size;
  *sha256 = hash.FinalHex();
  return Status::Ok();
}

bool IsLowercaseSha256(const std::string& value) {
  if (value.size() != 64) return false;
  for (const char character : value) {
    if (!((character >= '0' && character <= '9') ||
          (character >= 'a' && character <= 'f'))) {
      return false;
    }
  }
  return true;
}

bool IsSafeImageName(const std::string& image_name) {
  if (image_name.empty() || image_name == "." || image_name == "..") {
    return false;
  }
  if (image_name.find('\0') != std::string::npos ||
      image_name.find('/') != std::string::npos ||
      image_name.find('\\') != std::string::npos) {
    return false;
  }
  return fs::path(image_name).filename() == fs::path(image_name);
}

fs::path OwnedTemporaryPath(const fs::path& destination) {
  static std::atomic<std::uint64_t> counter{0};
  const auto parent = destination.parent_path();
  const auto base = destination.filename().string();
  for (;;) {
    const auto value = counter.fetch_add(1, std::memory_order_relaxed);
    const fs::path candidate =
        parent / (base + ".pwofficial.tmp." + std::to_string(getpid()) + "." +
                  std::to_string(value));
    std::error_code error;
    const bool exists = fs::exists(candidate, error);
    if (!error && !exists) return candidate;
  }
}

class OwnedTemporaryFile final {
 public:
  explicit OwnedTemporaryFile(fs::path path) : path_(std::move(path)) {}
  ~OwnedTemporaryFile() {
    if (!committed_) {
      std::error_code ignored;
      fs::remove(path_, ignored);
    }
  }
  const fs::path& path() const { return path_; }
  void Commit() { committed_ = true; }

 private:
  fs::path path_;
  bool committed_ = false;
};

Status RenameTemporaryFile(OwnedTemporaryFile* temporary,
                           const fs::path& destination) {
  std::error_code error;
  std::filesystem::rename(temporary->path(), destination, error);
  if (error) {
    return Status::Error("cannot atomically rename temporary file: " +
                         error.message());
  }
  temporary->Commit();
  return Status::Ok();
}

bool HostIsLittleEndian() {
  const std::uint16_t value = 1;
  return *reinterpret_cast<const std::uint8_t*>(&value) == 1;
}

std::uint32_t ByteSwap32(const std::uint32_t value) {
  return ((value & 0x000000ffU) << 24U) |
         ((value & 0x0000ff00U) << 8U) |
         ((value & 0x00ff0000U) >> 8U) |
         ((value & 0xff000000U) >> 24U);
}

template <typename T>
void WriteLittleEndian(std::ofstream* stream, const std::vector<T>& values) {
  static_assert(sizeof(T) == 4);
  if (HostIsLittleEndian()) {
    stream->write(reinterpret_cast<const char*>(values.data()),
                  static_cast<std::streamsize>(values.size() * sizeof(T)));
    return;
  }
  for (const T value : values) {
    std::uint32_t bits = 0;
    std::memcpy(&bits, &value, sizeof(bits));
    bits = ByteSwap32(bits);
    stream->write(reinterpret_cast<const char*>(&bits), sizeof(bits));
  }
}

template <typename T>
bool ReadLittleEndian(std::ifstream* stream, std::vector<T>* values) {
  static_assert(sizeof(T) == 4);
  stream->read(reinterpret_cast<char*>(values->data()),
               static_cast<std::streamsize>(values->size() * sizeof(T)));
  if (!*stream) return false;
  if (!HostIsLittleEndian()) {
    for (T& value : *values) {
      std::uint32_t bits = 0;
      std::memcpy(&bits, &value, sizeof(bits));
      bits = ByteSwap32(bits);
      std::memcpy(&value, &bits, sizeof(bits));
    }
  }
  return true;
}

Status ValidateDimensions(const std::size_t width,
                          const std::size_t height,
                          const std::size_t depth,
                          std::size_t* count) {
  if (width == 0 || height == 0 || depth == 0) {
    return Status::Error("COLMAP matrix dimensions must be non-zero");
  }
  if (width > std::numeric_limits<std::size_t>::max() / height) {
    return Status::Error("COLMAP matrix dimensions overflow");
  }
  const std::size_t area = width * height;
  if (area > std::numeric_limits<std::size_t>::max() / depth) {
    return Status::Error("COLMAP matrix dimensions overflow");
  }
  *count = area * depth;
  return Status::Ok();
}

Status ReadHeader(std::ifstream* stream,
                  std::size_t* width,
                  std::size_t* height,
                  std::size_t* depth) {
  std::array<std::string, 3> fields;
  for (std::string& field : fields) {
    char character = 0;
    while (stream->get(character)) {
      if (character == '&') break;
      if (character < '0' || character > '9' || field.size() >= 20) {
        return Status::Error("invalid COLMAP matrix header");
      }
      field.push_back(character);
    }
    if (!*stream || character != '&' || field.empty()) {
      return Status::Error("truncated COLMAP matrix header");
    }
  }
  std::array<std::size_t*, 3> outputs = {width, height, depth};
  for (std::size_t index = 0; index < fields.size(); ++index) {
    const auto result = std::from_chars(fields[index].data(),
                                        fields[index].data() + fields[index].size(),
                                        *outputs[index]);
    if (result.ec != std::errc{} ||
        result.ptr != fields[index].data() + fields[index].size()) {
      return Status::Error("invalid COLMAP matrix dimension");
    }
  }
  return Status::Ok();
}

Status ValidateConsistencyGraph(const ConsistencyGraph& graph) {
  if (graph.width == 0 || graph.height == 0) {
    return Status::Error("consistency graph dimensions must be non-zero");
  }
  std::size_t offset = 0;
  while (offset < graph.values.size()) {
    if (graph.values.size() - offset < 3) {
      return Status::Error("truncated consistency graph record");
    }
    const std::int32_t col = graph.values[offset];
    const std::int32_t row = graph.values[offset + 1];
    const std::int32_t num_images = graph.values[offset + 2];
    if (col < 0 || static_cast<std::size_t>(col) >= graph.width || row < 0 ||
        static_cast<std::size_t>(row) >= graph.height || num_images < 0) {
      return Status::Error("invalid consistency graph record");
    }
    const auto image_count = static_cast<std::size_t>(num_images);
    if (image_count > graph.values.size() - offset - 3) {
      return Status::Error("truncated consistency graph image list");
    }
    offset += 3 + image_count;
  }
  return Status::Ok();
}

template <typename Writer>
Status AtomicWrite(const fs::path& path, Writer writer) {
  std::error_code error;
  if (!fs::is_directory(path.parent_path(), error) || error) {
    return Status::Error("output parent is not a directory: " +
                         path.parent_path().string());
  }
  OwnedTemporaryFile temporary(OwnedTemporaryPath(path));
  std::ofstream stream(temporary.path(), std::ios::binary | std::ios::trunc);
  if (!stream) return Status::Error("cannot create temporary output");
  const Status written = writer(&stream);
  stream.flush();
  const bool stream_ok = static_cast<bool>(stream);
  stream.close();
  if (!written.ok()) return written;
  if (!stream_ok) return Status::Error("cannot write temporary output");
  return RenameTemporaryFile(&temporary, path);
}

}  // namespace

Status CreateStandardWorkspace(const fs::path& root) {
  if (root.empty()) return Status::Error("workspace root is empty");
  const std::array<fs::path, 6> directories = {
      root / "images",
      root / "sparse",
      root / "stereo",
      root / "stereo" / "depth_maps",
      root / "stereo" / "normal_maps",
      root / "stereo" / "consistency_graphs",
  };
  for (const fs::path& directory : directories) {
    std::error_code error;
    if (fs::exists(directory, error)) {
      if (error || !fs::is_directory(directory, error) || error) {
        return Status::Error("workspace path is not a directory: " +
                             directory.string());
      }
      continue;
    }
    if (!fs::create_directories(directory, error) && error) {
      return Status::Error("cannot create workspace directory: " +
                           directory.string() + ": " + error.message());
    }
  }
  return Status::Ok();
}

Status MaterializeImage(const fs::path& images_directory,
                        const MaterializationEntry& entry) {
  if (!IsSafeImageName(entry.image_name)) {
    return Status::Error("unsafe reconstruction image name");
  }
  if (!IsLowercaseSha256(entry.sha256)) {
    return Status::Error("invalid expected SHA-256");
  }
  std::error_code error;
  const fs::file_status images_status =
      fs::symlink_status(images_directory, error);
  if (error || images_status.type() != fs::file_type::directory) {
    return Status::Error("images directory must be a direct directory");
  }
  if (!fs::is_directory(images_directory, error) || error) {
    return Status::Error("images directory does not exist");
  }
  const fs::path destination = images_directory / entry.image_name;
  if (fs::exists(destination, error) || error) {
    return Status::Error("refusing to overwrite materialized image");
  }

  std::uintmax_t source_size = 0;
  std::string source_hash;
  Status status = FileIdentity(entry.source_path, &source_size, &source_hash);
  if (!status.ok()) return status;
  if (source_size != entry.byte_size || source_hash != entry.sha256) {
    return Status::Error("source image identity differs from handoff plan");
  }

  OwnedTemporaryFile temporary(OwnedTemporaryPath(destination));
  std::filesystem::create_hard_link(entry.source_path,
                                    temporary.path(),
                                    error);
  if (error) {
    error.clear();
    fs::copy_file(entry.source_path,
                  temporary.path(),
                  fs::copy_options::none,
                  error);
    if (error) {
      return Status::Error("cannot hard-link or copy image: " +
                           error.message());
    }
  }

  std::uintmax_t destination_size = 0;
  std::string destination_hash;
  status = FileIdentity(temporary.path(), &destination_size, &destination_hash);
  if (!status.ok()) return status;
  if (destination_size != entry.byte_size || destination_hash != entry.sha256) {
    return Status::Error("materialized image failed size/SHA-256 postcondition");
  }
  if (fs::exists(destination, error) || error) {
    return Status::Error("refusing to overwrite concurrently created image");
  }
  return RenameTemporaryFile(&temporary, destination);
}

Status WriteFloatMatrix(const fs::path& path, const FloatMatrix& matrix) {
  std::size_t count = 0;
  Status status =
      ValidateDimensions(matrix.width, matrix.height, matrix.depth, &count);
  if (!status.ok()) return status;
  if (matrix.values.size() != count) {
    return Status::Error("float matrix payload size differs from dimensions");
  }
  return AtomicWrite(path, [&](std::ofstream* stream) {
    *stream << matrix.width << "&" << matrix.height << "&" << matrix.depth
            << "&";
    WriteLittleEndian(stream, matrix.values);
    return Status::Ok();
  });
}

Status ReadFloatMatrix(const fs::path& path, FloatMatrix* matrix) {
  if (matrix == nullptr) return Status::Error("null float matrix output");
  std::ifstream stream(path, std::ios::binary);
  if (!stream) return Status::Error("cannot open float matrix");
  FloatMatrix result;
  Status status =
      ReadHeader(&stream, &result.width, &result.height, &result.depth);
  if (!status.ok()) return status;
  std::size_t count = 0;
  status = ValidateDimensions(result.width, result.height, result.depth, &count);
  if (!status.ok()) return status;
  result.values.resize(count);
  if (!ReadLittleEndian(&stream, &result.values)) {
    return Status::Error("truncated float matrix payload");
  }
  if (stream.peek() != std::ifstream::traits_type::eof()) {
    return Status::Error("unexpected float matrix trailing bytes");
  }
  *matrix = std::move(result);
  return Status::Ok();
}

Status WriteConsistencyGraph(const fs::path& path,
                             const ConsistencyGraph& graph) {
  const Status status = ValidateConsistencyGraph(graph);
  if (!status.ok()) return status;
  return AtomicWrite(path, [&](std::ofstream* stream) {
    *stream << graph.width << "&" << graph.height << "&1&";
    WriteLittleEndian(stream, graph.values);
    return Status::Ok();
  });
}

Status ReadConsistencyGraph(const fs::path& path, ConsistencyGraph* graph) {
  if (graph == nullptr) return Status::Error("null consistency graph output");
  std::ifstream stream(path, std::ios::binary);
  if (!stream) return Status::Error("cannot open consistency graph");
  ConsistencyGraph result;
  std::size_t depth = 0;
  Status status = ReadHeader(&stream, &result.width, &result.height, &depth);
  if (!status.ok()) return status;
  if (depth != 1) {
    return Status::Error("consistency graph depth must equal one");
  }
  const std::streampos payload_start = stream.tellg();
  stream.seekg(0, std::ios::end);
  const std::streampos payload_end = stream.tellg();
  if (payload_start < 0 || payload_end < payload_start) {
    return Status::Error("cannot determine consistency graph payload size");
  }
  const auto byte_count = static_cast<std::uintmax_t>(payload_end - payload_start);
  if (byte_count % sizeof(std::int32_t) != 0) {
    return Status::Error("misaligned consistency graph payload");
  }
  result.values.resize(byte_count / sizeof(std::int32_t));
  stream.seekg(payload_start);
  if (!ReadLittleEndian(&stream, &result.values)) {
    return Status::Error("truncated consistency graph payload");
  }
  status = ValidateConsistencyGraph(result);
  if (!status.ok()) return status;
  *graph = std::move(result);
  return Status::Ok();
}

Status WriteConfigLines(const fs::path& path,
                        const std::vector<std::string>& lines) {
  if (lines.empty()) {
    return Status::Error("refusing to infer an automatic image selection");
  }
  for (const std::string& line : lines) {
    if (line.empty() || line.find('\n') != std::string::npos ||
        line.find('\r') != std::string::npos ||
        line.find('\0') != std::string::npos) {
      return Status::Error("invalid explicit COLMAP config line");
    }
  }
  return AtomicWrite(path, [&](std::ofstream* stream) {
    for (const std::string& line : lines) *stream << line << '\n';
    return Status::Ok();
  });
}

}  // namespace pocketworld::official_dense
