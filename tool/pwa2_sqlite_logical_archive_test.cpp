#include "pwa2_sqlite_logical_archive.h"

#include <sqlite3.h>
#include <unistd.h>

#include <array>
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <limits>
#include <string>
#include <vector>

namespace {

int Fail(const std::string& message) {
  std::fprintf(stderr, "PW_PWA2_LOGICAL_ARCHIVE_TEST_FAILED: %s\n",
               message.c_str());
  return 1;
}

bool Exec(sqlite3* database, const char* sql, std::string* error) {
  char* sqlite_error = nullptr;
  const int status = sqlite3_exec(database, sql, nullptr, nullptr, &sqlite_error);
  if (status == SQLITE_OK) {
    return true;
  }
  *error = sqlite_error == nullptr ? sqlite3_errmsg(database) : sqlite_error;
  sqlite3_free(sqlite_error);
  return false;
}

bool InsertBlob(sqlite3* database,
                const char* sql,
                const std::vector<std::uint8_t>& blob,
                std::string* error) {
  sqlite3_stmt* statement = nullptr;
  if (sqlite3_prepare_v2(database, sql, -1, &statement, nullptr) != SQLITE_OK) {
    *error = sqlite3_errmsg(database);
    return false;
  }
  const int bind_status = sqlite3_bind_blob(
      statement, 1, blob.data(), static_cast<int>(blob.size()), SQLITE_TRANSIENT);
  const int step_status = bind_status == SQLITE_OK ? sqlite3_step(statement)
                                                    : bind_status;
  if (step_status != SQLITE_DONE) {
    *error = sqlite3_errmsg(database);
    sqlite3_finalize(statement);
    return false;
  }
  sqlite3_finalize(statement);
  return true;
}

std::array<std::uint8_t, 128> DescriptorBytes(std::int64_t image_id,
                                              std::int64_t row) {
  std::array<std::uint8_t, 128> descriptor{};
  for (std::size_t column = 0; column < descriptor.size(); ++column) {
    descriptor[column] = static_cast<std::uint8_t>(
        image_id * 17 + row * 29 + static_cast<std::int64_t>(column) * 7);
  }
  return descriptor;
}

std::vector<std::uint8_t> PairBlob(
    const std::vector<std::pair<std::uint32_t, std::uint32_t>>& pairs) {
  std::vector<std::uint8_t> bytes;
  bytes.reserve(pairs.size() * 2 * sizeof(std::uint32_t));
  for (const auto& pair : pairs) {
    for (const std::uint32_t value : {pair.first, pair.second}) {
      for (int shift = 0; shift < 32; shift += 8) {
        bytes.push_back(static_cast<std::uint8_t>(value >> shift));
      }
    }
  }
  return bytes;
}

std::int64_t PairId(std::int64_t first, std::int64_t second) {
  constexpr std::int64_t kMaximumImageId = 2147483647LL;
  return std::min(first, second) * kMaximumImageId + std::max(first, second);
}

bool InsertPair(sqlite3* database,
                std::int64_t first,
                std::int64_t second,
                const std::vector<std::pair<std::uint32_t, std::uint32_t>>& pairs,
                std::string* error) {
  const std::vector<std::uint8_t> bytes = PairBlob(pairs);
  const std::string pair_id = std::to_string(PairId(first, second));
  const std::string rows = std::to_string(pairs.size());
  if (!InsertBlob(database,
                  ("INSERT INTO matches VALUES(" + pair_id + "," + rows +
                   ",2,?1)")
                      .c_str(),
                  bytes, error)) {
    return false;
  }
  return InsertBlob(
      database,
      ("INSERT INTO two_view_geometries VALUES(" + pair_id + "," + rows +
       ",2,?1,2,NULL,NULL,NULL,NULL,NULL)")
          .c_str(),
      bytes, error);
}

bool CreateFixture(const std::string& path, std::string* error) {
  sqlite3* database = nullptr;
  if (sqlite3_open(path.c_str(), &database) != SQLITE_OK) {
    *error = database == nullptr ? "sqlite open failed" : sqlite3_errmsg(database);
    if (database != nullptr) {
      sqlite3_close(database);
    }
    return false;
  }

  const char* schema = R"sql(
    PRAGMA journal_mode=DELETE;
    PRAGMA foreign_keys=OFF;
    CREATE TABLE rigs(rig_id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
      ref_sensor_id INTEGER NOT NULL, ref_sensor_type INTEGER NOT NULL);
    CREATE UNIQUE INDEX rig_ref_sensor_assignment
      ON rigs(ref_sensor_id, ref_sensor_type);
    CREATE TABLE rig_sensors(rig_id INTEGER NOT NULL, sensor_id INTEGER NOT NULL,
      sensor_type INTEGER NOT NULL, sensor_from_rig BLOB);
    CREATE UNIQUE INDEX rig_sensor_assignment
      ON rig_sensors(sensor_id, sensor_type);
    CREATE TABLE cameras(camera_id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
      model INTEGER NOT NULL, width INTEGER NOT NULL, height INTEGER NOT NULL,
      params BLOB, prior_focal_length INTEGER NOT NULL);
    CREATE TABLE frames(frame_id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
      rig_id INTEGER NOT NULL);
    CREATE TABLE frame_data(frame_id INTEGER NOT NULL, data_id INTEGER NOT NULL,
      sensor_id INTEGER NOT NULL, sensor_type INTEGER NOT NULL);
    CREATE UNIQUE INDEX frame_sensor_assignment
      ON frame_data(data_id, sensor_type);
    CREATE TABLE images(image_id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
      name TEXT NOT NULL UNIQUE, camera_id INTEGER NOT NULL);
    CREATE UNIQUE INDEX index_name ON images(name);
    CREATE TABLE pose_priors(pose_prior_id INTEGER PRIMARY KEY NOT NULL,
      corr_data_id INTEGER NOT NULL, corr_sensor_id INTEGER NOT NULL,
      corr_sensor_type INTEGER NOT NULL, position BLOB,
      position_covariance BLOB, gravity BLOB,
      coordinate_system INTEGER NOT NULL);
    CREATE UNIQUE INDEX pose_prior_data_assignment
      ON pose_priors(corr_data_id, corr_sensor_id, corr_sensor_type);
    CREATE TABLE keypoints(image_id INTEGER PRIMARY KEY NOT NULL,
      rows INTEGER NOT NULL, cols INTEGER NOT NULL, data BLOB);
    CREATE TABLE descriptors(image_id INTEGER PRIMARY KEY NOT NULL,
      type INTEGER NOT NULL, rows INTEGER NOT NULL, cols INTEGER NOT NULL,
      data BLOB);
    CREATE TABLE matches(pair_id INTEGER PRIMARY KEY NOT NULL,
      rows INTEGER NOT NULL, cols INTEGER NOT NULL, data BLOB);
    CREATE TABLE two_view_geometries(pair_id INTEGER PRIMARY KEY NOT NULL,
      rows INTEGER NOT NULL, cols INTEGER NOT NULL, data BLOB,
      config INTEGER NOT NULL, F BLOB, E BLOB, H BLOB, qvec BLOB, tvec BLOB);
    INSERT INTO cameras(camera_id,model,width,height,params,prior_focal_length)
      VALUES(7,2,4032,3024,NULL,1);
    INSERT INTO images(image_id,name,camera_id) VALUES(11,'frame_001.jpg',7);
    INSERT INTO images(image_id,name,camera_id) VALUES(12,'frame_002.jpg',7);
    INSERT INTO images(image_id,name,camera_id) VALUES(13,'frame_003.jpg',7);
  )sql";

