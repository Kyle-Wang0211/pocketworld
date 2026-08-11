#include "pwa2_sqlite_logical_archive.h"

#include <CommonCrypto/CommonDigest.h>
#include <sqlite3.h>

#include <algorithm>
#include <array>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <deque>
#include <filesystem>
#include <fstream>
#include <functional>
#include <limits>
#include <map>
#include <set>
#include <sstream>
#include <string>
#include <utility>
#include <vector>

namespace pw::pwa2 {
namespace {

constexpr char kTablesMagic[] = "PWA2TBL1";
constexpr char kIndicesMagic[] = "PWA2IDX1";
constexpr char kManifestMagic[] = "PWA2MAN1";

enum class ValueType : std::uint8_t {
  kNull = 0,
  kInteger = 1,
  kReal = 2,
  kText = 3,
  kBlob = 4,
};

struct Value {
  ValueType type = ValueType::kNull;
  std::int64_t integer = 0;
  std::uint64_t real_bits = 0;
  std::vector<std::uint8_t> bytes;
};

struct Row {
  std::int64_t rowid = 0;
  std::vector<Value> values;
};

struct Table {
  std::string name;
  std::string sql;
  std::vector<std::string> columns;
  std::vector<Row> rows;
};

struct Index {
  std::string name;
  std::string sql;
};

struct DatabaseLogical {
  std::vector<Table> tables;
  std::vector<Index> indices;
};

struct ManifestEntry {
  std::string name;
  std::uint64_t size = 0;
  std::array<std::uint8_t, CC_SHA256_DIGEST_LENGTH> sha{};
};

struct DescriptorImage {
  std::int64_t image_id = 0;
  std::uint64_t base = 0;
  std::uint64_t rows = 0;
};

struct DescriptorEdge {
  std::uint64_t child = 0;
  std::uint64_t parent = 0;
};

struct DescriptorLayout {
  std::uint32_t block_records = 0;
  std::vector<DescriptorImage> images;
  std::vector<std::array<std::uint8_t, 128>> values;
  std::vector<std::uint64_t> roots;
  std::vector<DescriptorEdge> residuals;
  std::vector<std::uint64_t> literals;
};

class DisjointSet {
 public:
  explicit DisjointSet(std::size_t size) : parent_(size), rank_(size, 0) {
    for (std::size_t index = 0; index < size; ++index) {
      parent_[index] = index;
    }
  }

  std::size_t Find(std::size_t value) {
    std::size_t root = value;
    while (parent_[root] != root) {
      root = parent_[root];
    }
    while (parent_[value] != value) {
      const std::size_t next = parent_[value];
      parent_[value] = root;
      value = next;
    }
    return root;
  }

  bool Union(std::size_t first, std::size_t second) {
    first = Find(first);
    second = Find(second);
    if (first == second) {
      return false;
    }
    if (rank_[first] < rank_[second]) {
      std::swap(first, second);
    }
    parent_[second] = first;
    if (rank_[first] == rank_[second]) {
      ++rank_[first];
    }
    return true;
  }

 private:
  std::vector<std::size_t> parent_;
  std::vector<std::uint8_t> rank_;
};

void SetError(std::string* error, const std::string& message) {
  if (error != nullptr) {
    *error = message;
  }
}

std::string QuoteIdentifier(const std::string& identifier) {
  std::string quoted = "\"";
  for (const char character : identifier) {
    if (character == '\"') {
      quoted += '\"';
    }
    quoted += character;
  }
  quoted += '\"';
  return quoted;
}

class Writer {
 public:
  void Bytes(const void* data, std::size_t size) {
    const auto* begin = static_cast<const std::uint8_t*>(data);
    bytes_.insert(bytes_.end(), begin, begin + size);
  }

  void U8(std::uint8_t value) { bytes_.push_back(value); }

  void U32(std::uint32_t value) {
    for (int shift = 0; shift < 32; shift += 8) {
      bytes_.push_back(static_cast<std::uint8_t>(value >> shift));
    }
  }

  void U64(std::uint64_t value) {
    for (int shift = 0; shift < 64; shift += 8) {
      bytes_.push_back(static_cast<std::uint8_t>(value >> shift));
    }
  }

  void I64(std::int64_t value) { U64(static_cast<std::uint64_t>(value)); }

  bool String(const std::string& value) {
    if (value.size() > std::numeric_limits<std::uint32_t>::max()) {
      return false;
    }
    U32(static_cast<std::uint32_t>(value.size()));
    Bytes(value.data(), value.size());
    return true;
  }

  bool Blob(const std::vector<std::uint8_t>& value) {
    U64(value.size());
    Bytes(value.data(), value.size());
    return true;
  }

  const std::vector<std::uint8_t>& data() const { return bytes_; }

 private:
  std::vector<std::uint8_t> bytes_;
};

class Reader {
 public:
  explicit Reader(const std::vector<std::uint8_t>& bytes) : bytes_(bytes) {}

  bool Bytes(void* output, std::size_t size) {
    if (size > bytes_.size() - offset_) {
      return false;
    }
    std::memcpy(output, bytes_.data() + offset_, size);
    offset_ += size;
    return true;
  }

  bool U8(std::uint8_t* value) { return Bytes(value, sizeof(*value)); }

  bool U32(std::uint32_t* value) {
    if (bytes_.size() - offset_ < 4) {
      return false;
    }
    *value = 0;
    for (int shift = 0; shift < 32; shift += 8) {
      *value |= static_cast<std::uint32_t>(bytes_[offset_++]) << shift;
    }
    return true;
  }

  bool U64(std::uint64_t* value) {
    if (bytes_.size() - offset_ < 8) {
      return false;
    }
    *value = 0;
    for (int shift = 0; shift < 64; shift += 8) {
      *value |= static_cast<std::uint64_t>(bytes_[offset_++]) << shift;
    }
    return true;
  }

  bool I64(std::int64_t* value) {
    std::uint64_t unsigned_value = 0;
    if (!U64(&unsigned_value)) {
      return false;
    }
    *value = static_cast<std::int64_t>(unsigned_value);
    return true;
  }

  bool String(std::string* value) {
    std::uint32_t size = 0;
    if (!U32(&size) || size > bytes_.size() - offset_) {
      return false;
    }
    value->assign(reinterpret_cast<const char*>(bytes_.data() + offset_), size);
    offset_ += size;
    return true;
  }

  bool Blob(std::vector<std::uint8_t>* value) {
    std::uint64_t size = 0;
    if (!U64(&size) || size > bytes_.size() - offset_ ||
        size > std::numeric_limits<std::size_t>::max()) {
      return false;
    }
    const auto begin = bytes_.begin() + static_cast<std::ptrdiff_t>(offset_);
    value->assign(begin, begin + static_cast<std::ptrdiff_t>(size));
    offset_ += static_cast<std::size_t>(size);
    return true;
  }

  bool Done() const { return offset_ == bytes_.size(); }

 private:
  const std::vector<std::uint8_t>& bytes_;
  std::size_t offset_ = 0;
};

class ScopedDatabase {
 public:
  ~ScopedDatabase() {
    if (database_ != nullptr) {
      sqlite3_close(database_);
    }
  }

  sqlite3** out() { return &database_; }
  sqlite3* get() const { return database_; }

 private:
  sqlite3* database_ = nullptr;
};

class ScopedStatement {
 public:
  ~ScopedStatement() {
    if (statement_ != nullptr) {
      sqlite3_finalize(statement_);
    }
  }

  sqlite3_stmt** out() { return &statement_; }
  sqlite3_stmt* get() const { return statement_; }

