#include "../Runner/pw_sqlite_descriptor_transform.h"

#include <sqlite3.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>

#include <pthread.h>
#include <unistd.h>

namespace {

int Fail(const char* message) {
  std::fprintf(stderr, "PW_SQLITE_DESCRIPTOR_TRANSFORM_TEST_FAILED: %s\n",
               message);
  return 1;
}

bool ReadFile(const std::string& path, std::vector<unsigned char>* bytes) {
  std::ifstream input(path, std::ios::binary | std::ios::ate);
  if (!input) {
    return false;
  }
  const std::streamsize size = input.tellg();
  if (size < 0) {
    return false;
  }
  input.seekg(0, std::ios::beg);
  bytes->resize(static_cast<size_t>(size));
  return bytes->empty() ||
         input.read(reinterpret_cast<char*>(bytes->data()), size).good();
}

bool Exec(sqlite3* database, const char* sql) {
  char* error = nullptr;
  const int status = sqlite3_exec(database, sql, nullptr, nullptr, &error);
  if (status != SQLITE_OK) {
    std::fprintf(stderr, "sqlite error: %s\n", error == nullptr ? "" : error);
    sqlite3_free(error);
    return false;
  }
  return true;
}

bool CreateFixture(const std::string& path) {
  sqlite3* database = nullptr;
  if (sqlite3_open(path.c_str(), &database) != SQLITE_OK) {
    if (database != nullptr) {
      sqlite3_close(database);
    }
    return false;
  }

  bool ok =
      Exec(database, "PRAGMA page_size=4096;") &&
      Exec(database, "PRAGMA auto_vacuum=NONE;") &&
      Exec(database, "PRAGMA journal_mode=WAL;") &&
      Exec(database,
           "CREATE TABLE descriptors("
           "image_id INTEGER PRIMARY KEY NOT NULL,"
           "type INTEGER NOT NULL,"
           "rows INTEGER NOT NULL,"
           "cols INTEGER NOT NULL,"
           "data BLOB);") &&
      Exec(database,
           "CREATE TABLE two_view_geometries("
           "pair_id INTEGER PRIMARY KEY NOT NULL,"
           "rows INTEGER NOT NULL,"
           "cols INTEGER NOT NULL,"
           "data BLOB,"
           "config INTEGER NOT NULL,"
           "F BLOB,E BLOB,H BLOB,qvec BLOB,tvec BLOB);") &&
      Exec(database, "BEGIN IMMEDIATE;");

  sqlite3_stmt* insert = nullptr;
  if (ok) {
    ok = sqlite3_prepare_v2(
             database,
             "INSERT INTO descriptors(image_id,type,rows,cols,data)"
             "VALUES(?1,?2,?3,128,?4);",
             -1, &insert, nullptr) == SQLITE_OK;
  }

  for (int image = 1; ok && image <= 2; ++image) {
    const int rows = image == 1 ? 64 : 17;
    std::vector<unsigned char> descriptors(
        static_cast<size_t>(rows) * 128);
    for (int row = 0; row < rows; ++row) {
      for (int column = 0; column < 128; ++column) {
        descriptors[static_cast<size_t>(row) * 128 + column] =
            static_cast<unsigned char>((column * 3 + row * 5 + image) & 0xff);
      }
    }
    sqlite3_bind_int(insert, 1, image);
    sqlite3_bind_int(insert, 2, 0);
    sqlite3_bind_int(insert, 3, rows);
    sqlite3_bind_blob(insert, 4, descriptors.data(),
                      static_cast<int>(descriptors.size()), SQLITE_TRANSIENT);
    ok = sqlite3_step(insert) == SQLITE_DONE;
    sqlite3_reset(insert);
    sqlite3_clear_bindings(insert);
  }

  if (insert != nullptr) {
    sqlite3_finalize(insert);
  }

  sqlite3_stmt* insert_matches = nullptr;
  if (ok) {
    ok = sqlite3_prepare_v2(
             database,
             "INSERT INTO two_view_geometries("
             "pair_id,rows,cols,data,config) VALUES(?1,17,2,?2,3);",
             -1, &insert_matches, nullptr) == SQLITE_OK;
  }
  std::vector<uint32_t> matches(17u * 2u);
  for (uint32_t row = 0; row < 17; ++row) {
    matches[row * 2] = row;
    matches[row * 2 + 1] = row;
  }
  if (ok) {
    sqlite3_bind_int64(insert_matches, 1, 2147483649LL);
    sqlite3_bind_blob(insert_matches, 2, matches.data(),
                      static_cast<int>(matches.size() * sizeof(uint32_t)),
                      SQLITE_TRANSIENT);
    ok = sqlite3_step(insert_matches) == SQLITE_DONE;
  }
  if (insert_matches != nullptr) {
    sqlite3_finalize(insert_matches);
  }
  ok = ok && Exec(database, "COMMIT;");
  if (!ok) {
    Exec(database, "ROLLBACK;");
  }
  ok = sqlite3_close(database) == SQLITE_OK && ok;
  return ok;
}

bool IntegrityOk(const std::string& path) {
  sqlite3* database = nullptr;
  const std::string immutable_uri = "file:" + path + "?immutable=1";
  if (sqlite3_open_v2(immutable_uri.c_str(), &database,
                      SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nullptr) !=
      SQLITE_OK) {
    if (database != nullptr) {
      sqlite3_close(database);
    }
    return false;
  }
  sqlite3_stmt* statement = nullptr;
  bool ok =
      sqlite3_prepare_v2(database, "PRAGMA integrity_check;", -1, &statement,
                         nullptr) == SQLITE_OK &&
      sqlite3_step(statement) == SQLITE_ROW &&
      std::strcmp(
          reinterpret_cast<const char*>(sqlite3_column_text(statement, 0)),
          "ok") == 0;
  if (statement != nullptr) {
    sqlite3_finalize(statement);
  }
  ok = sqlite3_close(database) == SQLITE_OK && ok;
  return ok;
}

bool ReadDescriptor(const std::string& path,
                    const int image_id,
                    std::vector<unsigned char>* bytes) {
  sqlite3* database = nullptr;
  const std::string immutable_uri = "file:" + path + "?immutable=1";
  if (sqlite3_open_v2(immutable_uri.c_str(), &database,
                      SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nullptr) !=
      SQLITE_OK) {
    if (database != nullptr) {
      sqlite3_close(database);
    }
    return false;
  }
  sqlite3_stmt* statement = nullptr;
  bool ok = sqlite3_prepare_v2(
                database, "SELECT data FROM descriptors WHERE image_id=?1;",
                -1, &statement, nullptr) == SQLITE_OK;
  if (ok) {
    sqlite3_bind_int(statement, 1, image_id);
    ok = sqlite3_step(statement) == SQLITE_ROW;
  }
  if (ok) {
    const int length = sqlite3_column_bytes(statement, 0);
    const auto* data = static_cast<const unsigned char*>(
        sqlite3_column_blob(statement, 0));
    ok = length >= 0 && (length == 0 || data != nullptr);
    if (ok) {
      bytes->assign(data, data + length);
    }
  }
  if (statement != nullptr) {
    sqlite3_finalize(statement);
  }
  ok = sqlite3_close(database) == SQLITE_OK && ok;
  return ok;
}

struct SmallStackTransformArguments {
  const char* source = nullptr;
  const char* output = nullptr;
  int32_t status = PW_SQLITE_DESCRIPTOR_TRANSFORM_MALFORMED;
};

void* RunSmallStackTransform(void* opaque) {
  auto* arguments = static_cast<SmallStackTransformArguments*>(opaque);
  arguments->status = pw_sqlite_descriptor_transform_file(
      arguments->source, arguments->output,
      PW_SQLITE_DESCRIPTOR_TRACK_DELTA, false, nullptr);
  return nullptr;
}

bool TransformOnHalfMiBStack(const std::string& source,
                             const std::string& output) {
  pthread_attr_t attributes;
  if (pthread_attr_init(&attributes) != 0) {
    return false;
  }
  const int stack_status =
      pthread_attr_setstacksize(&attributes, 512u * 1024u);
  SmallStackTransformArguments arguments{
      source.c_str(), output.c_str(),
      PW_SQLITE_DESCRIPTOR_TRANSFORM_MALFORMED};
  pthread_t thread;
  const int create_status =
      stack_status == 0
          ? pthread_create(&thread, &attributes, RunSmallStackTransform,
                           &arguments)
          : stack_status;
  pthread_attr_destroy(&attributes);
  if (create_status != 0) {
    return false;
  }
  return pthread_join(thread, nullptr) == 0 &&
         arguments.status == PW_SQLITE_DESCRIPTOR_TRANSFORM_OK;
}

}  // namespace