  bool ok = Exec(database, schema, error);
  std::vector<std::uint8_t> camera_params(4 * sizeof(double));
  for (std::size_t index = 0; index < camera_params.size(); ++index) {
    camera_params[index] = static_cast<std::uint8_t>(index * 7U + 3U);
  }
  if (ok) {
    ok = InsertBlob(database,
                    "UPDATE cameras SET params=?1 WHERE camera_id=7",
                    camera_params, error);
  }

  for (const std::pair<std::int64_t, std::int64_t> image_rows :
       {std::pair<std::int64_t, std::int64_t>{11, 3}, {12, 3}, {13, 2}}) {
    std::vector<std::uint8_t> keypoints(
        static_cast<std::size_t>(image_rows.second) * 6 * sizeof(float));
    for (std::size_t index = 0; index < keypoints.size(); ++index) {
      keypoints[index] = static_cast<std::uint8_t>(
          image_rows.first * 5 + static_cast<std::int64_t>(index) * 11);
    }
    if (ok) {
      ok = InsertBlob(
          database,
          ("INSERT INTO keypoints VALUES(" + std::to_string(image_rows.first) +
           "," + std::to_string(image_rows.second) + ",6,?1)")
              .c_str(),
          keypoints, error);
    }

    std::vector<std::uint8_t> descriptors;
    descriptors.reserve(static_cast<std::size_t>(image_rows.second) * 128);
    for (std::int64_t row = 0; row < image_rows.second; ++row) {
      const std::array<std::uint8_t, 128> descriptor =
          DescriptorBytes(image_rows.first, row);
      descriptors.insert(descriptors.end(), descriptor.begin(), descriptor.end());
    }
    if (ok) {
      ok = InsertBlob(
          database,
          ("INSERT INTO descriptors VALUES(" +
           std::to_string(image_rows.first) + ",0," +
           std::to_string(image_rows.second) + ",128,?1)")
              .c_str(),
          descriptors, error);
    }
  }
  if (ok) {
    ok = InsertPair(database, 11, 12, {{0, 0}, {1, 1}}, error);
  }
  if (ok) {
    ok = InsertPair(database, 12, 13, {{0, 0}}, error);
  }
  if (ok) {
    ok = InsertPair(database, 11, 13, {{0, 0}}, error);
  }
  if (ok) {
    ok = Exec(database,
              ("INSERT INTO two_view_geometries VALUES(" +
               std::to_string(PairId(10, 11)) +
               ",0,2,NULL,2,NULL,NULL,NULL,NULL,NULL)")
                  .c_str(),
              error);
  }

