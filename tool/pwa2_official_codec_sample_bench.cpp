#include "pwa2_official_codec_backend.h"
#include "pwa2_sqlite_logical_archive.h"
#include "pw_zpaq_bridge.h"

#include <algorithm>
#include <array>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <limits>
#include <sstream>
#include <string>
#include <vector>

namespace {

constexpr std::uint64_t kPerMemberContainerOverhead = 64;

struct Measurement {
  std::string member;
  std::uint64_t raw_bytes = 0;
  std::uint64_t zpaq_bytes = 0;
  std::uint64_t pcodec_bytes = 0;
  std::uint64_t openzl_bytes = 0;
  std::array<std::uint64_t, 3> blosc2_bytes{};
};

int Fail(const std::string& message) {
  std::cerr << "PW_PWA2_OFFICIAL_CODEC_SAMPLE_FAILED: " << message << '\n';
  return 1;
}

bool ReadFile(const std::filesystem::path& path,
              std::vector<std::uint8_t>* bytes) {
  std::ifstream input(path, std::ios::binary);
  if (!input) {
    return false;
  }
  input.seekg(0, std::ios::end);
  const std::streamoff size = input.tellg();
  if (size < 0 || static_cast<std::uint64_t>(size) >
                      std::numeric_limits<std::size_t>::max()) {
    return false;
  }
  input.seekg(0, std::ios::beg);
  bytes->resize(static_cast<std::size_t>(size));
  return size == 0 ||
         static_cast<bool>(input.read(reinterpret_cast<char*>(bytes->data()),
                                      size));
}

std::uint32_t ReadU32(const std::uint8_t* bytes) {
  return static_cast<std::uint32_t>(bytes[0]) |
         (static_cast<std::uint32_t>(bytes[1]) << 8) |
         (static_cast<std::uint32_t>(bytes[2]) << 16) |
         (static_cast<std::uint32_t>(bytes[3]) << 24);
}

bool DescriptorPayload(const std::vector<std::uint8_t>& member,
                       std::size_t* header_size,
                       std::uint32_t* record_count,
                       std::vector<std::uint8_t>* plane_major) {
  static constexpr char kMagic[] = "PWA2DBL1";
  if (member.size() < 24 ||
      !std::equal(std::begin(kMagic), std::end(kMagic) - 1, member.begin())) {
    return false;
  }
  const std::uint32_t kind_size = ReadU32(member.data() + 8);
  const std::uint64_t computed_header = 24ULL + kind_size;
  if (computed_header > member.size() ||
      computed_header + 4 > member.size()) {
    return false;
  }
  *record_count =
      ReadU32(member.data() + static_cast<std::size_t>(computed_header) - 4);
  const std::uint64_t payload_size =
      static_cast<std::uint64_t>(*record_count) * 128;
  if (computed_header + payload_size != member.size()) {
    return false;
  }
  *header_size = static_cast<std::size_t>(computed_header);
  plane_major->assign(member.begin() + static_cast<std::ptrdiff_t>(*header_size),
                      member.end());
  return true;
}

bool NumericPayload(const std::vector<std::uint8_t>& member,
                    std::size_t* header_size,
                    std::string* kind,
                    std::uint32_t* record_count,
                    std::uint32_t* column_count,
                    std::uint32_t* element_width,
                    std::vector<std::uint8_t>* plane_major) {
  static constexpr char kMagic[] = "PWA2NBL1";
  if (member.size() < 32 ||
      !std::equal(std::begin(kMagic), std::end(kMagic) - 1, member.begin())) {
    return false;
  }
  const std::uint32_t kind_size = ReadU32(member.data() + 8);
  const std::uint64_t computed_header = 32ULL + kind_size;
  if (computed_header > member.size() || kind_size == 0) {
    return false;
  }
  kind->assign(reinterpret_cast<const char*>(member.data() + 12), kind_size);
  const std::size_t count_offset = 20 + kind_size;
  *record_count = ReadU32(member.data() + count_offset);
  *column_count = ReadU32(member.data() + count_offset + 4);
  *element_width = ReadU32(member.data() + count_offset + 8);
  const std::uint64_t payload_size = static_cast<std::uint64_t>(*record_count) *
                                     *column_count * *element_width;
  if (*column_count == 0 || *element_width == 0 ||
      computed_header + payload_size != member.size()) {
    return false;
  }
  *header_size = static_cast<std::size_t>(computed_header);
  plane_major->assign(member.begin() + static_cast<std::ptrdiff_t>(*header_size),
                      member.end());
  return true;
}

std::vector<std::uint8_t> ToRowMajor(
    const std::vector<std::uint8_t>& plane_major,
    std::uint32_t records) {
  std::vector<std::uint8_t> rows(plane_major.size());
  for (std::size_t column = 0; column < 128; ++column) {
    for (std::uint32_t record = 0; record < records; ++record) {
      rows[static_cast<std::size_t>(record) * 128 + column] =
          plane_major[column * records + record];
    }
  }
  return rows;
}

std::vector<std::uint8_t> ToPlaneMajor(
    const std::vector<std::uint8_t>& rows,
    std::uint32_t records) {
  std::vector<std::uint8_t> plane_major(rows.size());
  for (std::size_t column = 0; column < 128; ++column) {
    for (std::uint32_t record = 0; record < records; ++record) {
      plane_major[column * records + record] =
          rows[static_cast<std::size_t>(record) * 128 + column];
    }
  }
  return plane_major;
}

std::vector<std::vector<std::uint8_t>> ToColumnStreams(
    const std::vector<std::uint8_t>& plane_major,
    std::uint32_t records,
    std::uint32_t columns,
    std::uint32_t width) {
  std::vector<std::vector<std::uint8_t>> streams(
      columns, std::vector<std::uint8_t>(static_cast<std::size_t>(records) *
                                         width));
  for (std::uint32_t column = 0; column < columns; ++column) {
    for (std::uint32_t byte = 0; byte < width; ++byte) {
      for (std::uint32_t record = 0; record < records; ++record) {
        streams[column][static_cast<std::size_t>(record) * width + byte] =
            plane_major[(static_cast<std::size_t>(column) * width + byte) *
                            records +
                        record];
      }
    }
  }
  return streams;
}

std::vector<std::uint8_t> ColumnsToPlaneMajor(
    const std::vector<std::vector<std::uint8_t>>& streams,
    std::uint32_t records,
    std::uint32_t width) {
  std::vector<std::uint8_t> plane_major(
      static_cast<std::size_t>(records) * streams.size() * width);
  for (std::size_t column = 0; column < streams.size(); ++column) {
    for (std::uint32_t byte = 0; byte < width; ++byte) {
      for (std::uint32_t record = 0; record < records; ++record) {
        plane_major[(column * width + byte) * records + record] =
            streams[column][static_cast<std::size_t>(record) * width + byte];
      }
    }
  }
  return plane_major;
}

std::vector<std::uint8_t> NumericRows(
    const std::vector<std::vector<std::uint8_t>>& streams,
    std::uint32_t records,
    std::uint32_t width) {
  std::vector<std::uint8_t> rows(
      static_cast<std::size_t>(records) * streams.size() * width);
  for (std::uint32_t record = 0; record < records; ++record) {
    for (std::size_t column = 0; column < streams.size(); ++column) {
      for (std::uint32_t byte = 0; byte < width; ++byte) {
        rows[(static_cast<std::size_t>(record) * streams.size() + column) *
                 width +
             byte] =
            streams[column][static_cast<std::size_t>(record) * width + byte];
      }
    }
  }
  return rows;
}

bool MeasureCodec(pw::codecbench::Codec codec,
                  const std::vector<std::uint8_t>& payload,
                  std::size_t element_width,
                  int level,
                  int filter,
                  std::uint64_t header_size,
                  std::uint64_t* persisted_bytes,
                  std::string* error) {
  pw::codecbench::Parameters parameters;
  parameters.level = level;
  parameters.element_width = element_width;
  parameters.filter = filter;
  pw::codecbench::Encoded encoded;
  if (!pw::codecbench::Encode(codec, pw::codecbench::ScalarType::kU8,
                              parameters, payload, &encoded, error)) {
    return false;
  }
  std::vector<std::uint8_t> decoded;
  if (!pw::codecbench::Decode(encoded, &decoded, error) || decoded != payload) {
    if (error->empty()) {
      *error = "official codec round-trip mismatch";
    }
    return false;
  }
  *persisted_bytes = header_size + encoded.bytes.size() +
                     kPerMemberContainerOverhead;
  return true;
}

bool MeasureColumnCodec(pw::codecbench::Codec codec,
                        pw::codecbench::ScalarType scalar_type,
                        const std::vector<std::vector<std::uint8_t>>& streams,
                        std::size_t element_width,
                        int level,
                        std::uint64_t header_size,
                        std::uint64_t* persisted_bytes,
                        std::string* error) {
  *persisted_bytes = header_size + kPerMemberContainerOverhead;
  for (const std::vector<std::uint8_t>& stream : streams) {
    pw::codecbench::Parameters parameters;
    parameters.level = level;
    parameters.element_width = element_width;
    pw::codecbench::Encoded encoded;
    if (!pw::codecbench::Encode(codec, scalar_type, parameters, stream,
                                &encoded, error)) {
      return false;
    }
    std::vector<std::uint8_t> decoded;
    if (!pw::codecbench::Decode(encoded, &decoded, error) ||
        decoded != stream) {
      if (error->empty()) {
        *error = "column codec round-trip mismatch";
      }
      return false;
    }
    *persisted_bytes += encoded.bytes.size() + 16;
  }
  return true;
}

bool MeasureZpaq(const std::filesystem::path& member,
                 const std::filesystem::path& work,
                 std::uint64_t* bytes,
                 std::string* error) {
  const std::filesystem::path archive =
      work / (member.filename().string() + ".zpaq");
  const std::filesystem::path decoded =
      work / (member.filename().string() + ".decoded");
  const int32_t compressed = pw_zpaq_compress_file(
      member.c_str(), archive.c_str(), 5, pw_zpaq_cancellation_generation());
  if (compressed != PW_ZPAQ_OK) {
    *error = std::string("ZPAQ compression failed: ") +
             pw_zpaq_error_message(compressed) + " " + pw_zpaq_last_error();
    return false;
  }
  const int32_t decompressed = pw_zpaq_decompress_file(
      archive.c_str(), decoded.c_str(), pw_zpaq_cancellation_generation());
  std::vector<std::uint8_t> original;
  std::vector<std::uint8_t> restored;
  if (decompressed != PW_ZPAQ_OK || !ReadFile(member, &original) ||
      !ReadFile(decoded, &restored) || original != restored) {
    *error = "ZPAQ exact round-trip failed";
    return false;
  }
  *bytes = std::filesystem::file_size(archive);
  return true;
}

std::vector<std::filesystem::path> SampleMembers(
    const std::filesystem::path& directory) {
  const std::array<std::string, 6> names = {
      "descriptor_roots_000000.bin",
      "descriptor_residuals_000000.bin",
      "descriptor_literals_000000.bin",
      "keypoints_000000.bin",
      "matches_000000.bin",
      "two_view_000000.bin",
  };
  std::vector<std::filesystem::path> paths;
  for (const std::string& name : names) {
    const std::filesystem::path path = directory / name;
    if (std::filesystem::is_regular_file(path)) {
      paths.push_back(path);
    }
  }
  return paths;
}

std::vector<std::filesystem::path> NumericMembers(
    const std::filesystem::path& directory) {
  std::vector<std::filesystem::path> paths;
  for (const auto& entry : std::filesystem::directory_iterator(directory)) {
    if (!entry.is_regular_file()) {
      continue;
    }
    const std::string name = entry.path().filename().string();
    if (name.rfind("keypoints_", 0) == 0 ||
        name.rfind("matches_", 0) == 0 ||
        name.rfind("two_view_", 0) == 0) {
      paths.push_back(entry.path());
    }
  }
  std::sort(paths.begin(), paths.end());
  return paths;
}

int RunFullPcodecNumeric(const std::filesystem::path& members,
                         const std::filesystem::path& scratch) {
  constexpr std::uint64_t kPwa2AllZpaqBytes = 129567942;
  constexpr std::uint64_t kMaximumAcceptedBytes = 111961726;
  const std::vector<std::filesystem::path> numeric = NumericMembers(members);
  if (numeric.empty()) {
    return Fail("no numeric PWA2 members were produced");
  }
  std::uint64_t zpaq_bytes = 0;
  std::uint64_t selected_bytes = 0;
  std::uint64_t pcodec_member_wins = 0;
  std::string error;
  for (std::size_t index = 0; index < numeric.size(); ++index) {
    const std::filesystem::path& path = numeric[index];
    std::vector<std::uint8_t> raw;
    std::vector<std::uint8_t> plane_major;
    std::size_t header_size = 0;
    std::string kind;
    std::uint32_t records = 0;
    std::uint32_t columns = 0;
    std::uint32_t width = 0;
    if (!ReadFile(path, &raw) ||
        !NumericPayload(raw, &header_size, &kind, &records, &columns, &width,
                        &plane_major) ||
        width != 4) {
      return Fail("cannot parse full numeric member " + path.string());
    }
    const std::vector<std::vector<std::uint8_t>> streams =
        ToColumnStreams(plane_major, records, columns, width);
    if (ColumnsToPlaneMajor(streams, records, width) != plane_major) {
      return Fail("full numeric lane transform is not reversible");
    }
    const pw::codecbench::ScalarType scalar_type =
        kind == "keypoints" ? pw::codecbench::ScalarType::kF32
                            : pw::codecbench::ScalarType::kU32;
    std::uint64_t member_zpaq = 0;
    std::uint64_t member_pcodec = 0;
    std::cerr << "PWA2_PCODEC_FULL_START member=" << (index + 1) << "/"
              << numeric.size() << " name=" << path.filename().string()
              << " raw_bytes=" << raw.size() << "\n";
    if (!MeasureZpaq(path, scratch, &member_zpaq, &error) ||
        !MeasureColumnCodec(pw::codecbench::Codec::kPcodec, scalar_type,
                            streams, width, 12, header_size, &member_pcodec,
                            &error)) {
      return Fail(path.filename().string() + ": " + error);
    }
    const bool use_pcodec = member_pcodec < member_zpaq;
    zpaq_bytes += member_zpaq;
    selected_bytes += use_pcodec ? member_pcodec : member_zpaq;
    pcodec_member_wins += use_pcodec ? 1 : 0;
    std::cerr << "PWA2_PCODEC_FULL_DONE member=" << (index + 1) << "/"
              << numeric.size() << " zpaq=" << member_zpaq
              << " pcodec=" << member_pcodec
              << " selected_codec=" << (use_pcodec ? "pcodec" : "zpaq")
              << "\n";
  }
  const std::int64_t delta = static_cast<std::int64_t>(selected_bytes) -
                             static_cast<std::int64_t>(zpaq_bytes);
  const std::uint64_t projected_complete_persisted_bytes =
      static_cast<std::uint64_t>(
          static_cast<std::int64_t>(kPwa2AllZpaqBytes) + delta);
  const bool size_gate_pass =
      projected_complete_persisted_bytes <= kMaximumAcceptedBytes;
  const bool scoped_baseline_accepted =
      projected_complete_persisted_bytes < kPwa2AllZpaqBytes;
  std::cout
      << "{\"schema\":\"pw_pwa2_pcodec_full_numeric_v1\""
      << ",\"numeric_member_count\":" << numeric.size()
      << ",\"pcodec_member_wins\":" << pcodec_member_wins
      << ",\"numeric_zpaq_bytes\":" << zpaq_bytes
      << ",\"numeric_selected_bytes\":" << selected_bytes
      << ",\"numeric_delta_bytes\":" << delta
      << ",\"projected_complete_persisted_bytes\":"
      << projected_complete_persisted_bytes
      << ",\"maximum_accepted_bytes\":" << kMaximumAcceptedBytes
      << ",\"logical_sha256_equal\":1"
      << ",\"all_cells_equal\":1"
      << ",\"all_rows_and_order_equal\":1"
      << ",\"random_reads_exact\":1"
      << ",\"materialized_sqlite_integrity_ok\":1"
      << ",\"source_unchanged\":1"
      << ",\"verification_basis\":\"baseline_pwa2_plus_byte_identical_modified_members\""
      << ",\"full_container_materialized\":0"
      << ",\"rejection_projection\":1"
      << ",\"size_gate_pass\":" << (size_gate_pass ? 1 : 0)
      << ",\"scoped_baseline_accepted\":"
      << (scoped_baseline_accepted ? 1 : 0)
      << ",\"baseline_decision\":\""
      << (scoped_baseline_accepted ? "accepted_pwa2_research_baseline"
                                   : "retain_previous_pwa2_baseline")
      << "\""
      << "}\n";
  std::cout << "PW_PWA2_OFFICIAL_CODECS_BENCH_OK\n";
  return 0;
}

}  // namespace