int main() {
  char directory_template[] =
      "/private/tmp/pw-sqlite-descriptor-transform-XXXXXX";
  const char* directory = mkdtemp(directory_template);
  if (directory == nullptr) {
    return Fail("mkdtemp failed");
  }

  const std::string source = std::string(directory) + "/source.db";
  const std::string transformed = std::string(directory) + "/transformed.db";
  const std::string restored = std::string(directory) + "/restored.db";
  const std::string small_stack =
      std::string(directory) + "/small-stack.db";

  int result = 0;
  if (!CreateFixture(source)) {
    result = Fail("fixture creation failed");
  }

  std::vector<unsigned char> source_before;
  if (result == 0 && !ReadFile(source, &source_before)) {
    result = Fail("source read failed");
  }

  if (result == 0 && !TransformOnHalfMiBStack(source, small_stack)) {
    result = Fail("transform overflowed a half MiB worker stack");
  }

  PWSQLiteDescriptorTransformStats forward_stats{};
  if (result == 0) {
    const int32_t status = pw_sqlite_descriptor_transform_file(
        source.c_str(), transformed.c_str(), PW_SQLITE_DESCRIPTOR_TRANSPOSE,
        false, &forward_stats);
    if (status != PW_SQLITE_DESCRIPTOR_TRANSFORM_OK) {
      std::fprintf(stderr, "forward status=%d detail=%s\n", status,
                   pw_sqlite_descriptor_transform_last_error());
      result = Fail("forward transpose failed");
    }
  }

  PWSQLiteDescriptorTransformStats inverse_stats{};
  if (result == 0) {
    const int32_t status = pw_sqlite_descriptor_transform_file(
        transformed.c_str(), restored.c_str(), PW_SQLITE_DESCRIPTOR_TRANSPOSE,
        true, &inverse_stats);
    if (status != PW_SQLITE_DESCRIPTOR_TRANSFORM_OK) {
      std::fprintf(stderr, "inverse status=%d detail=%s\n", status,
                   pw_sqlite_descriptor_transform_last_error());
      result = Fail("inverse transpose failed");
    }
  }

  std::vector<unsigned char> source_after;
  std::vector<unsigned char> transformed_bytes;
  std::vector<unsigned char> restored_bytes;
  if (result == 0 &&
      (!ReadFile(source, &source_after) ||
       !ReadFile(transformed, &transformed_bytes) ||
       !ReadFile(restored, &restored_bytes))) {
    result = Fail("output read failed");
  }
  if (result == 0 && source_after != source_before) {
    result = Fail("source file changed");
  }
  if (result == 0 && transformed_bytes == source_before) {
    result = Fail("transpose did not change descriptor bytes");
  }
  if (result == 0 && restored_bytes != source_before) {
    result = Fail("inverse did not restore exact file bytes");
  }
  if (result == 0 &&
      (!IntegrityOk(transformed) || !IntegrityOk(restored))) {
    result = Fail("SQLite integrity check failed");
  }
  if (result == 0 &&
      pw_sqlite_descriptor_integrity_check_file(restored.c_str()) != 1) {
    result = Fail("exported SQLite integrity check failed");
  }
  if (result == 0 &&
      (forward_stats.descriptor_records != 2 ||
       forward_stats.descriptor_bytes != (64u + 17u) * 128u ||
       std::memcmp(&forward_stats, &inverse_stats, sizeof(forward_stats)) !=
           0)) {
    result = Fail("unexpected transform statistics");
  }

  const int32_t predicted_transforms[] = {
      PW_SQLITE_DESCRIPTOR_TRANSPOSE_XOR,
      PW_SQLITE_DESCRIPTOR_TRANSPOSE_DELTA,
      PW_SQLITE_DESCRIPTOR_TRACK_DELTA,
  };
  for (const int32_t transform : predicted_transforms) {
    const std::string predicted =
        std::string(directory) + "/predicted-" + std::to_string(transform) +
        ".db";
    const std::string predicted_repeat = predicted + ".repeat";
    const std::string predicted_restored = predicted + ".restored";
    PWSQLiteDescriptorTransformStats predicted_stats{};
    if (result == 0) {
      const int32_t status = pw_sqlite_descriptor_transform_file(
          source.c_str(), predicted.c_str(), transform, false,
          &predicted_stats);
      if (status != PW_SQLITE_DESCRIPTOR_TRANSFORM_OK) {
        std::fprintf(stderr, "predicted transform=%d status=%d detail=%s\n",
                     transform, status,
                     pw_sqlite_descriptor_transform_last_error());
        result = Fail("predicted forward transform failed");
      }
    }
    if (result == 0) {
      const int32_t status = pw_sqlite_descriptor_transform_file(
          source.c_str(), predicted_repeat.c_str(), transform, false, nullptr);
      if (status != PW_SQLITE_DESCRIPTOR_TRANSFORM_OK) {
        result = Fail("predicted deterministic repeat failed");
      }
    }
    if (result == 0) {
      const int32_t status = pw_sqlite_descriptor_transform_file(
          predicted.c_str(), predicted_restored.c_str(), transform, true,
          nullptr);
      if (status != PW_SQLITE_DESCRIPTOR_TRANSFORM_OK) {
        result = Fail("predicted inverse transform failed");
      }
    }

    std::vector<unsigned char> predicted_bytes;
    std::vector<unsigned char> predicted_repeat_bytes;
    std::vector<unsigned char> predicted_restored_bytes;
    if (result == 0 &&
        (!ReadFile(predicted, &predicted_bytes) ||
         !ReadFile(predicted_repeat, &predicted_repeat_bytes) ||
         !ReadFile(predicted_restored, &predicted_restored_bytes))) {
      result = Fail("predicted output read failed");
    }
    if (result == 0 &&
        (predicted_bytes == source_before ||
         predicted_bytes != predicted_repeat_bytes ||
         predicted_restored_bytes != source_before ||
         !IntegrityOk(predicted) || !IntegrityOk(predicted_restored) ||
         predicted_stats.descriptor_records != 2 ||
         predicted_stats.descriptor_bytes != (64u + 17u) * 128u)) {
      result = Fail("predicted transform contract failed");
    }
    if (result == 0 && transform == PW_SQLITE_DESCRIPTOR_TRACK_DELTA) {
      std::vector<unsigned char> source_root;
      std::vector<unsigned char> transformed_root;
      std::vector<unsigned char> source_child;
      std::vector<unsigned char> transformed_child;
      if (!ReadDescriptor(source, 1, &source_root) ||
          !ReadDescriptor(predicted, 1, &transformed_root) ||
          !ReadDescriptor(source, 2, &source_child) ||
          !ReadDescriptor(predicted, 2, &transformed_child) ||
          source_root != transformed_root ||
          source_child == transformed_child) {
        result = Fail("track delta root/child contract failed");
      }
    }
    std::remove(predicted.c_str());
    std::remove(predicted_repeat.c_str());
    std::remove(predicted_restored.c_str());
  }

  const std::string cancelled = std::string(directory) + "/cancelled.db";
  if (result == 0) {
    const uint64_t generation =
        pw_sqlite_descriptor_transform_cancellation_generation();
    pw_sqlite_descriptor_transform_request_cancel();
    const int32_t status = pw_sqlite_descriptor_transform_file_cancellable(
        source.c_str(), cancelled.c_str(), PW_SQLITE_DESCRIPTOR_TRACK_DELTA,
        false, generation, nullptr);
    if (status != PW_SQLITE_DESCRIPTOR_TRANSFORM_CANCELLED ||
        access(cancelled.c_str(), F_OK) == 0) {
      result = Fail("cancelled transform published an output");
    }
  }

  std::remove(source.c_str());
  std::remove(transformed.c_str());
  std::remove(restored.c_str());
  std::remove(small_stack.c_str());
  std::remove(cancelled.c_str());
  rmdir(directory);

  if (result == 0) {
    std::printf(
        "PW_SQLITE_DESCRIPTOR_TRANSFORM_TEST_OK records=%llu bytes=%llu "
        "source_unchanged=1 byte_equal=1 integrity_ok=1\n",
        static_cast<unsigned long long>(forward_stats.descriptor_records),
        static_cast<unsigned long long>(forward_stats.descriptor_bytes));
  }
  return result;
}
