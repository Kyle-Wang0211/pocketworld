#include <cstdint>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

#include <fpzip.h>
#include <meshoptimizer.h>
#include <zfp.h>

namespace fs = std::filesystem;

namespace {

struct PlyData {
  std::vector<unsigned char> file;
  std::vector<unsigned char> header;
  std::vector<float> positions_aos;
  std::vector<unsigned char> colors;
  std::size_t vertex_count = 0;
};

std::vector<unsigned char> ReadFile(const fs::path& path) {
  std::ifstream input(path, std::ios::binary | std::ios::ate);
  if (!input) {
    throw std::runtime_error("cannot open input: " + path.string());
  }
  const auto size = input.tellg();
  if (size < 0) {
    throw std::runtime_error("cannot determine input size");
  }
  std::vector<unsigned char> bytes(static_cast<std::size_t>(size));
  input.seekg(0);
  if (!bytes.empty() &&
      !input.read(reinterpret_cast<char*>(bytes.data()), size)) {
    throw std::runtime_error("cannot read input");
  }
  return bytes;
}

void WriteFile(const fs::path& path, const std::vector<unsigned char>& bytes) {
  std::ofstream output(path, std::ios::binary | std::ios::trunc);
  if (!output || (!bytes.empty() &&
                  !output.write(reinterpret_cast<const char*>(bytes.data()),
                                static_cast<std::streamsize>(bytes.size())))) {
    throw std::runtime_error("cannot write output: " + path.string());
  }
}

std::size_t ParseCount(const std::string& header) {
  const std::string marker = "element vertex ";
  const auto begin = header.find(marker);
  if (begin == std::string::npos) {
    throw std::runtime_error("PLY vertex count is missing");
  }
  const auto number_begin = begin + marker.size();
  const auto number_end = header.find('\n', number_begin);
  return std::stoull(header.substr(number_begin, number_end - number_begin));
}

PlyData ParsePly(const fs::path& path) {
  PlyData data;
  data.file = ReadFile(path);
  const std::string all(reinterpret_cast<const char*>(data.file.data()),
                        data.file.size());
  const std::string marker = "end_header\n";
  const auto marker_at = all.find(marker);
  if (marker_at == std::string::npos) {
    throw std::runtime_error("PLY header terminator is missing");
  }
  const auto header_size = marker_at + marker.size();
  const std::string header_text = all.substr(0, header_size);
  if (header_text.find("format binary_little_endian 1.0") ==
          std::string::npos ||
      header_text.find("property float x") == std::string::npos ||
      header_text.find("property float y") == std::string::npos ||
      header_text.find("property float z") == std::string::npos ||
      header_text.find("property uchar red") == std::string::npos ||
      header_text.find("property uchar green") == std::string::npos ||
      header_text.find("property uchar blue") == std::string::npos) {
    throw std::runtime_error("PLY schema is not the expected xyz/rgb layout");
  }
  data.vertex_count = ParseCount(header_text);
  constexpr std::size_t kStride = 3 * sizeof(float) + 3;
  if (data.file.size() != header_size + data.vertex_count * kStride) {
    throw std::runtime_error("PLY size does not match its declared schema");
  }
  data.header.assign(data.file.begin(), data.file.begin() + header_size);
  data.positions_aos.resize(data.vertex_count * 3);
  data.colors.resize(data.vertex_count * 3);
  for (std::size_t i = 0; i < data.vertex_count; ++i) {
    const auto* record = data.file.data() + header_size + i * kStride;
    std::memcpy(data.positions_aos.data() + i * 3, record, 3 * sizeof(float));
    std::memcpy(data.colors.data() + i * 3, record + 3 * sizeof(float), 3);
  }
  return data;
}

std::vector<unsigned char> RestorePly(
    const std::vector<unsigned char>& header,
    const std::vector<float>& positions_aos,
    const std::vector<unsigned char>& colors) {
  const std::size_t vertex_count = positions_aos.size() / 3;
  if (positions_aos.size() != vertex_count * 3 ||
      colors.size() != vertex_count * 3) {
    throw std::runtime_error("restored streams have inconsistent sizes");
  }
  constexpr std::size_t kStride = 3 * sizeof(float) + 3;
  std::vector<unsigned char> restored(header.size() + vertex_count * kStride);
  std::memcpy(restored.data(), header.data(), header.size());
  for (std::size_t i = 0; i < vertex_count; ++i) {
    auto* record = restored.data() + header.size() + i * kStride;
    std::memcpy(record, positions_aos.data() + i * 3, 3 * sizeof(float));
    std::memcpy(record + 3 * sizeof(float), colors.data() + i * 3, 3);
  }
  return restored;
}

void AppendU64(std::vector<unsigned char>& output, std::uint64_t value) {
  for (int shift = 0; shift < 64; shift += 8) {
    output.push_back(static_cast<unsigned char>(value >> shift));
  }
}

std::vector<unsigned char> Frame(const char magic[8], std::size_t count,
                                 const std::vector<unsigned char>& header,
                                 const std::vector<unsigned char>& primary,
                                 const std::vector<unsigned char>& secondary) {
  std::vector<unsigned char> output;
  output.reserve(8 + 4 * sizeof(std::uint64_t) + header.size() +
                 primary.size() + secondary.size());
  output.insert(output.end(), magic, magic + 8);
  AppendU64(output, count);
  AppendU64(output, header.size());
  AppendU64(output, primary.size());
  AppendU64(output, secondary.size());
  output.insert(output.end(), header.begin(), header.end());
  output.insert(output.end(), primary.begin(), primary.end());
  output.insert(output.end(), secondary.begin(), secondary.end());
  return output;
}

std::vector<unsigned char> EncodeMeshopt(const void* data,
                                         std::size_t count,
                                         std::size_t stride) {
  std::vector<unsigned char> encoded(
      meshopt_encodeVertexBufferBound(count, stride));
  const std::size_t size = meshopt_encodeVertexBufferLevel(
      encoded.data(), encoded.size(), data, count, stride, 3, 1);
  if (size == 0) {
    throw std::runtime_error("meshoptimizer encoding failed");
  }
  encoded.resize(size);
  return encoded;
}

std::vector<unsigned char> EncodeFpzip(const std::vector<float>& values,
                                       int nx, int ny, int nf) {
  std::vector<unsigned char> encoded(values.size() * sizeof(float) * 2 + 4096);
  FPZ* stream = fpzip_write_to_buffer(encoded.data(), encoded.size());
  if (stream == nullptr) {
    throw std::runtime_error("fpzip writer allocation failed");
  }
  stream->type = FPZIP_TYPE_FLOAT;
  stream->prec = 0;
  stream->nx = nx;
  stream->ny = ny;
  stream->nz = 1;
  stream->nf = nf;
  const bool header_ok = fpzip_write_header(stream) != 0;
  const std::size_t size = header_ok ? fpzip_write(stream, values.data()) : 0;
  fpzip_write_close(stream);
  if (size == 0) {
    throw std::runtime_error("fpzip encoding failed");
  }
  encoded.resize(size);
  return encoded;
}

std::vector<float> DecodeFpzip(const std::vector<unsigned char>& encoded,
                               std::size_t value_count, int nx, int ny,
                               int nf) {
  std::vector<float> decoded(value_count);
  FPZ* stream = fpzip_read_from_buffer(encoded.data());
  if (stream == nullptr || fpzip_read_header(stream) == 0 ||
      stream->type != FPZIP_TYPE_FLOAT || stream->prec != 0 ||
      stream->nx != nx || stream->ny != ny || stream->nz != 1 ||
      stream->nf != nf || fpzip_read(stream, decoded.data()) == 0) {
    if (stream != nullptr) {
      fpzip_read_close(stream);
    }
    throw std::runtime_error("fpzip decoding failed");
  }
  fpzip_read_close(stream);
  return decoded;
}

std::vector<unsigned char> EncodeZfp(std::vector<float>& values,
                                     std::size_t nx, std::size_t ny) {
  zfp_field* field = zfp_field_2d(values.data(), zfp_type_float, nx, ny);
  zfp_stream* stream = zfp_stream_open(nullptr);
  if (field == nullptr || stream == nullptr) {
    throw std::runtime_error("ZFP allocation failed");
  }
  zfp_stream_set_reversible(stream);
  std::vector<unsigned char> encoded(zfp_stream_maximum_size(stream, field));
  bitstream* bits = stream_open(encoded.data(), encoded.size());
  zfp_stream_set_bit_stream(stream, bits);
  zfp_stream_rewind(stream);
  const std::size_t size = zfp_compress(stream, field);
  stream_close(bits);
  zfp_stream_close(stream);
  zfp_field_free(field);
  if (size == 0) {
    throw std::runtime_error("ZFP encoding failed");
  }
  encoded.resize(size);
  return encoded;
}

std::vector<float> DecodeZfp(const std::vector<unsigned char>& encoded,
                             std::size_t value_count, std::size_t nx,
                             std::size_t ny) {
  std::vector<float> decoded(value_count);
  zfp_field* field = zfp_field_2d(decoded.data(), zfp_type_float, nx, ny);
  zfp_stream* stream = zfp_stream_open(nullptr);
  bitstream* bits = stream_open(
      const_cast<unsigned char*>(encoded.data()), encoded.size());
  if (field == nullptr || stream == nullptr || bits == nullptr) {
    throw std::runtime_error("ZFP decoder allocation failed");
  }
  zfp_stream_set_reversible(stream);
  zfp_stream_set_bit_stream(stream, bits);
  zfp_stream_rewind(stream);
  const std::size_t size = zfp_decompress(stream, field);
  stream_close(bits);
  zfp_stream_close(stream);
  zfp_field_free(field);
  if (size == 0) {
    throw std::runtime_error("ZFP decoding failed");
  }
  return decoded;
}

std::vector<float> ToSoa(const std::vector<float>& aos) {
  const std::size_t count = aos.size() / 3;
  std::vector<float> soa(aos.size());
  for (std::size_t i = 0; i < count; ++i) {
    for (std::size_t component = 0; component < 3; ++component) {
      soa[component * count + i] = aos[i * 3 + component];
    }
  }
  return soa;
}

std::vector<float> ToAos(const std::vector<float>& soa) {
  const std::size_t count = soa.size() / 3;
  std::vector<float> aos(soa.size());
  for (std::size_t i = 0; i < count; ++i) {
    for (std::size_t component = 0; component < 3; ++component) {
      aos[i * 3 + component] = soa[component * count + i];
    }
  }
  return aos;
}

void RequireExact(const PlyData& source,
                  const std::vector<float>& positions_aos,
                  const std::vector<unsigned char>& colors,
                  const fs::path& restored_path) {
  const auto restored = RestorePly(source.header, positions_aos, colors);
  if (restored != source.file) {
    throw std::runtime_error("restored PLY is not byte-identical");
  }
  WriteFile(restored_path, restored);
}

}  // namespace