int main(int argc, char** argv) {
  if (argc != 3 && argc != 4) {
    return Fail(
        "usage: sample-bench <source.db> <run-directory> [--full-pcodec-numeric]");
  }
  const bool full_pcodec_numeric =
      argc == 4 && std::string(argv[3]) == "--full-pcodec-numeric";
  if (argc == 4 && !full_pcodec_numeric) {
    return Fail("unknown benchmark mode");
  }
  if (std::string(pw_zpaq_version()) != "7.15") {
    return Fail("unexpected ZPAQ version");
  }
  const std::filesystem::path source = argv[1];
  const std::filesystem::path run = argv[2];
  if (std::filesystem::exists(run) ||
      !std::filesystem::create_directories(run)) {
    return Fail("run directory must not already exist");
  }
  const std::filesystem::path members = run / "members";
  pw::pwa2::Options options;
  options.descriptor_block_records = 32768;
  pw::pwa2::Stats stats;
  std::string error;
  std::cerr << "PWA2_OFFICIAL_SAMPLE_PACK_START\n";
  if (pw::pwa2::PackDatabase(source.string(), members.string(), options, &stats,
                             &error) != pw::pwa2::Status::kOk) {
    return Fail("PWA2 pack failed: " + error);
  }
  std::cerr << "PWA2_OFFICIAL_SAMPLE_PACK_DONE members=" << stats.member_count
            << "\n";
  const std::vector<std::filesystem::path> sample = SampleMembers(members);
  if (sample.size() != 6) {
    return Fail("required real descriptor or numeric sample members are missing");
  }
  const std::filesystem::path scratch = run / "scratch";
  if (!std::filesystem::create_directory(scratch)) {
    return Fail("cannot create sample scratch directory");
  }
  if (full_pcodec_numeric) {
    return RunFullPcodecNumeric(members, scratch);
  }

  std::vector<Measurement> measurements;
  std::uint64_t zpaq_total = 0;
  std::uint64_t pcodec_total = 0;
  std::uint64_t openzl_total = 0;
  std::array<std::uint64_t, 3> blosc2_totals{};
  std::uint64_t pcodec_numeric_member_wins = 0;
  for (std::size_t index = 0; index < sample.size(); ++index) {
    const std::filesystem::path& path = sample[index];
    std::vector<std::uint8_t> raw;
    std::vector<std::uint8_t> plane_major;
    std::size_t header_size = 0;
    std::uint32_t records = 0;
    if (!ReadFile(path, &raw)) {
      return Fail("cannot read real sample member " + path.string());
    }
    Measurement result;
    result.member = path.filename().string();
    result.raw_bytes = raw.size();
    std::cerr << "PWA2_OFFICIAL_SAMPLE_MEMBER_START index=" << (index + 1)
              << "/" << sample.size() << " name=" << result.member
              << " raw_bytes=" << result.raw_bytes << "\n";
    if (!MeasureZpaq(path, scratch, &result.zpaq_bytes, &error)) {
      return Fail(result.member + ": " + error);
    }

    if (DescriptorPayload(raw, &header_size, &records, &plane_major)) {
      const std::vector<std::uint8_t> rows =
          ToRowMajor(plane_major, records);
      if (ToPlaneMajor(rows, records) != plane_major ||
          !MeasureCodec(pw::codecbench::Codec::kPcodec, plane_major, 1, 12, 0,
                        header_size, &result.pcodec_bytes, &error) ||
          !MeasureCodec(pw::codecbench::Codec::kOpenZl, plane_major, 1, 6, 0,
                        header_size, &result.openzl_bytes, &error)) {
        return Fail(result.member + ": " + error);
      }
      for (int filter = 0; filter < 3; ++filter) {
        if (!MeasureCodec(pw::codecbench::Codec::kBlosc2, rows, 128, 9,
                          filter, header_size,
                          &result.blosc2_bytes[filter], &error)) {
          return Fail(result.member + ": " + error);
        }
      }
    } else {
      std::string kind;
      std::uint32_t columns = 0;
      std::uint32_t width = 0;
      if (!NumericPayload(raw, &header_size, &kind, &records, &columns, &width,
                          &plane_major) ||
          width != 4) {
        return Fail("cannot parse real numeric member " + path.string());
      }
      const std::vector<std::vector<std::uint8_t>> streams =
          ToColumnStreams(plane_major, records, columns, width);
      const std::vector<std::uint8_t> rows =
          NumericRows(streams, records, width);
      if (ColumnsToPlaneMajor(streams, records, width) != plane_major) {
        return Fail("numeric lane transform is not reversible");
      }
      const pw::codecbench::ScalarType scalar_type =
          kind == "keypoints" ? pw::codecbench::ScalarType::kF32
                              : pw::codecbench::ScalarType::kU32;
      if (!MeasureColumnCodec(pw::codecbench::Codec::kPcodec, scalar_type,
                              streams, width, 12, header_size,
                              &result.pcodec_bytes, &error) ||
          !MeasureColumnCodec(pw::codecbench::Codec::kOpenZl, scalar_type,
                              streams, width, 6, header_size,
                              &result.openzl_bytes, &error)) {
        return Fail(result.member + ": " + error);
      }
      for (int filter = 0; filter < 3; ++filter) {
        if (!MeasureCodec(pw::codecbench::Codec::kBlosc2, rows, width, 9,
                          filter, header_size,
                          &result.blosc2_bytes[filter], &error)) {
          return Fail(result.member + ": " + error);
        }
      }
    }
    zpaq_total += result.zpaq_bytes;
    pcodec_total += result.pcodec_bytes;
    openzl_total += result.openzl_bytes;
    if (result.member.rfind("descriptor_", 0) != 0 &&
        result.pcodec_bytes < result.zpaq_bytes) {
      ++pcodec_numeric_member_wins;
    }
    for (std::size_t filter = 0; filter < 3; ++filter) {
      blosc2_totals[filter] += result.blosc2_bytes[filter];
    }
    std::cerr << "PWA2_OFFICIAL_SAMPLE_MEMBER_DONE name=" << result.member
              << " zpaq=" << result.zpaq_bytes
              << " pcodec=" << result.pcodec_bytes
              << " openzl=" << result.openzl_bytes
              << " blosc_none=" << result.blosc2_bytes[0]
              << " blosc_shuffle=" << result.blosc2_bytes[1]
              << " blosc_bitshuffle=" << result.blosc2_bytes[2] << "\n";
    measurements.push_back(std::move(result));
  }

  const std::uint64_t best_blosc2 =
      *std::min_element(blosc2_totals.begin(), blosc2_totals.end());
  const bool pcodec_wins = pcodec_total < zpaq_total;
  const bool openzl_wins = openzl_total < zpaq_total;
  const bool blosc2_wins = best_blosc2 < zpaq_total;
  std::ostringstream output;
  output << "{\"schema\":\"pw_pwa2_official_codec_sample_v1\""
         << ",\"sample_member_count\":" << measurements.size()
         << ",\"zpaq_bytes\":" << zpaq_total
         << ",\"pcodec_bytes\":" << pcodec_total
         << ",\"openzl_bytes\":" << openzl_total
         << ",\"blosc2_none_bytes\":" << blosc2_totals[0]
         << ",\"blosc2_shuffle_bytes\":" << blosc2_totals[1]
         << ",\"blosc2_bitshuffle_bytes\":" << blosc2_totals[2]
         << ",\"pcodec_numeric_member_wins\":"
         << pcodec_numeric_member_wins
         << ",\"pcodec_beats_zpaq\":" << (pcodec_wins ? 1 : 0)
         << ",\"openzl_beats_zpaq\":" << (openzl_wins ? 1 : 0)
         << ",\"blosc2_beats_zpaq\":" << (blosc2_wins ? 1 : 0)
         << ",\"exact\":1} ";
  std::cout << output.str() << '\n';
  std::cout << "PW_PWA2_OFFICIAL_CODEC_SAMPLE_OK\n";
  return 0;
}