 private:
  sqlite3_stmt* statement_ = nullptr;
};

bool Prepare(sqlite3* database,
             const std::string& sql,
             ScopedStatement* statement,
             std::string* error) {
  if (sqlite3_prepare_v2(database, sql.c_str(), -1, statement->out(), nullptr) ==
      SQLITE_OK) {
    return true;
  }
  SetError(error, sqlite3_errmsg(database));
  return false;
}

bool Exec(sqlite3* database, const std::string& sql, std::string* error) {
  char* sqlite_error = nullptr;
  const int status = sqlite3_exec(database, sql.c_str(), nullptr, nullptr,
                                  &sqlite_error);
  if (status == SQLITE_OK) {
    return true;
  }
  SetError(error,
           sqlite_error == nullptr ? sqlite3_errmsg(database) : sqlite_error);
  sqlite3_free(sqlite_error);
  return false;
}

bool LoadValue(sqlite3_stmt* statement, int column, Value* value) {
  const int type = sqlite3_column_type(statement, column);
  if (type == SQLITE_NULL) {
    value->type = ValueType::kNull;
    return true;
  }
  if (type == SQLITE_INTEGER) {
    value->type = ValueType::kInteger;
    value->integer = sqlite3_column_int64(statement, column);
    return true;
  }
  if (type == SQLITE_FLOAT) {
    value->type = ValueType::kReal;
    const double real = sqlite3_column_double(statement, column);
    static_assert(sizeof(real) == sizeof(value->real_bits));
    std::memcpy(&value->real_bits, &real, sizeof(real));
    return true;
  }
  if (type != SQLITE_TEXT && type != SQLITE_BLOB) {
    return false;
  }
  value->type = type == SQLITE_TEXT ? ValueType::kText : ValueType::kBlob;
  const int size = sqlite3_column_bytes(statement, column);
  if (size < 0) {
    return false;
  }
  const auto* data = static_cast<const std::uint8_t*>(
      type == SQLITE_TEXT ? static_cast<const void*>(
                                sqlite3_column_text(statement, column))
                          : sqlite3_column_blob(statement, column));
  if (size > 0 && data == nullptr) {
    return false;
  }
  value->bytes.assign(data, data + size);
  return true;
}

bool LoadLogicalDatabase(const std::string& path,
                         DatabaseLogical* logical,
                         std::string* error) {
  ScopedDatabase database;
  if (sqlite3_open_v2(path.c_str(), database.out(), SQLITE_OPEN_READONLY,
                      nullptr) != SQLITE_OK) {
    SetError(error, database.get() == nullptr ? "sqlite open failed"
                                             : sqlite3_errmsg(database.get()));
    return false;
  }

  ScopedStatement table_statement;
  if (!Prepare(database.get(),
               "SELECT name, sql FROM sqlite_master WHERE type='table' "
               "ORDER BY name",
               &table_statement, error)) {
    return false;
  }
  while (sqlite3_step(table_statement.get()) == SQLITE_ROW) {
    Table table;
    const auto* name = sqlite3_column_text(table_statement.get(), 0);
    const auto* sql = sqlite3_column_text(table_statement.get(), 1);
    if (name == nullptr) {
      SetError(error, "table name is null");
      return false;
    }
    table.name = reinterpret_cast<const char*>(name);
    if (sql != nullptr) {
      table.sql = reinterpret_cast<const char*>(sql);
    }

    ScopedStatement columns;
    if (!Prepare(database.get(), "PRAGMA table_info(" +
                                     QuoteIdentifier(table.name) + ")",
                 &columns, error)) {
      return false;
    }
    while (sqlite3_step(columns.get()) == SQLITE_ROW) {
      const auto* column_name = sqlite3_column_text(columns.get(), 1);
      if (column_name == nullptr) {
        SetError(error, "column name is null");
        return false;
      }
      table.columns.emplace_back(reinterpret_cast<const char*>(column_name));
    }

    ScopedStatement rows;
    if (!Prepare(database.get(), "SELECT rowid,* FROM " +
                                     QuoteIdentifier(table.name) +
                                     " ORDER BY rowid",
                 &rows, error)) {
      return false;
    }
    while (true) {
      const int step = sqlite3_step(rows.get());
      if (step == SQLITE_DONE) {
        break;
      }
      if (step != SQLITE_ROW) {
        SetError(error, sqlite3_errmsg(database.get()));
        return false;
      }
      Row row;
      row.rowid = sqlite3_column_int64(rows.get(), 0);
      row.values.resize(table.columns.size());
      for (std::size_t column = 0; column < table.columns.size(); ++column) {
        if (!LoadValue(rows.get(), static_cast<int>(column + 1),
                       &row.values[column])) {
          SetError(error, "unsupported SQLite value");
          return false;
        }
      }
      table.rows.push_back(std::move(row));
    }
    logical->tables.push_back(std::move(table));
  }

  ScopedStatement index_statement;
  if (!Prepare(database.get(),
               "SELECT name, sql FROM sqlite_master WHERE type='index' AND "
               "sql IS NOT NULL ORDER BY name",
               &index_statement, error)) {
    return false;
  }
  while (sqlite3_step(index_statement.get()) == SQLITE_ROW) {
    const auto* name = sqlite3_column_text(index_statement.get(), 0);
    const auto* sql = sqlite3_column_text(index_statement.get(), 1);
    if (name == nullptr || sql == nullptr) {
      SetError(error, "index metadata is null");
      return false;
    }
    logical->indices.push_back(
        {reinterpret_cast<const char*>(name), reinterpret_cast<const char*>(sql)});
  }
  return true;
}

bool ValidateSupportedSchema(const DatabaseLogical& logical,
                             std::string* error) {
  const std::set<std::string> expected = {
      "cameras",       "descriptors", "frame_data", "frames",
      "images",        "keypoints",   "matches",    "pose_priors",
      "rig_sensors",   "rigs",        "sqlite_sequence",
      "two_view_geometries"};
  std::set<std::string> actual;
  for (const Table& table : logical.tables) {
    actual.insert(table.name);
  }
  if (actual != expected) {
    SetError(error, "unsupported table set");
    return false;
  }
  const std::map<std::string, std::vector<std::string>> required = {
      {"descriptors", {"image_id", "type", "rows", "cols", "data"}},
      {"keypoints", {"image_id", "rows", "cols", "data"}},
      {"matches", {"pair_id", "rows", "cols", "data"}},
      {"two_view_geometries",
       {"pair_id", "rows", "cols", "data", "config", "F", "E", "H",
        "qvec", "tvec"}},
  };
  for (const auto& requirement : required) {
    const std::string& name = requirement.first;
    const std::vector<std::string>& columns = requirement.second;
    const auto found = std::find_if(
        logical.tables.begin(), logical.tables.end(),
        [&](const Table& table) { return table.name == name; });
    if (found == logical.tables.end() || found->columns != columns) {
      SetError(error, "unsupported columns for " + name);
      return false;
    }
  }
  return true;
}

bool SerializeValue(const Value& value, Writer* writer) {
  writer->U8(static_cast<std::uint8_t>(value.type));
  switch (value.type) {
    case ValueType::kNull:
      return true;
    case ValueType::kInteger:
      writer->I64(value.integer);
      return true;
    case ValueType::kReal:
      writer->U64(value.real_bits);
      return true;
    case ValueType::kText:
    case ValueType::kBlob:
      return writer->Blob(value.bytes);
  }
  return false;
}

bool DeserializeValue(Reader* reader, Value* value) {
  std::uint8_t type = 0;
  if (!reader->U8(&type) || type > static_cast<std::uint8_t>(ValueType::kBlob)) {
    return false;
  }
  value->type = static_cast<ValueType>(type);
  switch (value->type) {
    case ValueType::kNull:
      return true;
    case ValueType::kInteger:
      return reader->I64(&value->integer);
    case ValueType::kReal:
      return reader->U64(&value->real_bits);
    case ValueType::kText:
    case ValueType::kBlob:
      return reader->Blob(&value->bytes);
  }
  return false;
}

bool SerializeTables(const DatabaseLogical& logical,
                     std::vector<std::uint8_t>* bytes) {
  Writer writer;
  writer.Bytes(kTablesMagic, sizeof(kTablesMagic) - 1);
  writer.U32(static_cast<std::uint32_t>(logical.tables.size()));
  for (const Table& table : logical.tables) {
    if (!writer.String(table.name) || !writer.String(table.sql)) {
      return false;
    }
    writer.U32(static_cast<std::uint32_t>(table.columns.size()));
    for (const std::string& column : table.columns) {
      if (!writer.String(column)) {
        return false;
      }
    }
    writer.U64(table.rows.size());
    for (const Row& row : table.rows) {
      writer.I64(row.rowid);
      for (const Value& value : row.values) {
        if (!SerializeValue(value, &writer)) {
          return false;
        }
      }
    }
  }
  *bytes = writer.data();
  return true;
}

bool DeserializeTables(const std::vector<std::uint8_t>& bytes,
                       DatabaseLogical* logical) {
  Reader reader(bytes);
  std::array<char, sizeof(kTablesMagic) - 1> magic{};
  std::uint32_t table_count = 0;
  if (!reader.Bytes(magic.data(), magic.size()) ||
      std::memcmp(magic.data(), kTablesMagic, magic.size()) != 0 ||
      !reader.U32(&table_count) || table_count > 1024) {
    return false;
  }
  for (std::uint32_t table_index = 0; table_index < table_count; ++table_index) {
    Table table;
    std::uint32_t column_count = 0;
    std::uint64_t row_count = 0;
    if (!reader.String(&table.name) || !reader.String(&table.sql) ||
        !reader.U32(&column_count) || column_count > 1024) {
      return false;
    }
    table.columns.resize(column_count);
    for (std::string& column : table.columns) {
      if (!reader.String(&column)) {
        return false;
      }
    }
    if (!reader.U64(&row_count) || row_count > 100000000ULL) {
      return false;
    }
    table.rows.resize(static_cast<std::size_t>(row_count));
    for (Row& row : table.rows) {
      if (!reader.I64(&row.rowid)) {
        return false;
      }
      row.values.resize(column_count);
      for (Value& value : row.values) {
        if (!DeserializeValue(&reader, &value)) {
          return false;
        }
      }
    }
    logical->tables.push_back(std::move(table));
  }
  return reader.Done();
}

bool SerializeIndices(const DatabaseLogical& logical,
                      std::vector<std::uint8_t>* bytes) {
  Writer writer;
  writer.Bytes(kIndicesMagic, sizeof(kIndicesMagic) - 1);
  writer.U32(static_cast<std::uint32_t>(logical.indices.size()));
  for (const Index& index : logical.indices) {
    if (!writer.String(index.name) || !writer.String(index.sql)) {
      return false;
    }
  }
  *bytes = writer.data();
  return true;
}

bool DeserializeIndices(const std::vector<std::uint8_t>& bytes,
                        DatabaseLogical* logical) {
  Reader reader(bytes);
  std::array<char, sizeof(kIndicesMagic) - 1> magic{};
  std::uint32_t index_count = 0;
  if (!reader.Bytes(magic.data(), magic.size()) ||
      std::memcmp(magic.data(), kIndicesMagic, magic.size()) != 0 ||
      !reader.U32(&index_count) || index_count > 4096) {
    return false;
  }
  for (std::uint32_t index = 0; index < index_count; ++index) {
    Index entry;
    if (!reader.String(&entry.name) || !reader.String(&entry.sql)) {
      return false;
    }
    logical->indices.push_back(std::move(entry));
  }
  return reader.Done();
}

std::array<std::uint8_t, CC_SHA256_DIGEST_LENGTH> Sha256(
    const std::vector<std::uint8_t>& bytes) {
  std::array<std::uint8_t, CC_SHA256_DIGEST_LENGTH> digest{};
  CC_SHA256(bytes.data(), static_cast<CC_LONG>(bytes.size()), digest.data());
  return digest;
}

std::string Hex(
    const std::array<std::uint8_t, CC_SHA256_DIGEST_LENGTH>& digest) {
  static constexpr char kHex[] = "0123456789abcdef";
  std::string value;
  value.reserve(digest.size() * 2);
  for (const std::uint8_t byte : digest) {
    value.push_back(kHex[byte >> 4]);
    value.push_back(kHex[byte & 15]);
  }
  return value;
}

bool WriteFile(const std::filesystem::path& path,
               const std::vector<std::uint8_t>& bytes,
               std::string* error) {
  std::ofstream output(path, std::ios::binary | std::ios::trunc);
  if (!output ||
      !output.write(reinterpret_cast<const char*>(bytes.data()), bytes.size())) {
    SetError(error, "cannot write " + path.string());
    return false;
  }
  output.close();
  if (!output) {
    SetError(error, "cannot close " + path.string());
    return false;
  }
  return true;
}

bool ReadFile(const std::filesystem::path& path,
              std::vector<std::uint8_t>* bytes,
              std::string* error) {
  std::ifstream input(path, std::ios::binary);
  if (!input) {
    SetError(error, "cannot read " + path.string());
    return false;
  }
  input.seekg(0, std::ios::end);
  const std::streamoff size = input.tellg();
  if (size < 0 || static_cast<std::uint64_t>(size) >
                      std::numeric_limits<std::size_t>::max()) {
    SetError(error, "invalid file length " + path.string());
    return false;
  }
  input.seekg(0, std::ios::beg);
  bytes->resize(static_cast<std::size_t>(size));
  if (size > 0 && !input.read(reinterpret_cast<char*>(bytes->data()), size)) {
    SetError(error, "cannot read complete file " + path.string());
    return false;
  }
  return true;
}

std::vector<std::uint8_t> SerializeManifest(
    const std::vector<ManifestEntry>& entries) {
  Writer writer;
  writer.Bytes(kManifestMagic, sizeof(kManifestMagic) - 1);
  writer.U32(static_cast<std::uint32_t>(entries.size()));
  for (const ManifestEntry& entry : entries) {
    writer.String(entry.name);
    writer.U64(entry.size);
    writer.Bytes(entry.sha.data(), entry.sha.size());
  }
  return writer.data();
}

bool DeserializeManifest(const std::vector<std::uint8_t>& bytes,
                         std::vector<ManifestEntry>* entries) {
  Reader reader(bytes);
  std::array<char, sizeof(kManifestMagic) - 1> magic{};
  std::uint32_t count = 0;
  if (!reader.Bytes(magic.data(), magic.size()) ||
      std::memcmp(magic.data(), kManifestMagic, magic.size()) != 0 ||
      !reader.U32(&count) || count > 100000) {
    return false;
  }
  std::set<std::string> names;
  for (std::uint32_t index = 0; index < count; ++index) {
    ManifestEntry entry;
    if (!reader.String(&entry.name) || !reader.U64(&entry.size) ||
        !reader.Bytes(entry.sha.data(), entry.sha.size()) ||
        !names.insert(entry.name).second) {
      return false;
    }
    entries->push_back(std::move(entry));
  }
  return reader.Done();
}

bool LoadManifestMap(const std::string& directory,
                     std::map<std::string, ManifestEntry>* entries,
                     std::string* error) {
  std::vector<std::uint8_t> manifest_bytes;
  if (!ReadFile(std::filesystem::path(directory) / "manifest.bin",
                &manifest_bytes, error)) {
    return false;
  }
  std::vector<ManifestEntry> manifest_entries;
  if (!DeserializeManifest(manifest_bytes, &manifest_entries)) {
    SetError(error, "malformed manifest");
    return false;
  }
  for (ManifestEntry& entry : manifest_entries) {
    entries->emplace(entry.name, std::move(entry));
  }
  return entries->size() == manifest_entries.size();
}

bool ReadVerifiedMember(const std::string& directory,
                        const std::string& name,
                        const std::map<std::string, ManifestEntry>& entries,
                        std::vector<std::uint8_t>* bytes,
                        std::string* error) {
  const auto entry = entries.find(name);
  if (entry == entries.end() || name.find('/') != std::string::npos ||
      !ReadFile(std::filesystem::path(directory) / name, bytes, error) ||
      bytes->size() != entry->second.size || Sha256(*bytes) != entry->second.sha) {
    SetError(error, "member verification failed: " + name);
    return false;
  }
  return true;
}

bool LoadVerifiedMembers(const std::string& directory,
                         std::map<std::string, std::vector<std::uint8_t>>* members,
                         std::string* error) {
  std::vector<std::uint8_t> manifest_bytes;
  if (!ReadFile(std::filesystem::path(directory) / "manifest.bin",
                &manifest_bytes, error)) {
    return false;
  }
  std::vector<ManifestEntry> entries;
  if (!DeserializeManifest(manifest_bytes, &entries)) {
    SetError(error, "malformed manifest");
    return false;
  }
  for (const ManifestEntry& entry : entries) {
    std::vector<std::uint8_t> bytes;
    if (entry.name.find('/') != std::string::npos || entry.name == "manifest.bin" ||
        !ReadFile(std::filesystem::path(directory) / entry.name, &bytes, error) ||
        bytes.size() != entry.size || Sha256(bytes) != entry.sha) {
      SetError(error, "member verification failed: " + entry.name);
      return false;
    }
    members->emplace(entry.name, std::move(bytes));
  }
  return members->size() == entries.size();
}

bool LogicalBytes(const DatabaseLogical& logical,
                  std::vector<std::uint8_t>* tables,
                  std::vector<std::uint8_t>* indices) {
  return SerializeTables(logical, tables) && SerializeIndices(logical, indices);
}

const Table* FindTable(const DatabaseLogical& logical, const std::string& name) {
  const auto found = std::find_if(
      logical.tables.begin(), logical.tables.end(),
      [&](const Table& table) { return table.name == name; });
  return found == logical.tables.end() ? nullptr : &*found;
}

std::uint64_t CountRows(const DatabaseLogical& logical) {
  std::uint64_t count = 0;
  for (const Table& table : logical.tables) {
    count += table.rows.size();
  }
  return count;
}

bool BindValue(sqlite3_stmt* statement,
               int parameter,
               const Value& value,
               std::string* error) {
  int status = SQLITE_ERROR;
  switch (value.type) {
    case ValueType::kNull:
      status = sqlite3_bind_null(statement, parameter);
      break;
    case ValueType::kInteger:
      status = sqlite3_bind_int64(statement, parameter, value.integer);
      break;
    case ValueType::kReal: {
      double real = 0;
      std::memcpy(&real, &value.real_bits, sizeof(real));
      status = sqlite3_bind_double(statement, parameter, real);
      break;
    }
    case ValueType::kText:
      status = sqlite3_bind_text64(
          statement, parameter,
          reinterpret_cast<const char*>(value.bytes.data()), value.bytes.size(),
          SQLITE_TRANSIENT, SQLITE_UTF8);
      break;
    case ValueType::kBlob:
      status = sqlite3_bind_blob64(statement, parameter, value.bytes.data(),
                                   value.bytes.size(), SQLITE_TRANSIENT);
      break;
  }
  if (status == SQLITE_OK) {
    return true;
  }
  SetError(error, "SQLite bind failed");
  return false;
}

bool InsertTableRows(sqlite3* database,
                     const Table& table,
                     std::string* error) {
  if (table.name == "sqlite_sequence" &&
      !Exec(database, "DELETE FROM sqlite_sequence", error)) {
    return false;
  }
  std::string sql = "INSERT INTO " + QuoteIdentifier(table.name) + "(rowid";
  for (const std::string& column : table.columns) {
    sql += "," + QuoteIdentifier(column);
  }
  sql += ") VALUES(?1";
  for (std::size_t parameter = 0; parameter < table.columns.size(); ++parameter) {
    sql += ",?" + std::to_string(parameter + 2);
  }
  sql += ")";

  ScopedStatement statement;
  if (!Prepare(database, sql, &statement, error)) {
    return false;
  }
  for (const Row& row : table.rows) {
    sqlite3_reset(statement.get());
    sqlite3_clear_bindings(statement.get());
    if (sqlite3_bind_int64(statement.get(), 1, row.rowid) != SQLITE_OK) {
      SetError(error, sqlite3_errmsg(database));
      return false;
    }
    for (std::size_t value = 0; value < row.values.size(); ++value) {
      if (!BindValue(statement.get(), static_cast<int>(value + 2),
                     row.values[value], error)) {
        return false;
      }
    }
    if (sqlite3_step(statement.get()) != SQLITE_DONE) {
      SetError(error, sqlite3_errmsg(database));
      return false;
    }
  }
  return true;
}

Table* FindTableMutable(DatabaseLogical* logical, const std::string& name) {
  const auto found = std::find_if(
      logical->tables.begin(), logical->tables.end(),
      [&](const Table& table) { return table.name == name; });
  return found == logical->tables.end() ? nullptr : &*found;
}

bool IntegerValue(const Value& value, std::int64_t* output) {
  if (value.type != ValueType::kInteger) {
    return false;
  }
  *output = value.integer;
  return true;
}

std::uint32_t ReadLittleU32(const std::uint8_t* bytes) {
  return static_cast<std::uint32_t>(bytes[0]) |
         (static_cast<std::uint32_t>(bytes[1]) << 8) |
         (static_cast<std::uint32_t>(bytes[2]) << 16) |
         (static_cast<std::uint32_t>(bytes[3]) << 24);
}

bool DecodePairId(std::int64_t pair_id,
                  std::int64_t* first,
                  std::int64_t* second) {
  constexpr std::int64_t kMaximumImageId = 2147483647LL;
  if (pair_id < 0) {
    return false;
  }
  *second = pair_id % kMaximumImageId;
  *first = (pair_id - *second) / kMaximumImageId;
  return *first >= 0 && *second >= 0 && *first < *second &&
         *second < kMaximumImageId;
}

bool BuildDescriptorLayout(const DatabaseLogical& logical,
                           const Options& options,
                           DescriptorLayout* layout,
                           std::string* error) {
  const Table* descriptors = FindTable(logical, "descriptors");
  const Table* two_view = FindTable(logical, "two_view_geometries");
  if (descriptors == nullptr || two_view == nullptr ||
      options.descriptor_block_records == 0 ||
      options.descriptor_block_records >
          std::numeric_limits<std::uint32_t>::max()) {
    SetError(error, "descriptor source tables are missing");
    return false;
  }
  layout->block_records =
      static_cast<std::uint32_t>(options.descriptor_block_records);
  std::map<std::int64_t, DescriptorImage> images;
  for (const Row& row : descriptors->rows) {
    if (row.values.size() != 5) {
      SetError(error, "malformed descriptor row");
      return false;
    }
    std::int64_t image_id = 0;
    std::int64_t rows = 0;
    std::int64_t columns = 0;
    if (!IntegerValue(row.values[0], &image_id) ||
        !IntegerValue(row.values[2], &rows) ||
        !IntegerValue(row.values[3], &columns) || rows < 0 || columns != 128 ||
        row.values[4].type != ValueType::kBlob ||
        static_cast<std::uint64_t>(rows) >
            std::numeric_limits<std::size_t>::max() / 128 ||
        row.values[4].bytes.size() != static_cast<std::size_t>(rows) * 128 ||
        images.find(image_id) != images.end()) {
      SetError(error, "unsupported descriptor dimensions or image ID");
      return false;
    }
    DescriptorImage image{image_id, layout->values.size(),
                          static_cast<std::uint64_t>(rows)};
    images.emplace(image_id, image);
    layout->images.push_back(image);
    for (std::int64_t descriptor_row = 0; descriptor_row < rows;
         ++descriptor_row) {
      std::array<std::uint8_t, 128> descriptor{};
      std::copy_n(row.values[4].bytes.begin() + descriptor_row * 128, 128,
                  descriptor.begin());
      layout->values.push_back(descriptor);
    }
  }

  if (options.descriptor_parent_builder) {
    std::vector<std::uint8_t> flat;
    flat.reserve(layout->values.size() * 128);
    for (const auto& descriptor : layout->values) {
      flat.insert(flat.end(), descriptor.begin(), descriptor.end());
    }
    std::vector<std::uint64_t> parents;
    if (!options.descriptor_parent_builder(flat, &parents, error) ||
        parents.size() != layout->values.size()) {
      if (error != nullptr && error->empty()) {
        *error = "descriptor parent builder returned the wrong node count";
      }
      return false;
    }
    for (std::uint64_t child = 0; child < parents.size(); ++child) {
      const std::uint64_t parent = parents[child];
      if (parent == std::numeric_limits<std::uint64_t>::max()) {
        layout->roots.push_back(child);
      } else if (parent < child) {
        layout->residuals.push_back({child, parent});
      } else {
        SetError(error, "descriptor parent must precede its child");
        return false;
      }
    }
    if (layout->roots.size() + layout->residuals.size() !=
        layout->values.size()) {
      SetError(error, "descriptor forest does not cover every node");
      return false;
    }
    return true;
  }

  std::vector<std::pair<std::uint64_t, std::uint64_t>> edges;
  for (const Row& row : two_view->rows) {
    if (row.values.size() != 10) {
      SetError(error, "malformed two-view row");
      return false;
    }
    std::int64_t pair_id = 0;
    std::int64_t rows = 0;
    std::int64_t columns = 0;
    std::int64_t first_image_id = 0;
    std::int64_t second_image_id = 0;
    if (!IntegerValue(row.values[0], &pair_id) ||
        !IntegerValue(row.values[1], &rows) ||
        !IntegerValue(row.values[2], &columns) || rows < 0 || columns != 2 ||
        !DecodePairId(pair_id, &first_image_id, &second_image_id)) {
      SetError(error, "unsupported two-view match data");
      return false;
    }
    const bool has_empty_match_data =
        rows == 0 &&
        (row.values[3].type == ValueType::kNull ||
         (row.values[3].type == ValueType::kBlob &&
          row.values[3].bytes.empty()));
    const bool has_nonempty_match_data =
        rows > 0 && row.values[3].type == ValueType::kBlob &&
        static_cast<std::uint64_t>(rows) <=
            std::numeric_limits<std::size_t>::max() / 8 &&
        row.values[3].bytes.size() == static_cast<std::size_t>(rows) * 8;
    if (!has_empty_match_data && !has_nonempty_match_data) {
      SetError(error, "unsupported two-view match data");
      return false;
    }
    const auto first_image = images.find(first_image_id);
    const auto second_image = images.find(second_image_id);
    if (first_image == images.end() || second_image == images.end()) {
      continue;
    }
    for (std::int64_t match = 0; match < rows; ++match) {
      const std::uint8_t* pair = row.values[3].bytes.data() + match * 8;
      const std::uint32_t first_row = ReadLittleU32(pair);
      const std::uint32_t second_row = ReadLittleU32(pair + 4);
      if (first_row >= first_image->second.rows ||
          second_row >= second_image->second.rows) {
        continue;
      }
      std::uint64_t first_node = first_image->second.base + first_row;
      std::uint64_t second_node = second_image->second.base + second_row;
      if (first_node > second_node) {
        std::swap(first_node, second_node);
      }
      if (first_node != second_node) {
        edges.emplace_back(first_node, second_node);
      }
    }
  }
  std::sort(edges.begin(), edges.end());
  edges.erase(std::unique(edges.begin(), edges.end()), edges.end());

  DisjointSet disjoint_set(layout->values.size());
  std::vector<std::vector<std::uint64_t>> adjacency(layout->values.size());
  for (const auto& edge : edges) {
    if (!disjoint_set.Union(static_cast<std::size_t>(edge.first),
                            static_cast<std::size_t>(edge.second))) {
      continue;
    }
    adjacency[edge.first].push_back(edge.second);
    adjacency[edge.second].push_back(edge.first);
  }
  for (auto& neighbors : adjacency) {
    std::sort(neighbors.begin(), neighbors.end());
  }

  std::vector<bool> component_seen(layout->values.size(), false);
  for (std::uint64_t node = 0; node < layout->values.size(); ++node) {
    if (adjacency[node].empty() || component_seen[node]) {
      continue;
    }
    std::vector<std::uint64_t> component;
    std::deque<std::uint64_t> pending = {node};
    component_seen[node] = true;
    while (!pending.empty()) {
      const std::uint64_t current = pending.front();
      pending.pop_front();
      component.push_back(current);
      for (const std::uint64_t neighbor : adjacency[current]) {
        if (!component_seen[neighbor]) {
          component_seen[neighbor] = true;
          pending.push_back(neighbor);
        }
      }
    }
    const std::uint64_t root =
        *std::min_element(component.begin(), component.end());
    layout->roots.push_back(root);
    std::vector<bool> tree_seen(layout->values.size(), false);
    pending = {root};
    tree_seen[root] = true;
    while (!pending.empty()) {
      const std::uint64_t parent = pending.front();
      pending.pop_front();
      for (const std::uint64_t child : adjacency[parent]) {
        if (tree_seen[child]) {
          continue;
        }
        tree_seen[child] = true;
        layout->residuals.push_back({child, parent});
        pending.push_back(child);
      }
    }
  }
  std::sort(layout->roots.begin(), layout->roots.end());
  for (std::uint64_t node = 0; node < adjacency.size(); ++node) {
    if (adjacency[node].empty()) {
      layout->literals.push_back(node);
    }
  }
  return true;
}

std::vector<std::uint8_t> SerializeDescriptorTopology(
    const DescriptorLayout& layout) {
  Writer writer;
  static constexpr char kMagic[] = "PWA2TOP1";
  writer.Bytes(kMagic, sizeof(kMagic) - 1);
  writer.U32(layout.block_records);
  writer.U64(layout.values.size());
  writer.U32(static_cast<std::uint32_t>(layout.images.size()));
  for (const DescriptorImage& image : layout.images) {
    writer.I64(image.image_id);
    writer.U64(image.base);
    writer.U64(image.rows);
  }
  writer.U64(layout.roots.size());
  for (const std::uint64_t root : layout.roots) {
    writer.U64(root);
  }
  writer.U64(layout.residuals.size());
  for (const DescriptorEdge& edge : layout.residuals) {
    writer.U64(edge.child);
    writer.U64(edge.parent);
  }
  return writer.data();
}

bool DeserializeDescriptorTopology(const std::vector<std::uint8_t>& bytes,
                                   DescriptorLayout* layout) {
  Reader reader(bytes);
  static constexpr char kMagic[] = "PWA2TOP1";
  std::array<char, sizeof(kMagic) - 1> magic{};
  std::uint64_t node_count = 0;
  std::uint32_t image_count = 0;
  if (!reader.Bytes(magic.data(), magic.size()) ||
      std::memcmp(magic.data(), kMagic, magic.size()) != 0 ||
      !reader.U32(&layout->block_records) || layout->block_records == 0 ||
      !reader.U64(&node_count) || node_count > 100000000ULL ||
      !reader.U32(&image_count) || image_count > 1000000) {
    return false;
  }
  layout->values.resize(static_cast<std::size_t>(node_count));
  layout->images.resize(image_count);
  std::uint64_t expected_base = 0;
  for (DescriptorImage& image : layout->images) {
    if (!reader.I64(&image.image_id) || !reader.U64(&image.base) ||
        !reader.U64(&image.rows) || image.base != expected_base ||
        image.rows > node_count - expected_base) {
      return false;
    }
    expected_base += image.rows;
  }
  if (expected_base != node_count) {
    return false;
  }
  std::uint64_t root_count = 0;
  if (!reader.U64(&root_count) || root_count > node_count) {
    return false;
  }
  layout->roots.resize(static_cast<std::size_t>(root_count));
  for (std::uint64_t& root : layout->roots) {
    if (!reader.U64(&root) || root >= node_count) {
      return false;
    }
  }
  if (!std::is_sorted(layout->roots.begin(), layout->roots.end()) ||
      std::adjacent_find(layout->roots.begin(), layout->roots.end()) !=
          layout->roots.end()) {
    return false;
  }
  std::uint64_t residual_count = 0;
  if (!reader.U64(&residual_count) || residual_count > node_count) {
    return false;
  }
  layout->residuals.resize(static_cast<std::size_t>(residual_count));
  std::set<std::uint64_t> children;
  for (DescriptorEdge& edge : layout->residuals) {
    if (!reader.U64(&edge.child) || !reader.U64(&edge.parent) ||
        edge.child >= node_count || edge.parent >= node_count ||
        edge.child == edge.parent || !children.insert(edge.child).second) {
      return false;
    }
  }
  std::set<std::uint64_t> roots(layout->roots.begin(), layout->roots.end());
  for (std::uint64_t node = 0; node < node_count; ++node) {
    if (roots.find(node) == roots.end() &&
        children.find(node) == children.end()) {
      layout->literals.push_back(node);
    }
  }
  return reader.Done();
}

std::string DescriptorBlockName(const std::string& prefix,
                                std::uint32_t block_index) {
  std::array<char, 96> name{};
  std::snprintf(name.data(), name.size(), "%s_%06u.bin", prefix.c_str(),
                block_index);
  return name.data();
}

std::vector<std::uint8_t> SerializeDescriptorBlock(
    const DescriptorLayout& layout,
    const std::string& kind,
    const std::vector<std::uint64_t>& nodes,
    std::uint64_t start,
    std::uint32_t count) {
  Writer writer;
  static constexpr char kMagic[] = "PWA2DBL1";
  writer.Bytes(kMagic, sizeof(kMagic) - 1);
  writer.String(kind);
  writer.U64(start);
  writer.U32(count);
  for (std::size_t column = 0; column < 128; ++column) {
    for (std::uint32_t record = 0; record < count; ++record) {
      writer.U8(layout.values[nodes[start + record]][column]);
    }
  }
  return writer.data();
}

std::vector<std::uint8_t> SerializeResidualBlock(
    const DescriptorLayout& layout,
    std::uint64_t start,
    std::uint32_t count) {
  Writer writer;
  static constexpr char kMagic[] = "PWA2DBL1";
  writer.Bytes(kMagic, sizeof(kMagic) - 1);
  writer.String("residuals");
  writer.U64(start);
  writer.U32(count);
  for (std::size_t column = 0; column < 128; ++column) {
    for (std::uint32_t record = 0; record < count; ++record) {
      const DescriptorEdge& edge = layout.residuals[start + record];
      writer.U8(static_cast<std::uint8_t>(
          layout.values[edge.child][column] - layout.values[edge.parent][column]));
    }
  }
  return writer.data();
}

bool ParseDescriptorBlock(const std::vector<std::uint8_t>& bytes,
                          const std::string& expected_kind,
                          std::uint64_t expected_start,
                          std::uint32_t expected_count,
                          std::vector<std::array<std::uint8_t, 128>>* values) {
  Reader reader(bytes);
  static constexpr char kMagic[] = "PWA2DBL1";
  std::array<char, sizeof(kMagic) - 1> magic{};
  std::string kind;
  std::uint64_t start = 0;
  std::uint32_t count = 0;
  if (!reader.Bytes(magic.data(), magic.size()) ||
      std::memcmp(magic.data(), kMagic, magic.size()) != 0 ||
      !reader.String(&kind) || kind != expected_kind ||
      !reader.U64(&start) || start != expected_start ||
      !reader.U32(&count) || count != expected_count ||
      bytes.size() < static_cast<std::size_t>(count) * 128) {
    return false;
  }
  values->assign(count, {});
  for (std::size_t column = 0; column < 128; ++column) {
    for (std::uint32_t record = 0; record < count; ++record) {
      if (!reader.U8(&(*values)[record][column])) {
        return false;
      }
    }
  }
  return reader.Done();
}

void AddDescriptorValueBlocks(
    const DescriptorLayout& layout,
    const std::string& prefix,
    const std::string& kind,
    const std::vector<std::uint64_t>& nodes,
    std::map<std::string, std::vector<std::uint8_t>>* members) {
  std::uint32_t block_index = 0;
  for (std::uint64_t start = 0; start < nodes.size();
       start += layout.block_records, ++block_index) {
    const std::uint32_t count = static_cast<std::uint32_t>(
        std::min<std::uint64_t>(layout.block_records, nodes.size() - start));
    members->emplace(DescriptorBlockName(prefix, block_index),
                     SerializeDescriptorBlock(layout, kind, nodes, start, count));
  }
}

void AddDescriptorResidualBlocks(
    const DescriptorLayout& layout,
    std::map<std::string, std::vector<std::uint8_t>>* members) {
  std::uint32_t block_index = 0;
  for (std::uint64_t start = 0; start < layout.residuals.size();
       start += layout.block_records, ++block_index) {
    const std::uint32_t count = static_cast<std::uint32_t>(
        std::min<std::uint64_t>(layout.block_records,
                                layout.residuals.size() - start));
    members->emplace(DescriptorBlockName("descriptor_residuals", block_index),
                     SerializeResidualBlock(layout, start, count));
  }
}

bool BuildDescriptorMembers(
    DatabaseLogical* metadata,
    const Options& options,
    std::map<std::string, std::vector<std::uint8_t>>* members,
    Stats* stats,
    std::string* error) {
  if (options.descriptor_block_records >
      std::numeric_limits<std::uint32_t>::max()) {
    SetError(error, "descriptor block size is too large");
    return false;
  }
  DescriptorLayout layout;
  if (!BuildDescriptorLayout(*metadata, options, &layout, error)) {
    return false;
  }
  members->emplace("descriptor_topology.bin",
                   SerializeDescriptorTopology(layout));
  AddDescriptorValueBlocks(layout, "descriptor_roots", "roots", layout.roots,
                           members);
  AddDescriptorResidualBlocks(layout, members);
  AddDescriptorValueBlocks(layout, "descriptor_literals", "literals",
                           layout.literals, members);

  Table* descriptors = FindTableMutable(metadata, "descriptors");
  if (descriptors == nullptr) {
    return false;
  }
  for (Row& row : descriptors->rows) {
    row.values[4] = Value{};
  }
  stats->descriptor_nodes = layout.values.size();
  stats->root_descriptor_nodes = layout.roots.size();
  stats->predicted_descriptor_nodes = layout.residuals.size();
  stats->unmatched_descriptor_nodes = layout.literals.size();
  return true;
}

bool LoadDescriptorClass(
    const std::map<std::string, std::vector<std::uint8_t>>& members,
    const std::string& prefix,
    const std::string& kind,
    std::uint32_t block_records,
    std::uint64_t total_records,
    std::vector<std::array<std::uint8_t, 128>>* output) {
  for (std::uint64_t start = 0, block_index = 0; start < total_records;
       start += block_records, ++block_index) {
    const std::uint32_t count = static_cast<std::uint32_t>(
        std::min<std::uint64_t>(block_records, total_records - start));
    const auto member = members.find(
        DescriptorBlockName(prefix, static_cast<std::uint32_t>(block_index)));
    std::vector<std::array<std::uint8_t, 128>> block;
    if (member == members.end() ||
        !ParseDescriptorBlock(member->second, kind, start, count, &block)) {
      return false;
    }
    output->insert(output->end(), block.begin(), block.end());
  }
  return output->size() == total_records;
}

bool RestoreDescriptorMembers(
    DatabaseLogical* logical,
    const std::map<std::string, std::vector<std::uint8_t>>& members,
    std::string* error) {
  const auto topology_member = members.find("descriptor_topology.bin");
  DescriptorLayout layout;
  if (topology_member == members.end() ||
      !DeserializeDescriptorTopology(topology_member->second, &layout)) {
    SetError(error, "malformed descriptor topology");
    return false;
  }
  std::vector<std::array<std::uint8_t, 128>> roots;
  std::vector<std::array<std::uint8_t, 128>> residuals;
  std::vector<std::array<std::uint8_t, 128>> literals;
  if (!LoadDescriptorClass(members, "descriptor_roots", "roots",
                           layout.block_records, layout.roots.size(), &roots) ||
      !LoadDescriptorClass(members, "descriptor_residuals", "residuals",
                           layout.block_records, layout.residuals.size(),
                           &residuals) ||
      !LoadDescriptorClass(members, "descriptor_literals", "literals",
                           layout.block_records, layout.literals.size(),
                           &literals)) {
    SetError(error, "malformed descriptor value block");
    return false;
  }

  std::vector<bool> assigned(layout.values.size(), false);
  for (std::size_t index = 0; index < layout.roots.size(); ++index) {
    layout.values[layout.roots[index]] = roots[index];
    assigned[layout.roots[index]] = true;
  }
  for (std::size_t index = 0; index < layout.literals.size(); ++index) {
    layout.values[layout.literals[index]] = literals[index];
    assigned[layout.literals[index]] = true;
  }
  for (std::size_t index = 0; index < layout.residuals.size(); ++index) {
    const DescriptorEdge& edge = layout.residuals[index];
    if (!assigned[edge.parent] || assigned[edge.child]) {
      SetError(error, "descriptor dependency order is invalid");
      return false;
    }
    for (std::size_t column = 0; column < 128; ++column) {
      layout.values[edge.child][column] = static_cast<std::uint8_t>(
          residuals[index][column] + layout.values[edge.parent][column]);
    }
    assigned[edge.child] = true;
  }
  if (std::find(assigned.begin(), assigned.end(), false) != assigned.end()) {
    SetError(error, "descriptor topology does not cover all nodes");
    return false;
  }

  Table* descriptors = FindTableMutable(logical, "descriptors");
  if (descriptors == nullptr || descriptors->rows.size() != layout.images.size()) {
    SetError(error, "descriptor metadata does not match topology");
    return false;
  }
  for (std::size_t image_index = 0; image_index < layout.images.size();
       ++image_index) {
    Row& row = descriptors->rows[image_index];
    std::int64_t image_id = 0;
    std::int64_t rows = 0;
    if (row.values.size() != 5 || !IntegerValue(row.values[0], &image_id) ||
        !IntegerValue(row.values[2], &rows) ||
        image_id != layout.images[image_index].image_id || rows < 0 ||
        static_cast<std::uint64_t>(rows) != layout.images[image_index].rows) {
      SetError(error, "descriptor metadata row mismatch");
      return false;
    }
    Value data;
    data.type = ValueType::kBlob;
    data.bytes.reserve(static_cast<std::size_t>(rows) * 128);
    for (std::uint64_t node = layout.images[image_index].base;
         node < layout.images[image_index].base + layout.images[image_index].rows;
         ++node) {
      data.bytes.insert(data.bytes.end(), layout.values[node].begin(),
                        layout.values[node].end());
    }
    row.values[4] = std::move(data);
  }
  return true;
}

std::vector<std::uint8_t> SerializeNumericBlock(
    const std::string& kind,
    const std::vector<std::vector<std::uint8_t>>& records,
    std::uint64_t start,
    std::uint32_t count,
    std::uint32_t columns,
    std::uint32_t element_width) {
  Writer writer;
  static constexpr char kMagic[] = "PWA2NBL1";
  writer.Bytes(kMagic, sizeof(kMagic) - 1);
  writer.String(kind);
  writer.U64(start);
  writer.U32(count);
  writer.U32(columns);
  writer.U32(element_width);
  for (std::uint32_t column = 0; column < columns; ++column) {
    for (std::uint32_t byte_plane = 0; byte_plane < element_width;
         ++byte_plane) {
      for (std::uint32_t record = 0; record < count; ++record) {
        writer.U8(records[start + record][column * element_width + byte_plane]);
      }
    }
  }
  return writer.data();
}

bool ParseNumericBlock(const std::vector<std::uint8_t>& bytes,
                       const std::string& expected_kind,
                       std::uint64_t expected_start,
                       std::uint32_t expected_count,
                       std::uint32_t expected_columns,
                       std::uint32_t expected_width,
                       std::vector<std::vector<std::uint8_t>>* records) {
  Reader reader(bytes);
  static constexpr char kMagic[] = "PWA2NBL1";
  std::array<char, sizeof(kMagic) - 1> magic{};
  std::string kind;
  std::uint64_t start = 0;
  std::uint32_t count = 0;
  std::uint32_t columns = 0;
  std::uint32_t width = 0;
  if (!reader.Bytes(magic.data(), magic.size()) ||
      std::memcmp(magic.data(), kMagic, magic.size()) != 0 ||
      !reader.String(&kind) || kind != expected_kind ||
      !reader.U64(&start) || start != expected_start ||
      !reader.U32(&count) || count != expected_count ||
      !reader.U32(&columns) || columns != expected_columns ||
      !reader.U32(&width) || width != expected_width || columns == 0 ||
      width == 0) {
    return false;
  }
  records->assign(count,
                  std::vector<std::uint8_t>(columns * width, std::uint8_t{0}));
  for (std::uint32_t column = 0; column < columns; ++column) {
    for (std::uint32_t byte_plane = 0; byte_plane < width; ++byte_plane) {
      for (std::uint32_t record = 0; record < count; ++record) {
        if (!reader.U8(
                &(*records)[record][column * width + byte_plane])) {
          return false;
        }
      }
    }
  }
  return reader.Done();
}

bool BuildNumericMembers(
    DatabaseLogical* metadata,
    const std::string& table_name,
    const std::string& prefix,
    std::uint32_t element_width,
    std::uint32_t block_records,
    std::map<std::string, std::vector<std::uint8_t>>* members,
    std::uint64_t* record_count,
    std::uint64_t* byte_count,
    std::string* error) {
  Table* table = FindTableMutable(metadata, table_name);
  if (table == nullptr || block_records == 0) {
    SetError(error, "numeric table is missing: " + table_name);
    return false;
  }
  std::vector<std::vector<std::uint8_t>> records;
  std::uint32_t common_columns = 0;
  for (Row& row : table->rows) {
    if (row.values.size() < 4) {
      SetError(error, "malformed numeric row: " + table_name);
      return false;
    }
    std::int64_t rows = 0;
    std::int64_t columns = 0;
    if (!IntegerValue(row.values[1], &rows) ||
        !IntegerValue(row.values[2], &columns) || rows < 0 || columns <= 0 ||
        columns > 1024) {
      SetError(error, "unsupported numeric dimensions: " + table_name);
      return false;
    }
    if (common_columns == 0) {
      common_columns = static_cast<std::uint32_t>(columns);
    } else if (common_columns != static_cast<std::uint32_t>(columns)) {
      SetError(error, "mixed numeric column counts: " + table_name);
      return false;
    }
    const std::uint64_t expected_bytes =
        static_cast<std::uint64_t>(rows) * columns * element_width;
    if (expected_bytes == 0) {
      continue;
    }
    if (row.values[3].type != ValueType::kBlob ||
        row.values[3].bytes.size() != expected_bytes) {
      SetError(error, "numeric BLOB length mismatch: " + table_name);
      return false;
    }
    const std::size_t record_bytes =
        static_cast<std::size_t>(columns) * element_width;
    for (std::int64_t record = 0; record < rows; ++record) {
      const auto begin = row.values[3].bytes.begin() + record * record_bytes;
      records.emplace_back(begin, begin + record_bytes);
    }
    row.values[3] = Value{};
  }
  *record_count = records.size();
  *byte_count = records.size() * common_columns * element_width;
  std::uint32_t block_index = 0;
  for (std::uint64_t start = 0; start < records.size();
       start += block_records, ++block_index) {
    const std::uint32_t count = static_cast<std::uint32_t>(
        std::min<std::uint64_t>(block_records, records.size() - start));
    members->emplace(
        DescriptorBlockName(prefix, block_index),
        SerializeNumericBlock(prefix, records, start, count, common_columns,
                              element_width));
  }
  return true;
}

bool RestoreNumericMembers(
    DatabaseLogical* logical,
    const std::string& table_name,
    const std::string& prefix,
    std::uint32_t element_width,
    std::uint32_t block_records,
    const std::map<std::string, std::vector<std::uint8_t>>& members,
    std::string* error) {
  Table* table = FindTableMutable(logical, table_name);
  if (table == nullptr || block_records == 0) {
    SetError(error, "numeric metadata table is missing: " + table_name);
    return false;
  }
  std::uint64_t total_records = 0;
  std::uint32_t common_columns = 0;
  for (const Row& row : table->rows) {
    std::int64_t rows = 0;
    std::int64_t columns = 0;
    if (row.values.size() < 4 || !IntegerValue(row.values[1], &rows) ||
        !IntegerValue(row.values[2], &columns) || rows < 0 || columns <= 0) {
      return false;
    }
    if (common_columns == 0) {
      common_columns = static_cast<std::uint32_t>(columns);
    } else if (common_columns != static_cast<std::uint32_t>(columns)) {
      return false;
    }
    total_records += static_cast<std::uint64_t>(rows);
  }

  std::vector<std::vector<std::uint8_t>> records;
  for (std::uint64_t start = 0, block_index = 0; start < total_records;
       start += block_records, ++block_index) {
    const std::uint32_t count = static_cast<std::uint32_t>(
        std::min<std::uint64_t>(block_records, total_records - start));
    const auto member = members.find(DescriptorBlockName(
        prefix, static_cast<std::uint32_t>(block_index)));
    std::vector<std::vector<std::uint8_t>> block;
    if (member == members.end() ||
        !ParseNumericBlock(member->second, prefix, start, count, common_columns,
                           element_width, &block)) {
      SetError(error, "malformed numeric member: " + prefix);
      return false;
    }
    records.insert(records.end(), block.begin(), block.end());
  }
  if (records.size() != total_records) {
    return false;
  }

  std::size_t next_record = 0;
  for (Row& row : table->rows) {
    std::int64_t rows = 0;
    IntegerValue(row.values[1], &rows);
    if (rows == 0) {
      continue;
    }
    Value data;
    data.type = ValueType::kBlob;
    for (std::int64_t record = 0; record < rows; ++record) {
      if (next_record >= records.size()) {
        return false;
      }
      data.bytes.insert(data.bytes.end(), records[next_record].begin(),
                        records[next_record].end());
      ++next_record;
    }
    row.values[3] = std::move(data);
  }
  return next_record == records.size();
}

bool RestoreAllStructuredMembers(
    DatabaseLogical* logical,
    const std::map<std::string, std::vector<std::uint8_t>>& members,
    std::uint32_t block_records,
    std::string* error) {
  return RestoreDescriptorMembers(logical, members, error) &&
         RestoreNumericMembers(logical, "keypoints", "keypoints", 4,
                               block_records, members, error) &&
         RestoreNumericMembers(logical, "matches", "matches", 4,
                               block_records, members, error) &&
         RestoreNumericMembers(logical, "two_view_geometries", "two_view", 4,
                               block_records, members, error);
}

bool StructuredBlockRecords(
    const std::map<std::string, std::vector<std::uint8_t>>& members,
    std::uint32_t* block_records) {
  const auto topology = members.find("descriptor_topology.bin");
  DescriptorLayout layout;
  if (topology == members.end() ||
      !DeserializeDescriptorTopology(topology->second, &layout)) {
    return false;
  }
  *block_records = layout.block_records;
  return true;
}

}  // namespace

const char* StatusName(Status status) {
  switch (status) {
    case Status::kOk:
      return "ok";
    case Status::kInvalidArgument:
      return "invalid_argument";
    case Status::kInputFailed:
      return "input_failed";
    case Status::kOutputFailed:
      return "output_failed";
    case Status::kUnsupportedSchema:
      return "unsupported_schema";
    case Status::kMalformed:
      return "malformed";
    case Status::kChecksumMismatch:
      return "checksum_mismatch";
  }
  return "unknown";
}

Status PackDatabase(const std::string& source_database,
                    const std::string& output_directory,
                    const Options& options,
                    Stats* stats,
                    std::string* error) {
  if (source_database.empty() || output_directory.empty() || stats == nullptr ||
      options.descriptor_block_records == 0) {
    SetError(error, "invalid pack arguments");
    return Status::kInvalidArgument;
  }
  if (std::filesystem::exists(output_directory)) {
    SetError(error, "output directory already exists");
    return Status::kOutputFailed;
  }

  DatabaseLogical logical;
  if (!LoadLogicalDatabase(source_database, &logical, error)) {
    return Status::kInputFailed;
  }
  if (!ValidateSupportedSchema(logical, error)) {
    return Status::kUnsupportedSchema;
  }
  DatabaseLogical metadata = logical;
  std::map<std::string, std::vector<std::uint8_t>> members;
  if (!BuildDescriptorMembers(&metadata, options, &members, stats, error)) {
    return Status::kMalformed;
  }
  const auto numeric_block_records =
      static_cast<std::uint32_t>(options.descriptor_block_records);
  if (!BuildNumericMembers(&metadata, "keypoints", "keypoints", 4,
                           numeric_block_records, &members,
                           &stats->keypoint_records, &stats->keypoint_bytes,
                           error) ||
      !BuildNumericMembers(&metadata, "matches", "matches", 4,
                           numeric_block_records, &members,
                           &stats->match_records, &stats->match_bytes, error) ||
      !BuildNumericMembers(&metadata, "two_view_geometries", "two_view", 4,
                           numeric_block_records, &members,
                           &stats->two_view_records, &stats->two_view_bytes,
                           error)) {
    return Status::kMalformed;
  }
  std::vector<std::uint8_t> tables;
  std::vector<std::uint8_t> indices;
  if (!LogicalBytes(metadata, &tables, &indices)) {
    SetError(error, "logical serialization failed");
    return Status::kMalformed;
  }
  members.emplace("tables.bin", std::move(tables));
  members.emplace("indices.bin", std::move(indices));

  const std::filesystem::path staging = output_directory + ".staging";
  std::error_code filesystem_error;
  std::filesystem::remove_all(staging, filesystem_error);
  if (!std::filesystem::create_directories(staging, filesystem_error) ||
      filesystem_error) {
    SetError(error, "cannot create staging directory");
    return Status::kOutputFailed;
  }
  std::vector<ManifestEntry> entries;
  entries.reserve(members.size());
  for (const auto& member : members) {
    entries.push_back(
        {member.first, member.second.size(), Sha256(member.second)});
  }
  const std::vector<std::uint8_t> manifest = SerializeManifest(entries);
  for (const auto& member : members) {
    if (!WriteFile(staging / member.first, member.second, error)) {
      std::filesystem::remove_all(staging, filesystem_error);
      return Status::kOutputFailed;
    }
  }
  if (!WriteFile(staging / "manifest.bin", manifest, error)) {
    std::filesystem::remove_all(staging, filesystem_error);
    return Status::kOutputFailed;
  }
  std::filesystem::rename(staging, output_directory, filesystem_error);
  if (filesystem_error) {
    std::filesystem::remove_all(staging, filesystem_error);
    SetError(error, "cannot publish member directory");
    return Status::kOutputFailed;
  }

  stats->table_count = logical.tables.size();
  stats->row_count = CountRows(logical);
  stats->member_count = entries.size() + 1;
  stats->raw_member_bytes = manifest.size();
  for (const auto& member : members) {
    stats->raw_member_bytes += member.second.size();
  }
  return Status::kOk;
}

Status VerifyDatabase(const std::string& source_database,
                      const std::string& member_directory,
                      Verification* verification,
                      std::string* error) {
  if (verification == nullptr) {
    SetError(error, "verification output is null");
    return Status::kInvalidArgument;
  }
  DatabaseLogical source;
  if (!LoadLogicalDatabase(source_database, &source, error)) {
    return Status::kInputFailed;
  }
  std::vector<std::uint8_t> source_tables;
  std::vector<std::uint8_t> source_indices;
  if (!ValidateSupportedSchema(source, error) ||
      !LogicalBytes(source, &source_tables, &source_indices)) {
    return Status::kUnsupportedSchema;
  }
  std::map<std::string, std::vector<std::uint8_t>> members;
  if (!LoadVerifiedMembers(member_directory, &members, error)) {
    return Status::kChecksumMismatch;
  }
  const auto tables = members.find("tables.bin");
  const auto indices = members.find("indices.bin");
  if (tables == members.end() || indices == members.end()) {
    SetError(error, "required logical member is missing");
    return Status::kMalformed;
  }
  DatabaseLogical restored;
  std::uint32_t block_records = 0;
  if (!DeserializeTables(tables->second, &restored) ||
      !DeserializeIndices(indices->second, &restored) ||
      !StructuredBlockRecords(members, &block_records) ||
      !RestoreAllStructuredMembers(&restored, members, block_records, error)) {
    return Status::kMalformed;
  }
  std::vector<std::uint8_t> restored_tables;
  std::vector<std::uint8_t> restored_indices;
  if (!LogicalBytes(restored, &restored_tables, &restored_indices)) {
    return Status::kMalformed;
  }
  verification->all_tables_covered = restored_tables == source_tables;
  verification->all_cells_equal = verification->all_tables_covered;
  verification->all_rows_and_order_equal = verification->all_tables_covered &&
                                            restored_indices == source_indices;
  verification->source_logical_sha256 = Hex(Sha256(source_tables));
  verification->restored_logical_sha256 = Hex(Sha256(restored_tables));
  if (!verification->all_rows_and_order_equal ||
      verification->source_logical_sha256 !=
          verification->restored_logical_sha256) {
    SetError(error, "logical contents differ");
    return Status::kMalformed;
  }
  return Status::kOk;
}

Status MaterializeDatabase(const std::string& member_directory,
                           const std::string& output_database,
                           std::string* error) {
  if (std::filesystem::exists(output_database)) {
    SetError(error, "materialized output already exists");
    return Status::kOutputFailed;
  }
  std::map<std::string, std::vector<std::uint8_t>> members;
  if (!LoadVerifiedMembers(member_directory, &members, error)) {
    return Status::kChecksumMismatch;
  }
  DatabaseLogical logical;
  std::uint32_t block_records = 0;
  if (!DeserializeTables(members["tables.bin"], &logical) ||
      !DeserializeIndices(members["indices.bin"], &logical) ||
      !StructuredBlockRecords(members, &block_records) ||
      !RestoreAllStructuredMembers(&logical, members, block_records, error) ||
      !ValidateSupportedSchema(logical, error)) {
    SetError(error, "cannot parse logical members");
    return Status::kMalformed;
  }

  ScopedDatabase database;
  if (sqlite3_open_v2(output_database.c_str(), database.out(),
                      SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nullptr) !=
      SQLITE_OK) {
    SetError(error, database.get() == nullptr ? "cannot create SQLite output"
                                             : sqlite3_errmsg(database.get()));
    return Status::kOutputFailed;
  }
  if (!Exec(database.get(), "PRAGMA foreign_keys=OFF; BEGIN IMMEDIATE;", error)) {
    return Status::kOutputFailed;
  }
  for (const Table& table : logical.tables) {
    if (table.name != "sqlite_sequence" &&
        (table.sql.empty() || !Exec(database.get(), table.sql, error))) {
      Exec(database.get(), "ROLLBACK", nullptr);
      return Status::kOutputFailed;
    }
  }
  for (const Table& table : logical.tables) {
    if (!InsertTableRows(database.get(), table, error)) {
      Exec(database.get(), "ROLLBACK", nullptr);
      return Status::kOutputFailed;
    }
  }
  for (const Index& index : logical.indices) {
    if (!Exec(database.get(), index.sql, error)) {
      Exec(database.get(), "ROLLBACK", nullptr);
      return Status::kOutputFailed;
    }
  }
  if (!Exec(database.get(), "COMMIT", error)) {
    return Status::kOutputFailed;
  }
  return Status::kOk;
}

Status CompareDatabasesLogical(const std::string& left_database,
                               const std::string& right_database,
                               bool* equal,
                               std::string* error) {
  if (equal == nullptr) {
    SetError(error, "equality output is null");
    return Status::kInvalidArgument;
  }
  DatabaseLogical left;
  DatabaseLogical right;
  if (!LoadLogicalDatabase(left_database, &left, error) ||
      !LoadLogicalDatabase(right_database, &right, error)) {
    return Status::kInputFailed;
  }
  std::vector<std::uint8_t> left_tables;
  std::vector<std::uint8_t> left_indices;
  std::vector<std::uint8_t> right_tables;
  std::vector<std::uint8_t> right_indices;
  if (!LogicalBytes(left, &left_tables, &left_indices) ||
      !LogicalBytes(right, &right_tables, &right_indices)) {
    return Status::kMalformed;
  }
  *equal = left_tables == right_tables && left_indices == right_indices;
  if (!*equal) {
    SetError(error, "canonical logical bytes differ");
  }
  return Status::kOk;
}

Status ReadDescriptor(const std::string& member_directory,
                      std::int64_t image_id,
                      std::int64_t row_index,
                      std::array<std::uint8_t, 128>* descriptor,
                      std::uint64_t* members_touched,
                      std::string* error) {
  if (descriptor == nullptr || members_touched == nullptr || row_index < 0) {
    return Status::kInvalidArgument;
  }
  std::map<std::string, ManifestEntry> manifest;
  if (!LoadManifestMap(member_directory, &manifest, error)) {
    return Status::kChecksumMismatch;
  }
  std::vector<std::uint8_t> topology_bytes;
  if (!ReadVerifiedMember(member_directory, "descriptor_topology.bin", manifest,
                          &topology_bytes, error)) {
    return Status::kChecksumMismatch;
  }
  DescriptorLayout layout;
  if (!DeserializeDescriptorTopology(topology_bytes, &layout)) {
    SetError(error, "malformed descriptor topology");
    return Status::kMalformed;
  }

  std::uint64_t target_node = std::numeric_limits<std::uint64_t>::max();
  for (const DescriptorImage& image : layout.images) {
    if (image.image_id == image_id &&
        static_cast<std::uint64_t>(row_index) < image.rows) {
      target_node = image.base + static_cast<std::uint64_t>(row_index);
      break;
    }
  }
  if (target_node == std::numeric_limits<std::uint64_t>::max()) {
    SetError(error, "descriptor not found");
    return Status::kInputFailed;
  }

  std::map<std::uint64_t, std::size_t> root_positions;
  for (std::size_t index = 0; index < layout.roots.size(); ++index) {
    root_positions.emplace(layout.roots[index], index);
  }
  std::map<std::uint64_t, std::size_t> residual_positions;
  for (std::size_t index = 0; index < layout.residuals.size(); ++index) {
    residual_positions.emplace(layout.residuals[index].child, index);
  }
  std::map<std::uint64_t, std::size_t> literal_positions;
  std::size_t literal_position = 0;
  for (std::uint64_t node = 0; node < layout.values.size(); ++node) {
    if (root_positions.find(node) == root_positions.end() &&
        residual_positions.find(node) == residual_positions.end()) {
      literal_positions.emplace(node, literal_position++);
    }
  }
  if (literal_positions.size() != layout.literals.size()) {
    return Status::kMalformed;
  }

  *members_touched = 0;
  std::map<std::string,
           std::vector<std::array<std::uint8_t, 128>>>
      block_cache;
  const auto read_class_record =
      [&](const std::string& prefix, const std::string& kind,
          std::size_t position, std::size_t total,
          std::array<std::uint8_t, 128>* value) -> bool {
    const std::uint64_t start =
        (position / layout.block_records) * layout.block_records;
    const std::uint32_t block_index =
        static_cast<std::uint32_t>(position / layout.block_records);
    const std::uint32_t count = static_cast<std::uint32_t>(
        std::min<std::size_t>(layout.block_records, total - start));
    const std::string name = DescriptorBlockName(prefix, block_index);
    auto cached = block_cache.find(name);
    if (cached == block_cache.end()) {
      std::vector<std::uint8_t> bytes;
      std::vector<std::array<std::uint8_t, 128>> decoded;
      if (!ReadVerifiedMember(member_directory, name, manifest, &bytes, error) ||
          !ParseDescriptorBlock(bytes, kind, start, count, &decoded)) {
        return false;
      }
      cached = block_cache.emplace(name, std::move(decoded)).first;
      ++*members_touched;
    }
    *value = cached->second[position - start];
    return true;
  };

  std::map<std::uint64_t, std::array<std::uint8_t, 128>> decoded_nodes;
  std::set<std::uint64_t> visiting;
  std::function<bool(std::uint64_t)> decode_node = [&](std::uint64_t node) {
    if (decoded_nodes.find(node) != decoded_nodes.end()) {
      return true;
    }
    if (!visiting.insert(node).second) {
      SetError(error, "descriptor dependency cycle");
      return false;
    }
    std::array<std::uint8_t, 128> value{};
    const auto root = root_positions.find(node);
    const auto residual = residual_positions.find(node);
    const auto literal = literal_positions.find(node);
    bool ok = false;
    if (root != root_positions.end()) {
      ok = read_class_record("descriptor_roots", "roots", root->second,
                             layout.roots.size(), &value);
    } else if (literal != literal_positions.end()) {
      ok = read_class_record("descriptor_literals", "literals",
                             literal->second, layout.literals.size(), &value);
    } else if (residual != residual_positions.end()) {
      const DescriptorEdge& edge = layout.residuals[residual->second];
      std::array<std::uint8_t, 128> delta{};
      ok = decode_node(edge.parent) &&
           read_class_record("descriptor_residuals", "residuals",
                             residual->second, layout.residuals.size(), &delta);
      if (ok) {
        for (std::size_t column = 0; column < 128; ++column) {
          value[column] = static_cast<std::uint8_t>(
              decoded_nodes[edge.parent][column] + delta[column]);
        }
      }
    }
    visiting.erase(node);
    if (ok) {
      decoded_nodes.emplace(node, value);
    }
    return ok;
  };

  if (!decode_node(target_node)) {
    if (error != nullptr && error->empty()) {
      *error = "descriptor reconstruction failed";
    }
    return Status::kMalformed;
  }
  *descriptor = decoded_nodes[target_node];
  return Status::kOk;
}

}  // namespace pw::pwa2