  if (ok) {
    ok = Exec(database, "PRAGMA wal_checkpoint(TRUNCATE);", error);
  }
  sqlite3_close(database);
  return ok;
}

bool HasMemberPrefix(
    const std::vector<std::pair<std::string, std::vector<std::uint8_t>>>& files,
    const std::string& prefix) {
  return std::any_of(files.begin(), files.end(), [&](const auto& file) {
    return file.first.rfind(prefix, 0) == 0;
  });
}

std::vector<std::pair<std::string, std::vector<std::uint8_t>>> ReadDirectory(
    const std::string& directory) {
  std::vector<std::pair<std::string, std::vector<std::uint8_t>>> files;
  for (const auto& entry : std::filesystem::recursive_directory_iterator(
           directory)) {
    if (!entry.is_regular_file()) {
      continue;
    }
    std::ifstream input(entry.path(), std::ios::binary);
    std::vector<std::uint8_t> bytes(
        (std::istreambuf_iterator<char>(input)),
        std::istreambuf_iterator<char>());
    files.emplace_back(
        std::filesystem::relative(entry.path(), directory).generic_string(),
        std::move(bytes));
  }
  std::sort(files.begin(), files.end());
  return files;
}

}  // namespace

int main() {
  const std::filesystem::path root =
      "/private/tmp/pw_pwa2_fixture." + std::to_string(getpid());
  std::filesystem::remove_all(root);
  if (!std::filesystem::create_directory(root)) {
    return Fail("temporary directory creation failed");
  }
  const std::string source = (root / "source.db").string();
  const std::string members_a = (root / "members_a").string();
  const std::string members_b = (root / "members_b").string();
  const std::string members_full_forest =
      (root / "members_full_forest").string();
  const std::string restored = (root / "restored.db").string();
  const std::string restored_full_forest =
      (root / "restored_full_forest.db").string();

  std::string error;
  if (!CreateFixture(source, &error)) {
    std::filesystem::remove_all(root);
    return Fail("fixture creation failed: " + error);
  }

  pw::pwa2::Options options;
  options.descriptor_block_records = 2;
  pw::pwa2::Stats stats_a;
  pw::pwa2::Stats stats_b;
  if (pw::pwa2::PackDatabase(source, members_a, options, &stats_a, &error) !=
      pw::pwa2::Status::kOk) {
    std::filesystem::remove_all(root);
    return Fail("first pack failed: " + error);
  }
  if (pw::pwa2::PackDatabase(source, members_b, options, &stats_b, &error) !=
      pw::pwa2::Status::kOk) {
    std::filesystem::remove_all(root);
    return Fail("second pack failed: " + error);
  }
  if (ReadDirectory(members_a) != ReadDirectory(members_b)) {
    std::filesystem::remove_all(root);
    return Fail("pack output is not deterministic");
  }

  pw::pwa2::Options full_forest_options;
  full_forest_options.descriptor_block_records = 2;
  full_forest_options.descriptor_parent_builder =
      [](const std::vector<std::uint8_t>& descriptors,
         std::vector<std::uint64_t>* parents, std::string*) {
        const std::size_t count = descriptors.size() / 128;
        parents->assign(count, std::numeric_limits<std::uint64_t>::max());
        for (std::size_t child = 1; child < count; ++child) {
          (*parents)[child] = child - 1;
        }
        return true;
      };
  pw::pwa2::Stats full_forest_stats;
  if (pw::pwa2::PackDatabase(source, members_full_forest,
                             full_forest_options, &full_forest_stats,
                             &error) != pw::pwa2::Status::kOk ||
      full_forest_stats.descriptor_nodes != 8 ||
      full_forest_stats.root_descriptor_nodes != 1 ||
      full_forest_stats.predicted_descriptor_nodes != 7 ||
      full_forest_stats.unmatched_descriptor_nodes != 0) {
    std::filesystem::remove_all(root);
    return Fail("full-coverage descriptor parent builder failed: " + error);
  }
  pw::pwa2::Verification full_forest_verification;
  if (pw::pwa2::VerifyDatabase(source, members_full_forest,
                               &full_forest_verification, &error) !=
          pw::pwa2::Status::kOk ||
      !full_forest_verification.all_cells_equal ||
      !full_forest_verification.all_rows_and_order_equal ||
      pw::pwa2::MaterializeDatabase(members_full_forest,
                                    restored_full_forest, &error) !=
          pw::pwa2::Status::kOk) {
    std::filesystem::remove_all(root);
    return Fail("full-coverage forest exact restoration failed: " + error);
  }
  bool full_forest_equal = false;
  if (pw::pwa2::CompareDatabasesLogical(source, restored_full_forest,
                                        &full_forest_equal, &error) !=
          pw::pwa2::Status::kOk ||
      !full_forest_equal) {
    std::filesystem::remove_all(root);
    return Fail("full-coverage forest materialization differs: " + error);
  }
  const auto files_a = ReadDirectory(members_a);
  if (stats_a.table_count != 12 || stats_a.descriptor_nodes != 8 ||
      stats_a.member_count == 0 || stats_a.raw_member_bytes == 0) {
    std::filesystem::remove_all(root);
    return Fail("fixture coverage statistics are incomplete");
  }
  if (stats_a.root_descriptor_nodes != 2 ||
      stats_a.predicted_descriptor_nodes != 3 ||
      stats_a.unmatched_descriptor_nodes != 3 ||
      !HasMemberPrefix(files_a, "descriptor_roots_") ||
      !HasMemberPrefix(files_a, "descriptor_residuals_") ||
      !HasMemberPrefix(files_a, "descriptor_literals_")) {
    std::filesystem::remove_all(root);
    return Fail("descriptor streams were not structurally separated");
  }
  if (stats_a.keypoint_records != 8 || stats_a.keypoint_bytes != 192 ||
      stats_a.match_records != 4 || stats_a.match_bytes != 32 ||
      stats_a.two_view_records != 4 || stats_a.two_view_bytes != 32 ||
      !HasMemberPrefix(files_a, "keypoints_") ||
      !HasMemberPrefix(files_a, "matches_") ||
      !HasMemberPrefix(files_a, "two_view_")) {
    std::filesystem::remove_all(root);
    return Fail("numeric streams were not separated by column and byte plane");
  }

  struct DescriptorRequest {
    std::int64_t image_id;
    std::int64_t row;
    std::uint64_t expected_data_members;
  };
  for (const DescriptorRequest request :
       {DescriptorRequest{11, 0, 1}, {12, 1, 2}, {13, 1, 1}}) {
    std::array<std::uint8_t, 128> descriptor{};
    std::uint64_t members_touched = 0;
    if (pw::pwa2::ReadDescriptor(members_a, request.image_id, request.row,
                                 &descriptor, &members_touched, &error) !=
            pw::pwa2::Status::kOk ||
        descriptor != DescriptorBytes(request.image_id, request.row) ||
        members_touched != request.expected_data_members) {
      std::filesystem::remove_all(root);
      return Fail("bounded random descriptor read failed: " + error);
    }
  }

  pw::pwa2::Verification verification;
  if (pw::pwa2::VerifyDatabase(source, members_a, &verification, &error) !=
      pw::pwa2::Status::kOk) {
    std::filesystem::remove_all(root);
    return Fail("verification failed: " + error);
  }
  if (!verification.all_tables_covered || !verification.all_cells_equal ||
      !verification.all_rows_and_order_equal ||
      verification.source_logical_sha256.empty() ||
      verification.source_logical_sha256 !=
          verification.restored_logical_sha256) {
    std::filesystem::remove_all(root);
    return Fail("logical verification gates did not pass");
  }

  if (pw::pwa2::MaterializeDatabase(members_a, restored, &error) !=
      pw::pwa2::Status::kOk) {
    std::filesystem::remove_all(root);
    return Fail("materialization failed: " + error);
  }
  bool equal = false;
  if (pw::pwa2::CompareDatabasesLogical(source, restored, &equal, &error) !=
          pw::pwa2::Status::kOk ||
      !equal) {
    std::filesystem::remove_all(root);
    return Fail("materialized database differs: " + error);
  }

  sqlite3* restored_database = nullptr;
  if (sqlite3_open_v2(restored.c_str(), &restored_database,
                      SQLITE_OPEN_READONLY, nullptr) != SQLITE_OK) {
    std::filesystem::remove_all(root);
    return Fail("cannot open materialized database");
  }
  sqlite3_stmt* integrity = nullptr;
  const bool integrity_ok =
      sqlite3_prepare_v2(restored_database, "PRAGMA integrity_check", -1,
                         &integrity, nullptr) == SQLITE_OK &&
      sqlite3_step(integrity) == SQLITE_ROW &&
      std::string(reinterpret_cast<const char*>(sqlite3_column_text(integrity, 0))) ==
          "ok";
  sqlite3_finalize(integrity);
  sqlite3_close(restored_database);
  if (!integrity_ok) {
    std::filesystem::remove_all(root);
    return Fail("materialized database integrity failed");
  }

  std::filesystem::remove_all(root);
  std::printf(
      "PW_PWA2_LOGICAL_ARCHIVE_TEST_OK tables=%llu rows=%llu members=%llu "
      "raw_bytes=%llu\n",
      static_cast<unsigned long long>(stats_a.table_count),
      static_cast<unsigned long long>(stats_a.row_count),
      static_cast<unsigned long long>(stats_a.member_count),
      static_cast<unsigned long long>(stats_a.raw_member_bytes));
  return 0;
}
