#ifndef PW_PWA2_SQLITE_LOGICAL_ARCHIVE_H_
#define PW_PWA2_SQLITE_LOGICAL_ARCHIVE_H_

#include <array>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <string>
#include <vector>

namespace pw::pwa2 {

enum class Status {
  kOk = 0,
  kInvalidArgument,
  kInputFailed,
  kOutputFailed,
  kUnsupportedSchema,
  kMalformed,
  kChecksumMismatch,
};

struct Options {
  std::size_t descriptor_block_records = 32768;
  // Optional encoder-side full-coverage forest. A UINT64_MAX parent marks a
  // root; every other parent must precede its child. The persisted format and
  // decoder remain independent of the parent-selection implementation.
  std::function<bool(const std::vector<std::uint8_t>&,
                     std::vector<std::uint64_t>*, std::string*)>
      descriptor_parent_builder;
};

struct Stats {
  std::uint64_t table_count = 0;
  std::uint64_t row_count = 0;
  std::uint64_t member_count = 0;
  std::uint64_t descriptor_nodes = 0;
  std::uint64_t root_descriptor_nodes = 0;
  std::uint64_t predicted_descriptor_nodes = 0;
  std::uint64_t unmatched_descriptor_nodes = 0;
  std::uint64_t keypoint_records = 0;
  std::uint64_t keypoint_bytes = 0;
  std::uint64_t match_records = 0;
  std::uint64_t match_bytes = 0;
  std::uint64_t two_view_records = 0;
  std::uint64_t two_view_bytes = 0;
  std::uint64_t raw_member_bytes = 0;
};

struct Verification {
  bool all_tables_covered = false;
  bool all_cells_equal = false;
  bool all_rows_and_order_equal = false;
  bool materialized_integrity_ok = false;
  std::string source_logical_sha256;
  std::string restored_logical_sha256;
};

Status PackDatabase(const std::string& source_database,
                    const std::string& output_directory,
                    const Options& options,
                    Stats* stats,
                    std::string* error);

Status VerifyDatabase(const std::string& source_database,
                      const std::string& member_directory,
                      Verification* verification,
                      std::string* error);

Status MaterializeDatabase(const std::string& member_directory,
                           const std::string& output_database,
                           std::string* error);

Status CompareDatabasesLogical(const std::string& left_database,
                               const std::string& right_database,
                               bool* equal,
                               std::string* error);

Status ReadDescriptor(const std::string& member_directory,
                      std::int64_t image_id,
                      std::int64_t row,
                      std::array<std::uint8_t, 128>* descriptor,
                      std::uint64_t* members_touched,
                      std::string* error);

const char* StatusName(Status status);

}  // namespace pw::pwa2

#endif  // PW_PWA2_SQLITE_LOGICAL_ARCHIVE_H_
