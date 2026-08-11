#include "pwa2_sqlite_logical_archive.h"

#include <sqlite3.h>

#include <cstring>
#include <array>
#include <algorithm>
#include <cstdint>
#include <iostream>
#include <string>
#include <vector>

namespace {

bool IntegrityOk(const std::string& path) {
  sqlite3* database = nullptr;
  const std::string uri = "file:" + path + "?immutable=1";
  if (sqlite3_open_v2(uri.c_str(), &database,
                      SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nullptr) !=
      SQLITE_OK) {
    if (database != nullptr) {
      sqlite3_close(database);
    }
    return false;
  }
  sqlite3_stmt* statement = nullptr;
  bool ok = sqlite3_prepare_v2(database, "PRAGMA integrity_check", -1,
                               &statement, nullptr) == SQLITE_OK &&
            sqlite3_step(statement) == SQLITE_ROW;
  if (ok) {
    const char* value = reinterpret_cast<const char*>(
        sqlite3_column_text(statement, 0));
    ok = value != nullptr && std::strcmp(value, "ok") == 0;
  }
  sqlite3_finalize(statement);
  sqlite3_close(database);
  return ok;
}

struct DescriptorRequest {
  std::int64_t image_id = 0;
  std::int64_t row = 0;
  std::array<std::uint8_t, 128> expected{};
};

bool RandomReadsExact(const std::string& source,
                      const std::string& members,
                      std::uint64_t* maximum_members_touched,
                      std::string* error) {
  sqlite3* database = nullptr;
  if (sqlite3_open_v2(source.c_str(), &database, SQLITE_OPEN_READONLY,
                      nullptr) != SQLITE_OK) {
    return false;
  }
  sqlite3_stmt* statement = nullptr;
  if (sqlite3_prepare_v2(database,
                         "SELECT image_id,rows,cols,data FROM descriptors "
                         "ORDER BY image_id",
                         -1, &statement, nullptr) != SQLITE_OK) {
    sqlite3_close(database);
    return false;
  }
  std::vector<DescriptorRequest> all;
  while (sqlite3_step(statement) == SQLITE_ROW) {
    const std::int64_t image_id = sqlite3_column_int64(statement, 0);
    const std::int64_t rows = sqlite3_column_int64(statement, 1);
    const std::int64_t columns = sqlite3_column_int64(statement, 2);
    const auto* data = static_cast<const std::uint8_t*>(
        sqlite3_column_blob(statement, 3));
    const int bytes = sqlite3_column_bytes(statement, 3);
    if (rows < 0 || columns != 128 || data == nullptr ||
        bytes != rows * 128) {
      sqlite3_finalize(statement);
      sqlite3_close(database);
      return false;
    }
    for (std::int64_t row = 0; row < rows; ++row) {
      DescriptorRequest request;
      request.image_id = image_id;
      request.row = row;
      std::copy_n(data + row * 128, 128, request.expected.begin());
      all.push_back(request);
    }
  }
  sqlite3_finalize(statement);
  sqlite3_close(database);
  if (all.empty()) {
    return false;
  }
  const std::array<std::size_t, 3> ordinals = {
      0, all.size() / 2, all.size() - 1};
  *maximum_members_touched = 0;
  for (const std::size_t ordinal : ordinals) {
    std::array<std::uint8_t, 128> actual{};
    std::uint64_t touched = 0;
    const DescriptorRequest& request = all[ordinal];
    if (pw::pwa2::ReadDescriptor(members, request.image_id, request.row,
                                 &actual, &touched, error) !=
            pw::pwa2::Status::kOk ||
        actual != request.expected || touched == 0) {
      return false;
    }
    *maximum_members_touched = std::max(*maximum_members_touched, touched);
  }
  return true;
}

}  // namespace

int main(int argc, char** argv) {
  if (argc != 4) {
    std::cerr << "usage: pwa2-verify <source.db> <members> <materialized.db>\n";
    return 2;
  }
  const std::string source = argv[1];
  const std::string members = argv[2];
  const std::string materialized = argv[3];
  pw::pwa2::Verification verification;
  std::string error;
  if (pw::pwa2::VerifyDatabase(source, members, &verification, &error) !=
          pw::pwa2::Status::kOk ||
      pw::pwa2::MaterializeDatabase(members, materialized, &error) !=
          pw::pwa2::Status::kOk) {
    std::cerr << "PWA2 verify/materialize failed: " << error << '\n';
    return 3;
  }
  bool logical_equal = false;
  std::uint64_t maximum_members_touched = 0;
  if (pw::pwa2::CompareDatabasesLogical(source, materialized, &logical_equal,
                                        &error) != pw::pwa2::Status::kOk ||
      !logical_equal || !IntegrityOk(materialized) ||
      !RandomReadsExact(source, members, &maximum_members_touched, &error)) {
    std::cerr << "PWA2 materialized database differs: " << error << '\n';
    return 4;
  }
  std::cout << "{\"all_tables_covered\":"
            << (verification.all_tables_covered ? 1 : 0)
            << ",\"all_cells_equal\":"
            << (verification.all_cells_equal ? 1 : 0)
            << ",\"all_rows_and_order_equal\":"
            << (verification.all_rows_and_order_equal ? 1 : 0)
            << ",\"source_logical_sha256\":\""
            << verification.source_logical_sha256
            << "\",\"restored_logical_sha256\":\""
            << verification.restored_logical_sha256
            << "\",\"materialized_sqlite_integrity_ok\":1"
            << ",\"random_reads_exact\":1"
            << ",\"random_read_maximum_members_touched\":"
            << maximum_members_touched << "}\n";
  return 0;
}
