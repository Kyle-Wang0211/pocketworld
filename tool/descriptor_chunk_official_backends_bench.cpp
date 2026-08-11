#include "descriptor_chunk_archive.h"
#include "descriptor_similarity_forest.h"
#include "pw_zpaq_bridge.h"
#include "pwa2_official_codec_backend.h"

#include <CommonCrypto/CommonDigest.h>

#include <b2nd.h>
#include <blosc2.h>
#include <blosc2/filters-registry.h>
#include <sqlite3.h>

#include <algorithm>
#include <array>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <functional>
#include <iomanip>
#include <iostream>
#include <limits>
#include <sstream>
#include <string>
#include <utility>
#include <vector>

#include <spawn.h>
#include <sys/stat.h>
#include <sys/wait.h>

extern char **environ;

namespace {

constexpr std::uint32_t kDescriptorCount = 16384;
constexpr std::uint32_t kDimension = 128;
constexpr std::uint32_t kRootCount = 8192;
constexpr std::uint64_t kRawBytes =
    static_cast<std::uint64_t>(kDescriptorCount) * kDimension;
constexpr std::uint64_t kSourceBytes = 198983680;
constexpr char kSourceSha256[] =
    "0c12c0dfa76d50cae59929774242282d8236daeb852bdee6ac99c3062d6d08b0";

enum BackendId : std::uint8_t {
  kZpaqMethod5 = 1,
  kPcodecLevel12U8 = 2,
  kOpenZlExistingNumericLevel6 = 3,
  kBlosc2Zstd9None = 4,
  kBlosc2Zstd9Shuffle = 5,
  kBlosc2Zstd9Bitshuffle = 6,
  kOpenZlAceNoClustering = 7,
  kB2ndZstd9ShuffleBytedelta = 8,
};

using Decoder = std::function<bool(const std::vector<std::uint8_t> &,
                                   std::vector<std::uint8_t> *, std::string *)>;

struct EncodedArm {
  std::string name;
  std::uint8_t backend = 0;
  std::vector<std::uint8_t> frame;
  Decoder decoder;
  std::uint64_t encode_ms = 0;
  std::uint64_t encoder_model_bytes = 0;
};

struct ArmResult {
  std::string name;
  std::uint64_t codec_frame_bytes = 0;
  std::uint64_t parent_sidecar_bytes = 0;
  std::uint64_t archive_envelope_bytes = 0;
  std::uint64_t complete_persisted_bytes = 0;
  std::uint64_t encoder_model_bytes = 0;
  std::uint64_t encode_ms = 0;
  std::uint64_t decode_ms = 0;
  bool transformed_bytes_equal = false;
  bool transformed_sha256_equal = false;
  bool parent_sidecar_equal = false;
  bool original_bytes_equal = false;
  bool original_sha256_equal = false;
  bool corruption_rejected = false;
  std::string frame_sha256;
  std::string archive_sha256;
};

int Fail(const std::string &message) {
  std::cerr << "PW_DESCRIPTOR_CHUNK_OFFICIAL_BACKENDS_FAILED: " << message
            << '\n';
  return 1;
}

bool FailBool(std::string message, std::string *error) {
  if (error != nullptr) {
    *error = std::move(message);
  }
  return false;
}

std::string Hex(const std::array<std::uint8_t, 32> &digest) {
  std::ostringstream output;
  output << std::hex << std::setfill('0');
  for (const std::uint8_t byte : digest) {
    output << std::setw(2) << static_cast<unsigned int>(byte);
  }
  return output.str();
}

bool FileSha256(const std::string &path, std::string *hex, std::uint64_t *size,
                std::string *error) {
  std::ifstream input(path, std::ios::binary);
  if (!input) {
    return FailBool("cannot open file for SHA-256: " + path, error);
  }
  CC_SHA256_CTX context;
  CC_SHA256_Init(&context);
  std::array<char, 1024 * 1024> buffer{};
  std::uint64_t total = 0;
  while (input) {
    input.read(buffer.data(), buffer.size());
    const std::streamsize count = input.gcount();
    if (count > 0) {
      CC_SHA256_Update(&context, buffer.data(), static_cast<CC_LONG>(count));
      total += static_cast<std::uint64_t>(count);
    }
  }
  if (!input.eof()) {
    return FailBool("failed while hashing file: " + path, error);
  }
  std::array<std::uint8_t, CC_SHA256_DIGEST_LENGTH> digest{};
  CC_SHA256_Final(digest.data(), &context);
  *hex = Hex(digest);
  *size = total;
  return true;
}

bool WriteFile(const std::string &path, const std::vector<std::uint8_t> &bytes,
               std::string *error) {
  std::ofstream output(path, std::ios::binary | std::ios::trunc);
  if (!output) {
    return FailBool("cannot create file: " + path, error);
  }
  output.write(reinterpret_cast<const char *>(bytes.data()),
               static_cast<std::streamsize>(bytes.size()));
  output.flush();
  return output.good() || FailBool("cannot write file: " + path, error);
}

bool ReadFile(const std::string &path, std::vector<std::uint8_t> *bytes,
              std::string *error) {
  std::ifstream input(path, std::ios::binary | std::ios::ate);
  if (!input) {
    return FailBool("cannot open file: " + path, error);
  }
  const std::streamoff length = input.tellg();
  if (length < 0 || static_cast<std::uint64_t>(length) >
                        std::numeric_limits<std::size_t>::max()) {
    return FailBool("file length is invalid: " + path, error);
  }
  bytes->resize(static_cast<std::size_t>(length));
  input.seekg(0);
  if (!bytes->empty()) {
    input.read(reinterpret_cast<char *>(bytes->data()), length);
  }
  return input.good() || input.eof() ||
         FailBool("cannot read file: " + path, error);
}

bool RunProcess(const std::vector<std::string> &arguments, std::string *error) {
  if (arguments.empty()) {
    return FailBool("process argument list is empty", error);
  }
  std::vector<char *> argv;
  argv.reserve(arguments.size() + 1);
  for (const std::string &argument : arguments) {
    argv.push_back(const_cast<char *>(argument.c_str()));
  }
  argv.push_back(nullptr);
  pid_t process = 0;
  const int spawn_status =
      posix_spawn(&process, argv[0], nullptr, nullptr, argv.data(), environ);
  if (spawn_status != 0) {
    return FailBool("posix_spawn failed for " + arguments[0] + ": " +
                        std::strerror(spawn_status),
                    error);
  }
  int status = 0;
  if (waitpid(process, &status, 0) != process || !WIFEXITED(status) ||
      WEXITSTATUS(status) != 0) {
    return FailBool("process failed: " + arguments[0], error);
  }
  return true;
}

bool ReadDescriptorChunk(const std::string &database_path,
                         std::vector<std::uint8_t> *descriptors,
                         std::string *error) {
  const std::string uri = "file:" + database_path + "?immutable=1";
  sqlite3 *database = nullptr;
  if (sqlite3_open_v2(uri.c_str(), &database,
                      SQLITE_OPEN_READONLY | SQLITE_OPEN_URI,
                      nullptr) != SQLITE_OK) {
    const std::string message =
        database == nullptr ? "SQLite open failed" : sqlite3_errmsg(database);
    if (database != nullptr) {
      sqlite3_close(database);
    }
    return FailBool(message, error);
  }
  sqlite3_stmt *statement = nullptr;
  const char *sql =
      "SELECT image_id, rows, cols, data FROM descriptors ORDER BY image_id";
  if (sqlite3_prepare_v2(database, sql, -1, &statement, nullptr) != SQLITE_OK) {
    const std::string message = sqlite3_errmsg(database);
    sqlite3_close(database);
    return FailBool(message, error);
  }

  descriptors->clear();
  descriptors->reserve(kRawBytes);
  while (descriptors->size() < kRawBytes) {
    const int status = sqlite3_step(statement);
    if (status != SQLITE_ROW) {
      sqlite3_finalize(statement);
      sqlite3_close(database);
      return FailBool("descriptor table ended before the frozen chunk", error);
    }
    const std::int64_t rows = sqlite3_column_int64(statement, 1);
    const std::int64_t columns = sqlite3_column_int64(statement, 2);
    const int blob_bytes = sqlite3_column_bytes(statement, 3);
    const auto *blob =
        static_cast<const std::uint8_t *>(sqlite3_column_blob(statement, 3));
    if (rows <= 0 || columns != kDimension || blob == nullptr ||
        rows > std::numeric_limits<std::int64_t>::max() / columns ||
        rows * columns != blob_bytes) {
      sqlite3_finalize(statement);
      sqlite3_close(database);
      return FailBool("descriptor row dimensions are invalid", error);
    }
    const std::size_t remaining = kRawBytes - descriptors->size();
    const std::size_t copied =
        std::min<std::size_t>(remaining, static_cast<std::size_t>(blob_bytes));
    if (copied % kDimension != 0) {
      sqlite3_finalize(statement);
      sqlite3_close(database);
      return FailBool("descriptor selection split a vector", error);
    }
    descriptors->insert(descriptors->end(), blob, blob + copied);
  }
  const bool finalized = sqlite3_finalize(statement) == SQLITE_OK;
  const bool closed = sqlite3_close(database) == SQLITE_OK;
  return (finalized && closed && descriptors->size() == kRawBytes) ||
         FailBool("descriptor extraction did not close cleanly", error);
}

bool BuildFrozenChunk(const std::vector<std::uint8_t> &original,
                      std::vector<std::uint8_t> *transformed,
                      std::vector<std::uint8_t> *parent_sidecar,
                      std::vector<std::uint64_t> *parents, std::string *error) {
  pw::similarity_forest::Options options;
  options.dimension = kDimension;
  options.block_descriptors = kRootCount;
  options.nlist = 2048;
  options.nprobe = 32;
  options.maximum_training_descriptors = kDescriptorCount;
  options.nearest_candidates = 1;
  options.seed = 20260802;
  pw::similarity_forest::Stats stats;
  if (!pw::similarity_forest::Build(original, options, parents, &stats,
                                    error) ||
      stats.descriptor_nodes != kDescriptorCount ||
      stats.root_nodes != kRootCount ||
      stats.predicted_nodes != kDescriptorCount - kRootCount ||
      !pw::similarity_forest::EncodeParents(*parents, parent_sidecar, error)) {
    if (error != nullptr && error->empty()) {
      *error = "similarity forest dimensions differ from the frozen contract";
    }
    return false;
  }
  transformed->assign(original.begin(), original.end());
  return pw::similarity_forest::TransformResiduals(transformed, kDimension,
                                                   *parents, false, error);
}

bool DecodeOriginal(const std::vector<std::uint8_t> &transformed,
                    const std::vector<std::uint8_t> &parent_sidecar,
                    std::vector<std::uint8_t> *original, std::string *error) {
  std::vector<std::uint64_t> parents;
  if (!pw::similarity_forest::DecodeParents(parent_sidecar, kDescriptorCount,
                                            &parents, error)) {
    return false;
  }
  original->assign(transformed.begin(), transformed.end());
  return pw::similarity_forest::TransformResiduals(original, kDimension,
                                                   parents, true, error);
}

bool EncodeExisting(const std::string &name, std::uint8_t backend,
                    pw::codecbench::Codec codec,
                    const pw::codecbench::Parameters &parameters,
                    const std::vector<std::uint8_t> &transformed,
                    EncodedArm *arm, std::string *error) {
  const auto started = std::chrono::steady_clock::now();
  pw::codecbench::Encoded encoded;
  if (!pw::codecbench::Encode(codec, pw::codecbench::ScalarType::kU8,
                              parameters, transformed, &encoded, error)) {
    return false;
  }
  arm->name = name;
  arm->backend = backend;
  arm->frame = encoded.bytes;
  arm->encode_ms = static_cast<std::uint64_t>(
      std::chrono::duration_cast<std::chrono::milliseconds>(
          std::chrono::steady_clock::now() - started)
          .count());
  arm->decoder = [encoded](const std::vector<std::uint8_t> &frame,
                           std::vector<std::uint8_t> *decoded,
                           std::string *decode_error) mutable {
    encoded.bytes = frame;
    return pw::codecbench::Decode(encoded, decoded, decode_error);
  };
  return true;
}

bool EncodeZpaq(const std::vector<std::uint8_t> &transformed,
                const std::string &run_directory, EncodedArm *arm,
                std::string *error) {
  const std::string input = run_directory + "/zpaq.input";
  const std::string frame = run_directory + "/zpaq.frame";
  if (!WriteFile(input, transformed, error)) {
    return false;
  }
  const auto started = std::chrono::steady_clock::now();
  const int status = pw_zpaq_compress_file(input.c_str(), frame.c_str(), 5,
                                           pw_zpaq_cancellation_generation());
  if (status != PW_ZPAQ_OK || !ReadFile(frame, &arm->frame, error)) {
    return FailBool(std::string("ZPAQ encode failed: ") +
                        pw_zpaq_error_message(status) + " " +
                        pw_zpaq_last_error(),
                    error);
  }
  arm->name = "zpaq_method5";
  arm->backend = kZpaqMethod5;
  arm->encode_ms = static_cast<std::uint64_t>(
      std::chrono::duration_cast<std::chrono::milliseconds>(
          std::chrono::steady_clock::now() - started)
          .count());
  arm->decoder = [run_directory](const std::vector<std::uint8_t> &bytes,
                                 std::vector<std::uint8_t> *decoded,
                                 std::string *decode_error) {
    const std::string input_path = run_directory + "/zpaq.decode.frame";
    const std::string output_path = run_directory + "/zpaq.decode.raw";
    if (!WriteFile(input_path, bytes, decode_error)) {
      return false;
    }
    const int decode_status =
        pw_zpaq_decompress_file(input_path.c_str(), output_path.c_str(),
                                pw_zpaq_cancellation_generation());
    if (decode_status != PW_ZPAQ_OK) {
      return FailBool(std::string("ZPAQ decode failed: ") +
                          pw_zpaq_error_message(decode_status) + " " +
                          pw_zpaq_last_error(),
                      decode_error);
    }
    return ReadFile(output_path, decoded, decode_error);
  };
  return true;
}

bool EncodeB2nd(const std::vector<std::uint8_t> &transformed, EncodedArm *arm,
                std::string *error) {
  const auto started = std::chrono::steady_clock::now();
  // One B2ND element is one fixed-width descriptor record. This keeps the
  // logical [descriptor_count, 128] array exact while allowing SHUFFLE and
  // BYTEDELTA to see all 128 byte lanes of each record.
  int64_t shape[] = {kDescriptorCount};
  int32_t chunkshape[] = {kDescriptorCount};
  int32_t blockshape[] = {kRootCount};
  blosc2_cparams cparams = BLOSC2_CPARAMS_DEFAULTS;
  cparams.compcode = BLOSC_ZSTD;
  cparams.clevel = 9;
  cparams.typesize = kDimension;
  cparams.splitmode = BLOSC_ALWAYS_SPLIT;
  cparams.nthreads = 1;
  cparams.filters[BLOSC2_MAX_FILTERS - 2] = BLOSC_SHUFFLE;
  cparams.filters[BLOSC2_MAX_FILTERS - 1] = BLOSC_FILTER_BYTEDELTA;
  cparams.filters_meta[BLOSC2_MAX_FILTERS - 1] = 0;
  blosc2_dparams dparams = BLOSC2_DPARAMS_DEFAULTS;
  dparams.nthreads = 1;
  blosc2_storage storage = {.cparams = &cparams, .dparams = &dparams};
  storage.contiguous = true;
  b2nd_context_t *context = b2nd_create_ctx(&storage, 1, shape, chunkshape,
                                            blockshape, nullptr, 0, nullptr, 0);
  if (context == nullptr) {
    return FailBool("B2ND failed to create context", error);
  }
  b2nd_array_t *array = nullptr;
  const int create_status = b2nd_from_cbuffer(
      context, &array, transformed.data(), transformed.size());
  if (create_status < 0 || array == nullptr) {
    b2nd_free_ctx(context);
    return FailBool(
        "B2ND failed to encode array: " + std::to_string(create_status), error);
  }
  std::uint8_t *frame = nullptr;
  std::int64_t frame_size = 0;
  bool needs_free = false;
  const int frame_status =
      b2nd_to_cframe(array, &frame, &frame_size, &needs_free);
  if (frame_status < 0 || frame == nullptr || frame_size <= 0) {
    b2nd_free(array);
    b2nd_free_ctx(context);
    return FailBool("B2ND failed to serialize cframe: " +
                        std::to_string(frame_status),
                    error);
  }
  arm->frame.assign(frame, frame + frame_size);
  if (needs_free) {
    std::free(frame);
  }
  b2nd_free(array);
  b2nd_free_ctx(context);
  arm->name = "b2nd_zstd9_shuffle_bytedelta";
  arm->backend = kB2ndZstd9ShuffleBytedelta;
  arm->encode_ms = static_cast<std::uint64_t>(
      std::chrono::duration_cast<std::chrono::milliseconds>(
          std::chrono::steady_clock::now() - started)
          .count());
  arm->decoder = [](const std::vector<std::uint8_t> &bytes,
                    std::vector<std::uint8_t> *decoded,
                    std::string *decode_error) {
    b2nd_array_t *decoded_array = nullptr;
    const int status =
        b2nd_from_cframe(const_cast<std::uint8_t *>(bytes.data()), bytes.size(),
                         true, &decoded_array);
    if (status < 0 || decoded_array == nullptr) {
      return FailBool("B2ND failed to deserialize cframe: " +
                          std::to_string(status),
                      decode_error);
    }
    decoded->resize(kRawBytes);
    const int copy_status =
        b2nd_to_cbuffer(decoded_array, decoded->data(), decoded->size());
    b2nd_free(decoded_array);
    if (copy_status < 0) {
      return FailBool("B2ND failed to copy decoded array: " +
                          std::to_string(copy_status),
                      decode_error);
    }
    return true;
  };
  return true;
}

bool EncodeAce(const std::vector<std::uint8_t> &transformed,
               const std::string &zli, const std::string &run_directory,
               EncodedArm *arm, std::string *error) {
  const std::string samples = run_directory + "/ace_samples";
  const std::string sample = samples + "/chunk.bin";
  const std::string compressor = run_directory + "/ace.compressor";
  const std::string frame = run_directory + "/ace.frame.zl";
  std::error_code directory_error;
  std::filesystem::create_directories(samples, directory_error);
  if (directory_error || !WriteFile(sample, transformed, error)) {
    return FailBool("cannot prepare ACE sample directory", error);
  }
  const auto started = std::chrono::steady_clock::now();
  if (!RunProcess({zli, "--profile", "serial", "train", samples,
                   "--no-clustering", "--use-all-samples", "--max-time-secs",
                   "300", "--threads", "8", "-o", compressor, "-f"},
                  error) ||
      !RunProcess({zli, "compress", sample, "-c", compressor, "-o", frame,
                   "--strict", "-f"},
                  error) ||
      !ReadFile(frame, &arm->frame, error)) {
    return false;
  }
  std::error_code size_error;
  arm->encoder_model_bytes = std::filesystem::file_size(compressor, size_error);
  if (size_error) {
    return FailBool("cannot measure ACE training-time compressor", error);
  }
  arm->name = "openzl_ace_serial_no_clustering";
  arm->backend = kOpenZlAceNoClustering;
  arm->encode_ms = static_cast<std::uint64_t>(
      std::chrono::duration_cast<std::chrono::milliseconds>(
          std::chrono::steady_clock::now() - started)
          .count());
  arm->decoder = [zli, run_directory](const std::vector<std::uint8_t> &bytes,
                                      std::vector<std::uint8_t> *decoded,
                                      std::string *decode_error) {
    const std::string input = run_directory + "/ace.decode.frame.zl";
    const std::string output = run_directory + "/ace.decode.raw";
    if (!WriteFile(input, bytes, decode_error) ||
        !RunProcess({zli, "decompress", input, "-o", output, "-f"},
                    decode_error)) {
      return false;
    }
    return ReadFile(output, decoded, decode_error);
  };
  return true;
}

bool ValidateArm(const EncodedArm &arm,
                 const std::vector<std::uint8_t> &transformed,
                 const std::vector<std::uint8_t> &parent_sidecar,
                 const std::vector<std::uint8_t> &original, ArmResult *result,
                 std::string *error) {
  pw::descriptor_chunk::ArchiveFields fields;
  fields.backend = arm.backend;
  fields.descriptor_count = kDescriptorCount;
  fields.dimension = kDimension;
  fields.root_count = kRootCount;
  fields.transformed_sha256 = pw::descriptor_chunk::Sha256(transformed);
  fields.original_sha256 = pw::descriptor_chunk::Sha256(original);
  std::vector<std::uint8_t> archive;
  if (!pw::descriptor_chunk::BuildArchive(fields, arm.frame, parent_sidecar,
                                          &archive, error)) {
    return false;
  }
  pw::descriptor_chunk::ParsedArchive parsed;
  if (!pw::descriptor_chunk::ParseArchive(archive, &parsed, error)) {
    return false;
  }
  const auto decode_started = std::chrono::steady_clock::now();
  std::vector<std::uint8_t> decoded_transformed;
  if (!arm.decoder(parsed.frame, &decoded_transformed, error)) {
    return false;
  }
  result->decode_ms = static_cast<std::uint64_t>(
      std::chrono::duration_cast<std::chrono::milliseconds>(
          std::chrono::steady_clock::now() - decode_started)
          .count());
  std::vector<std::uint8_t> decoded_original;
  if (!DecodeOriginal(decoded_transformed, parsed.parents, &decoded_original,
                      error) ||
      !pw::descriptor_chunk::VerifyDecoded(parsed, decoded_transformed,
                                           decoded_original, error)) {
    return false;
  }

  std::vector<std::uint8_t> corrupted = archive;
  corrupted[pw::descriptor_chunk::kArchiveHeaderBytes + arm.frame.size() / 2] ^=
      1u;
  pw::descriptor_chunk::ParsedArchive corrupted_parsed;
  std::string corruption_error;
  result->corruption_rejected = !pw::descriptor_chunk::ParseArchive(
      corrupted, &corrupted_parsed, &corruption_error);
  result->name = arm.name;
  result->codec_frame_bytes = arm.frame.size();
  result->parent_sidecar_bytes = parent_sidecar.size();
  result->archive_envelope_bytes = pw::descriptor_chunk::kArchiveHeaderBytes;
  result->complete_persisted_bytes = archive.size();
  result->encoder_model_bytes = arm.encoder_model_bytes;
  result->encode_ms = arm.encode_ms;
  result->transformed_bytes_equal = decoded_transformed == transformed;
  result->transformed_sha256_equal =
      pw::descriptor_chunk::Sha256(decoded_transformed) ==
      pw::descriptor_chunk::Sha256(transformed);
  result->parent_sidecar_equal = parsed.parents == parent_sidecar;
  result->original_bytes_equal = decoded_original == original;
  result->original_sha256_equal =
      pw::descriptor_chunk::Sha256(decoded_original) ==
      pw::descriptor_chunk::Sha256(original);
  result->frame_sha256 = Hex(pw::descriptor_chunk::Sha256(arm.frame));
  result->archive_sha256 = Hex(pw::descriptor_chunk::Sha256(archive));
  if (!result->transformed_bytes_equal || !result->transformed_sha256_equal ||
      !result->parent_sidecar_equal || !result->original_bytes_equal ||
      !result->original_sha256_equal || !result->corruption_rejected) {
    return FailBool("one or more exactness gates failed for " + arm.name,
                    error);
  }
  return true;
}

void WriteArmJson(const ArmResult &arm, std::ostream *output) {
  *output << "{\"name\":\"" << arm.name
          << "\",\"codec_frame_bytes\":" << arm.codec_frame_bytes
          << ",\"parent_sidecar_bytes\":" << arm.parent_sidecar_bytes
          << ",\"archive_envelope_bytes\":" << arm.archive_envelope_bytes
          << ",\"complete_persisted_bytes\":" << arm.complete_persisted_bytes
          << ",\"encoder_model_bytes\":" << arm.encoder_model_bytes
          << ",\"encode_ms\":" << arm.encode_ms
          << ",\"decode_ms\":" << arm.decode_ms
          << ",\"transformed_bytes_equal\":"
          << (arm.transformed_bytes_equal ? 1 : 0)
          << ",\"transformed_sha256_equal\":"
          << (arm.transformed_sha256_equal ? 1 : 0)
          << ",\"parent_sidecar_equal\":" << (arm.parent_sidecar_equal ? 1 : 0)
          << ",\"original_bytes_equal\":" << (arm.original_bytes_equal ? 1 : 0)
          << ",\"original_sha256_equal\":"
          << (arm.original_sha256_equal ? 1 : 0)
          << ",\"corruption_rejected\":" << (arm.corruption_rejected ? 1 : 0)
          << ",\"frame_sha256\":\"" << arm.frame_sha256
          << "\",\"archive_sha256\":\"" << arm.archive_sha256 << "\"}";
}

} // namespace

