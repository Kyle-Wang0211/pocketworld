#import <Foundation/Foundation.h>

#include <sqlite3.h>

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

extern "C" int aether_gpu_match_gemm_pairs(
    const std::uint8_t* dA, int nA, const std::uint8_t* dB, int nB,
    double max_ratio, std::uint32_t* out_pairs, int max_pairs,
    int* out_num_matches);

namespace {

constexpr std::int64_t kMaxNumImages = 2147483647LL;

struct DescriptorTable {
  int rows = 0;
  int cols = 0;
  std::vector<std::uint8_t> bytes;
};

[[noreturn]] void fail(const char* message) {
  std::fprintf(stderr, "FAIL: %s\n", message);
  std::exit(1);
}

DescriptorTable loadDescriptors(sqlite3* db, int image_id) {
  sqlite3_stmt* statement = nullptr;
  const char* sql =
      "SELECT rows, cols, data FROM descriptors WHERE image_id = ?";
  if (sqlite3_prepare_v2(db, sql, -1, &statement, nullptr) != SQLITE_OK) {
    fail(sqlite3_errmsg(db));
  }
  sqlite3_bind_int(statement, 1, image_id);
  if (sqlite3_step(statement) != SQLITE_ROW) {
    sqlite3_finalize(statement);
    fail("descriptor row not found");
  }
  DescriptorTable table;
  table.rows = sqlite3_column_int(statement, 0);
  table.cols = sqlite3_column_int(statement, 1);
  const int byte_count = sqlite3_column_bytes(statement, 2);
  const auto* data = static_cast<const std::uint8_t*>(
      sqlite3_column_blob(statement, 2));
  if (table.rows <= 0 || table.cols != 128 || data == nullptr ||
      byte_count != table.rows * table.cols) {
    sqlite3_finalize(statement);
    fail("invalid descriptor blob shape");
  }
  table.bytes.assign(data, data + byte_count);
  sqlite3_finalize(statement);
  return table;
}

std::vector<std::uint32_t> loadStoredPairs(sqlite3* db, int image_a,
                                           int image_b) {
  const int low = std::min(image_a, image_b);
  const int high = std::max(image_a, image_b);
  const std::int64_t pair_id =
      static_cast<std::int64_t>(low) * kMaxNumImages + high;
  sqlite3_stmt* statement = nullptr;
  const char* sql = "SELECT rows, cols, data FROM matches WHERE pair_id = ?";
  if (sqlite3_prepare_v2(db, sql, -1, &statement, nullptr) != SQLITE_OK) {
    fail(sqlite3_errmsg(db));
  }
  sqlite3_bind_int64(statement, 1, pair_id);
  if (sqlite3_step(statement) != SQLITE_ROW) {
    sqlite3_finalize(statement);
    fail("stored match row not found");
  }
  const int rows = sqlite3_column_int(statement, 0);
  const int cols = sqlite3_column_int(statement, 1);
  const int byte_count = sqlite3_column_bytes(statement, 2);
  const auto* data = static_cast<const std::uint32_t*>(
      sqlite3_column_blob(statement, 2));
  if (rows < 0 || cols != 2 || byte_count != rows * cols * 4 ||
      (rows > 0 && data == nullptr)) {
    sqlite3_finalize(statement);
    fail("invalid stored match blob shape");
  }
  std::vector<std::uint32_t> pairs(data, data + rows * 2);
  sqlite3_finalize(statement);
  if (image_a > image_b) {
    for (int row = 0; row < rows; ++row) {
      std::swap(pairs[2 * row], pairs[2 * row + 1]);
    }
  }
  return pairs;
}

std::vector<std::uint64_t> pairKeys(const std::vector<std::uint32_t>& pairs) {
  std::vector<std::uint64_t> keys;
  keys.reserve(pairs.size() / 2);
  for (std::size_t index = 0; index + 1 < pairs.size(); index += 2) {
    keys.push_back((static_cast<std::uint64_t>(pairs[index]) << 32) |
                   pairs[index + 1]);
  }
  std::sort(keys.begin(), keys.end());
  return keys;
}

}  // namespace

int main(int argc, char** argv) {
  @autoreleasepool {
    if (argc < 4 || argc > 5) {
      std::fprintf(stderr,
                   "usage: %s <sfm_live.db> <image_a> <image_b> [iterations]\n",
                   argv[0]);
      return 2;
    }
    const int image_a = std::atoi(argv[2]);
    const int image_b = std::atoi(argv[3]);
    const int iterations = argc == 5 ? std::max(1, std::atoi(argv[4])) : 3;
    sqlite3* db = nullptr;
    if (sqlite3_open_v2(argv[1], &db, SQLITE_OPEN_READONLY, nullptr) !=
        SQLITE_OK) {
      fail(db ? sqlite3_errmsg(db) : "sqlite open failed");
    }
    const DescriptorTable a = loadDescriptors(db, image_a);
    const DescriptorTable b = loadDescriptors(db, image_b);
    const std::vector<std::uint32_t> stored =
        loadStoredPairs(db, image_a, image_b);
    sqlite3_close(db);

    std::vector<std::uint32_t> output(
        static_cast<std::size_t>(std::min(a.rows, b.rows)) * 2);
    std::vector<double> elapsed_ms;
    int output_count = 0;
    int rc = -1;
    for (int iteration = 0; iteration < iterations; ++iteration) {
      output_count = 0;
      const auto start = std::chrono::steady_clock::now();
      rc = aether_gpu_match_gemm_pairs(
          a.bytes.data(), a.rows, b.bytes.data(), b.rows, 0.7,
          output.data(), std::min(a.rows, b.rows), &output_count);
      const auto stop = std::chrono::steady_clock::now();
      elapsed_ms.push_back(
          std::chrono::duration<double, std::milli>(stop - start).count());
      if (rc != 0) break;
    }
    output.resize(static_cast<std::size_t>(std::max(0, output_count)) * 2);
    const bool exact_sequence = output == stored;
    const bool exact_set = pairKeys(output) == pairKeys(stored);
    std::printf(
        "{\"rc\":%d,\"image_a\":%d,\"image_b\":%d,"
        "\"rows_a\":%d,\"rows_b\":%d,\"stored_matches\":%zu,"
        "\"gpu_matches\":%d,\"exact_sequence\":%s,\"exact_set\":%s,"
        "\"elapsed_ms\":[",
        rc, image_a, image_b, a.rows, b.rows, stored.size() / 2,
        output_count, exact_sequence ? "true" : "false",
        exact_set ? "true" : "false");
    for (std::size_t index = 0; index < elapsed_ms.size(); ++index) {
      if (index) std::printf(",");
      std::printf("%.3f", elapsed_ms[index]);
    }
    std::printf("]}\n");
    return rc == 0 && exact_set ? 0 : 1;
  }
}