int main(int argc, char** argv) {
  try {
    if (argc != 3) {
      std::cerr << "usage: point_cloud_micro_bench INPUT.ply OUTPUT_DIR\n";
      return 2;
    }
    const PlyData source = ParsePly(argv[1]);
    const fs::path output_dir = argv[2];
    fs::create_directories(output_dir);

    std::vector<unsigned char> padded_colors(source.vertex_count * 4, 0);
    for (std::size_t i = 0; i < source.vertex_count; ++i) {
      std::memcpy(padded_colors.data() + i * 4, source.colors.data() + i * 3,
                  3);
    }
    const auto mesh_positions = EncodeMeshopt(
        source.positions_aos.data(), source.vertex_count, 3 * sizeof(float));
    const auto mesh_colors =
        EncodeMeshopt(padded_colors.data(), source.vertex_count, 4);
    std::vector<float> mesh_positions_decoded(source.positions_aos.size());
    std::vector<unsigned char> mesh_colors_decoded(padded_colors.size());
    if (meshopt_decodeVertexBuffer(
            mesh_positions_decoded.data(), source.vertex_count,
            3 * sizeof(float), mesh_positions.data(), mesh_positions.size()) !=
            0 ||
        meshopt_decodeVertexBuffer(mesh_colors_decoded.data(),
                                   source.vertex_count, 4, mesh_colors.data(),
                                   mesh_colors.size()) != 0) {
      throw std::runtime_error("meshoptimizer decoding failed");
    }
    std::vector<unsigned char> mesh_rgb(source.colors.size());
    for (std::size_t i = 0; i < source.vertex_count; ++i) {
      std::memcpy(mesh_rgb.data() + i * 3, mesh_colors_decoded.data() + i * 4,
                  3);
    }
    RequireExact(source, mesh_positions_decoded, mesh_rgb,
                 output_dir / "meshoptimizer.restored.ply");
    const auto mesh_archive = Frame("PWMESH1\0", source.vertex_count,
                                    source.header, mesh_positions, mesh_colors);
    WriteFile(output_dir / "meshoptimizer.bin", mesh_archive);

    const auto positions_soa = ToSoa(source.positions_aos);
    const auto fpzip_aos = EncodeFpzip(source.positions_aos, 3,
                                       static_cast<int>(source.vertex_count), 1);
    const auto fpzip_soa = EncodeFpzip(
        positions_soa, static_cast<int>(source.vertex_count), 1, 3);
    const bool use_fpzip_soa = fpzip_soa.size() < fpzip_aos.size();
    const auto& fpzip_best = use_fpzip_soa ? fpzip_soa : fpzip_aos;
    auto fpzip_decoded = use_fpzip_soa
                             ? ToAos(DecodeFpzip(
                                   fpzip_best, positions_soa.size(),
                                   static_cast<int>(source.vertex_count), 1, 3))
                             : DecodeFpzip(
                                   fpzip_best, source.positions_aos.size(), 3,
                                   static_cast<int>(source.vertex_count), 1);
    RequireExact(source, fpzip_decoded, source.colors,
                 output_dir / "fpzip.restored.ply");
    const auto fpzip_archive = Frame(use_fpzip_soa ? "PWFPZS1\0" : "PWFPZA1\0",
                                     source.vertex_count, source.header,
                                     fpzip_best, source.colors);
    WriteFile(output_dir / "fpzip.bin", fpzip_archive);

    auto zfp_aos_input = source.positions_aos;
    auto zfp_soa_input = positions_soa;
    const auto zfp_aos = EncodeZfp(zfp_aos_input, 3, source.vertex_count);
    const auto zfp_soa = EncodeZfp(zfp_soa_input, source.vertex_count, 3);
    const bool use_zfp_soa = zfp_soa.size() < zfp_aos.size();
    const auto& zfp_best = use_zfp_soa ? zfp_soa : zfp_aos;
    auto zfp_decoded = use_zfp_soa
                           ? ToAos(DecodeZfp(zfp_best, positions_soa.size(),
                                           source.vertex_count, 3))
                           : DecodeZfp(zfp_best, source.positions_aos.size(), 3,
                                       source.vertex_count);
    RequireExact(source, zfp_decoded, source.colors,
                 output_dir / "zfp.restored.ply");
    const auto zfp_archive = Frame(use_zfp_soa ? "PWZFPS1\0" : "PWZFPA1\0",
                                   source.vertex_count, source.header, zfp_best,
                                   source.colors);
    WriteFile(output_dir / "zfp.bin", zfp_archive);

    std::cout << "original_bytes=" << source.file.size() << '\n'
              << "vertex_count=" << source.vertex_count << '\n'
              << "header_bytes=" << source.header.size() << '\n'
              << "meshoptimizer_position_bytes=" << mesh_positions.size()
              << '\n'
              << "meshoptimizer_color_bytes=" << mesh_colors.size() << '\n'
              << "meshoptimizer_archive_bytes=" << mesh_archive.size() << '\n'
              << "fpzip_aos_position_bytes=" << fpzip_aos.size() << '\n'
              << "fpzip_soa_position_bytes=" << fpzip_soa.size() << '\n'
              << "fpzip_layout=" << (use_fpzip_soa ? "soa" : "aos") << '\n'
              << "fpzip_archive_bytes=" << fpzip_archive.size() << '\n'
              << "zfp_aos_position_bytes=" << zfp_aos.size() << '\n'
              << "zfp_soa_position_bytes=" << zfp_soa.size() << '\n'
              << "zfp_layout=" << (use_zfp_soa ? "soa" : "aos") << '\n'
              << "zfp_archive_bytes=" << zfp_archive.size() << '\n';
    return 0;
  } catch (const std::exception& error) {
    std::cerr << "point_cloud_micro_bench: " << error.what() << '\n';
    return 1;
  }
}