int main(int argc, char **argv) {
  if (argc != 5) {
    return Fail("usage: bench <source.db> <zli> <run-directory> <result.json>");
  }
  const std::string source = argv[1];
  const std::string zli = argv[2];
  const std::string run_directory = argv[3];
  const std::string result_path = argv[4];
  std::string error;
  std::string source_sha_before;
  std::uint64_t source_bytes_before = 0;
  if (!FileSha256(source, &source_sha_before, &source_bytes_before, &error) ||
      source_bytes_before != kSourceBytes ||
      source_sha_before != kSourceSha256) {
    return Fail("immutable source identity failed: " + error);
  }
  if (std::strcmp(pw_zpaq_version(), "7.15") != 0 ||
      std::strcmp(
          pw_zpaq_revision(),
          "e85ec2529eb0ba22ceaeabd461e55357ef099b80f61c14f377b429ea3d49d418") !=
          0) {
    return Fail("unexpected ZPAQ identity");
  }

  std::vector<std::uint8_t> original;
  std::vector<std::uint8_t> transformed;
  std::vector<std::uint8_t> parent_sidecar;
  std::vector<std::uint64_t> parents;
  if (!ReadDescriptorChunk(source, &original, &error) ||
      !BuildFrozenChunk(original, &transformed, &parent_sidecar, &parents,
                        &error)) {
    return Fail(error);
  }
  if (original.size() != kRawBytes || transformed.size() != kRawBytes) {
    return Fail("frozen chunk byte count changed");
  }

  blosc2_init();
  std::vector<EncodedArm> encoded_arms;
  EncodedArm arm;
  if (!EncodeZpaq(transformed, run_directory, &arm, &error)) {
    blosc2_destroy();
    return Fail(error);
  }
  encoded_arms.push_back(std::move(arm));

  pw::codecbench::Parameters parameters;
  parameters.level = 12;
  parameters.element_width = 1;
  arm = {};
  if (!EncodeExisting("pcodec_level12_u8", kPcodecLevel12U8,
                      pw::codecbench::Codec::kPcodec, parameters, transformed,
                      &arm, &error)) {
    blosc2_destroy();
    return Fail(error);
  }
  encoded_arms.push_back(std::move(arm));

  parameters.level = 6;
  parameters.element_width = 1;
  arm = {};
  if (!EncodeExisting("openzl_existing_numeric_level6",
                      kOpenZlExistingNumericLevel6,
                      pw::codecbench::Codec::kOpenZl, parameters, transformed,
                      &arm, &error)) {
    blosc2_destroy();
    return Fail(error);
  }
  encoded_arms.push_back(std::move(arm));

  const std::array<std::pair<int, std::pair<std::uint8_t, const char *>>, 3>
      blosc_arms = {
          {{BLOSC_NOSHUFFLE, {kBlosc2Zstd9None, "blosc2_zstd9_none"}},
           {BLOSC_SHUFFLE, {kBlosc2Zstd9Shuffle, "blosc2_zstd9_shuffle"}},
           {BLOSC_BITSHUFFLE,
            {kBlosc2Zstd9Bitshuffle, "blosc2_zstd9_bitshuffle"}}}};
  for (const auto &configuration : blosc_arms) {
    parameters.level = 9;
    parameters.element_width = kDimension;
    parameters.filter = configuration.first;
    arm = {};
    if (!EncodeExisting(configuration.second.second, configuration.second.first,
                        pw::codecbench::Codec::kBlosc2, parameters, transformed,
                        &arm, &error)) {
      blosc2_destroy();
      return Fail(error);
    }
    encoded_arms.push_back(std::move(arm));
  }

  arm = {};
  if (!EncodeB2nd(transformed, &arm, &error)) {
    blosc2_destroy();
    return Fail(error);
  }
  encoded_arms.push_back(std::move(arm));

  arm = {};
  if (!EncodeAce(transformed, zli, run_directory, &arm, &error)) {
    blosc2_destroy();
    return Fail(error);
  }
  encoded_arms.push_back(std::move(arm));

  std::vector<ArmResult> results;
  for (const EncodedArm &encoded : encoded_arms) {
    ArmResult result;
    if (!ValidateArm(encoded, transformed, parent_sidecar, original, &result,
                     &error)) {
      blosc2_destroy();
      return Fail(error);
    }
    std::cout << "PW_DESCRIPTOR_CHUNK_ARM_OK name=" << result.name
              << " complete_persisted_bytes=" << result.complete_persisted_bytes
              << '\n'
              << std::flush;
    results.push_back(std::move(result));
  }
  blosc2_destroy();

  std::string source_sha_after;
  std::uint64_t source_bytes_after = 0;
  if (!FileSha256(source, &source_sha_after, &source_bytes_after, &error)) {
    return Fail(error);
  }
  const bool source_unchanged = source_bytes_after == source_bytes_before &&
                                source_sha_after == source_sha_before;
  if (!source_unchanged) {
    return Fail("source changed during the micro benchmark");
  }
  const auto winner = std::min_element(
      results.begin(), results.end(),
      [](const ArmResult &left, const ArmResult &right) {
        return left.complete_persisted_bytes < right.complete_persisted_bytes;
      });

  std::ofstream output(result_path, std::ios::trunc);
  if (!output) {
    return Fail("cannot create result JSON");
  }
  output
      << "{\"schema\":\"pw_descriptor_chunk_official_backends_result_v1\""
      << ",\"scope\":\"host_only_micro_benchmark\""
      << ",\"production_promoted\":0"
      << ",\"source_bytes\":" << source_bytes_before << ",\"source_sha256\":\""
      << source_sha_before << "\""
      << ",\"source_unchanged\":" << (source_unchanged ? 1 : 0)
      << ",\"descriptor_count\":" << kDescriptorCount
      << ",\"dimension\":" << kDimension
      << ",\"raw_descriptor_bytes\":" << kRawBytes
      << ",\"root_count\":" << kRootCount
      << ",\"predicted_count\":" << kDescriptorCount - kRootCount
      << ",\"parent_sidecar_bytes\":" << parent_sidecar.size()
      << ",\"original_chunk_sha256\":\""
      << Hex(pw::descriptor_chunk::Sha256(original)) << "\""
      << ",\"transformed_chunk_sha256\":\""
      << Hex(pw::descriptor_chunk::Sha256(transformed)) << "\""
      << ",\"openzl_ace_profile\":\"serial\""
      << ",\"upstreams\":{\"openzl\":\"0.2.0@"
         "3dceb64867840201fb8f57a29d179995f700c9b8\""
      << ",\"c_blosc2\":\"3.3.0@7265419b23872707b1b52298d5f1469c9ea7b9e7\""
      << ",\"pcodec\":\"1.0.2@2d8555888b21bbaa19326580b740fa24b7da6bd3\""
      << ",\"zpaq\":\"7.15@"
         "e85ec2529eb0ba22ceaeabd461e55357ef099b80f61c14f377b429ea3d49d418\"}"
      << ",\"arms\":[";
  for (std::size_t index = 0; index < results.size(); ++index) {
    if (index != 0) {
      output << ',';
    }
    WriteArmJson(results[index], &output);
  }
  output << "],\"winner\":\"" << winner->name
         << "\",\"winner_complete_persisted_bytes\":"
         << winner->complete_persisted_bytes << ",\"stop_after_one_chunk\":1}"
         << '\n';
  output.flush();
  if (!output) {
    return Fail("failed to write result JSON");
  }
  std::cout << "PW_DESCRIPTOR_CHUNK_OFFICIAL_BACKENDS_OK winner="
            << winner->name
            << " complete_persisted_bytes=" << winner->complete_persisted_bytes
            << '\n';
  return 0;
}
