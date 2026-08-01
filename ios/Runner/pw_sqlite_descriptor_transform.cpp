#include "pw_sqlite_descriptor_transform.h"

#include <sqlite3.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <cerrno>
#include <cstddef>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <limits>
#include <map>
#include <new>
#include <set>
#include <string>
#include <utility>
#include <vector>

#include <fcntl.h>
#include <unistd.h>

namespace {

constexpr std::array<unsigned char, 16> kSQLiteMagic = {
    'S', 'Q', 'L', 'i', 't', 'e', ' ', 'f',
    'o', 'r', 'm', 'a', 't', ' ', '3', '\0'};
constexpr uint64_t kDescriptorColumns = 128;
constexpr uint64_t kMaxDescriptorBytes = 256ull * 1024ull * 1024ull;
constexpr uint64_t kMaxTotalDescriptorBytes = 512ull * 1024ull * 1024ull;
constexpr uint32_t kMaxBtreeDepth = 64;
constexpr int64_t kColmapMaxImageId = 2147483647ll;
constexpr uint64_t kNoDescriptorNode =
    std::numeric_limits<uint64_t>::max();

thread_local std::string g_last_error;
std::atomic<uint64_t> g_cancellation_generation{0};
thread_local bool g_cancellation_enabled = false;
thread_local uint64_t g_operation_generation = 0;

bool CurrentOperationCancelled() {
  return g_cancellation_enabled &&
         g_cancellation_generation.load(std::memory_order_acquire) !=
             g_operation_generation;
}

bool ContinueOperation() {
  if (!CurrentOperationCancelled()) {
    return true;
  }
  g_last_error = "descriptor transform cancelled";
  return false;
}

class ScopedCancellationOperation {
 public:
  explicit ScopedCancellationOperation(const uint64_t generation)
      : previous_enabled_(g_cancellation_enabled),
        previous_generation_(g_operation_generation) {
    g_cancellation_enabled = true;
    g_operation_generation = generation;
  }

  ~ScopedCancellationOperation() {
    g_cancellation_enabled = previous_enabled_;
    g_operation_generation = previous_generation_;
  }

 private:
  const bool previous_enabled_;
  const uint64_t previous_generation_;
};

struct DescriptorMetadata {
  int64_t rows = 0;
  int64_t columns = 0;
  int64_t bytes = 0;
};

struct PhysicalSpan {
  uint64_t offset = 0;
  uint64_t length = 0;
};

struct DescriptorLocation {
  int64_t row_id = 0;
  uint64_t rows = 0;
  std::vector<PhysicalSpan> spans;
};

struct DescriptorBuffer {
  const DescriptorLocation* location = nullptr;
  uint64_t first_node = 0;
  std::vector<unsigned char> bytes;
};

struct DescriptorRange {
  uint64_t first_node = 0;
  uint64_t rows = 0;
};

struct MatchEdge {
  uint64_t left = 0;
  uint64_t right = 0;

  bool operator<(const MatchEdge& other) const {
    return left < other.left || (left == other.left && right < other.right);
  }

  bool operator==(const MatchEdge& other) const {
    return left == other.left && right == other.right;
  }
};

class DisjointSet {
 public:
  explicit DisjointSet(const uint64_t count) : parent_(count) {
    for (uint64_t index = 0; index < count; ++index) {
      parent_[index] = index;
    }
  }

  uint64_t Find(uint64_t node) {
    uint64_t root = node;
    while (parent_[root] != root) {
      root = parent_[root];
    }
    while (parent_[node] != node) {
      const uint64_t next = parent_[node];
      parent_[node] = root;
      node = next;
    }
    return root;
  }

  bool Join(const uint64_t left, const uint64_t right) {
    const uint64_t left_root = Find(left);
    const uint64_t right_root = Find(right);
    if (left_root == right_root) {
      return false;
    }
    if (left_root < right_root) {
      parent_[right_root] = left_root;
    } else {
      parent_[left_root] = right_root;
    }
    return true;
  }

 private:
  std::vector<uint64_t> parent_;
};

uint16_t ReadBigEndian16(const unsigned char* bytes) {
  return static_cast<uint16_t>(
      (static_cast<uint16_t>(bytes[0]) << 8) |
      static_cast<uint16_t>(bytes[1]));
}

uint32_t ReadBigEndian32(const unsigned char* bytes) {
  return (static_cast<uint32_t>(bytes[0]) << 24) |
         (static_cast<uint32_t>(bytes[1]) << 16) |
         (static_cast<uint32_t>(bytes[2]) << 8) |
         static_cast<uint32_t>(bytes[3]);
}

uint32_t ReadLittleEndian32(const unsigned char* bytes) {
  return static_cast<uint32_t>(bytes[0]) |
         (static_cast<uint32_t>(bytes[1]) << 8) |
         (static_cast<uint32_t>(bytes[2]) << 16) |
         (static_cast<uint32_t>(bytes[3]) << 24);
}

bool AddFits(const uint64_t left,
             const uint64_t right,
             const uint64_t limit) {
  return left <= limit && right <= limit - left;
}

class RandomAccessFile {
 public:
  explicit RandomAccessFile(const std::string& path)
      : stream_(path, std::ios::binary | std::ios::in | std::ios::out) {
    if (!stream_) {
      return;
    }
    stream_.seekg(0, std::ios::end);
    const std::streamoff end = stream_.tellg();
    if (end < 0) {
      stream_.setstate(std::ios::failbit);
      return;
    }
    size_ = static_cast<uint64_t>(end);
  }

  bool valid() const { return stream_.is_open() && stream_.good(); }
  uint64_t size() const { return size_; }

  bool Read(const uint64_t offset, void* output, const uint64_t length) {
    if (!ContinueOperation() || !AddFits(offset, length, size_) ||
        length > static_cast<uint64_t>(
                     std::numeric_limits<std::streamsize>::max())) {
      return false;
    }
    stream_.clear();
    stream_.seekg(static_cast<std::streamoff>(offset), std::ios::beg);
    if (!stream_) {
      return false;
    }
    if (length == 0) {
      return true;
    }
    stream_.read(static_cast<char*>(output),
                 static_cast<std::streamsize>(length));
    return stream_.good();
  }

  bool Write(const uint64_t offset,
             const void* input,
             const uint64_t length) {
    if (!ContinueOperation() || !AddFits(offset, length, size_) ||
        length > static_cast<uint64_t>(
                     std::numeric_limits<std::streamsize>::max())) {
      return false;
    }
    stream_.clear();
    stream_.seekp(static_cast<std::streamoff>(offset), std::ios::beg);
    if (!stream_) {
      return false;
    }
    if (length == 0) {
      return true;
    }
    stream_.write(static_cast<const char*>(input),
                  static_cast<std::streamsize>(length));
    return stream_.good() && ContinueOperation();
  }

  bool Flush() {
    stream_.flush();
    return stream_.good();
  }

 private:
  std::fstream stream_;
  uint64_t size_ = 0;
};

bool CopyFile(const char* source_path, const char* output_path) {
  if (!ContinueOperation()) {
    return false;
  }
  std::ifstream input(source_path, std::ios::binary);
  if (!input) {
    g_last_error = "could not open source database";
    return false;
  }
  std::ofstream output(output_path, std::ios::binary | std::ios::trunc);
  if (!output) {
    g_last_error = "could not create transformed database";
    return false;
  }
  std::vector<char> buffer(1024 * 1024);
  while (input) {
    if (!ContinueOperation()) {
      return false;
    }
    input.read(buffer.data(), static_cast<std::streamsize>(buffer.size()));
    const std::streamsize count = input.gcount();
    if (count > 0) {
      output.write(buffer.data(), count);
      if (!output) {
        g_last_error = "could not write transformed database copy";
        return false;
      }
    }
  }
  if (!input.eof()) {
    g_last_error = "could not read source database";
    return false;
  }
  output.flush();
  if (!output) {
    g_last_error = "could not flush transformed database copy";
    return false;
  }
  output.close();
  if (!output) {
    g_last_error = "could not close transformed database copy";
    return false;
  }
  const int descriptor = open(output_path, O_RDONLY);
  if (descriptor < 0) {
    g_last_error = "could not reopen transformed database for sync";
    return false;
  }
  const bool synced = fsync(descriptor) == 0;
  const int saved_errno = errno;
  close(descriptor);
  if (!synced) {
    g_last_error =
        std::string("could not sync transformed database: ") +
        std::strerror(saved_errno);
    return false;
  }
  return true;
}

bool DecodeVarint(const unsigned char* bytes,
                  const size_t available,
                  uint64_t* value,
                  size_t* length) {
  uint64_t decoded = 0;
  const size_t first_bytes = std::min<size_t>(available, 8);
  for (size_t index = 0; index < first_bytes; ++index) {
    const unsigned char byte = bytes[index];
    decoded = (decoded << 7) | static_cast<uint64_t>(byte & 0x7f);
    if ((byte & 0x80) == 0) {
      *value = decoded;
      *length = index + 1;
      return true;
    }
  }
  if (available >= 9) {
    decoded = (decoded << 8) | static_cast<uint64_t>(bytes[8]);
    *value = decoded;
    *length = 9;
    return true;
  }
  return false;
}

uint64_t SerialTypeLength(const uint64_t serial_type, bool* valid) {
  *valid = true;
  switch (serial_type) {
    case 0:
    case 8:
    case 9:
      return 0;
    case 1:
      return 1;
    case 2:
      return 2;
    case 3:
      return 3;
    case 4:
      return 4;
    case 5:
      return 6;
    case 6:
    case 7:
      return 8;
    case 10:
    case 11:
      *valid = false;
      return 0;
    default:
      return (serial_type - 12) / 2;
  }
}

bool IsIntegerSerialType(const uint64_t serial_type) {
  return (serial_type >= 1 && serial_type <= 6) || serial_type == 8 ||
         serial_type == 9;
}

class PayloadReader {
 public:
  PayloadReader(RandomAccessFile* file,
                const std::vector<PhysicalSpan>* spans,
                const uint64_t size)
      : file_(file), spans_(spans), size_(size) {}

  bool Read(const uint64_t logical_offset,
            void* output,
            const uint64_t length) const {
    if (!AddFits(logical_offset, length, size_)) {
      return false;
    }
    unsigned char* destination = static_cast<unsigned char*>(output);
    uint64_t logical_cursor = 0;
    uint64_t wanted_start = logical_offset;
    uint64_t remaining = length;
    for (const PhysicalSpan& span : *spans_) {
      const uint64_t span_start = logical_cursor;
      const uint64_t span_end = logical_cursor + span.length;
      logical_cursor = span_end;
      if (remaining == 0) {
        break;
      }
      if (wanted_start >= span_end) {
        continue;
      }
      const uint64_t within =
          wanted_start > span_start ? wanted_start - span_start : 0;
      const uint64_t count = std::min(remaining, span.length - within);
      if (!file_->Read(span.offset + within, destination, count)) {
        return false;
      }
      destination += count;
      remaining -= count;
      wanted_start += count;
    }
    return remaining == 0;
  }

  bool ReadVarint(const uint64_t logical_offset,
                  uint64_t* value,
                  size_t* length) const {
    if (logical_offset >= size_) {
      return false;
    }
    std::array<unsigned char, 9> bytes{};
    const uint64_t available =
        std::min<uint64_t>(bytes.size(), size_ - logical_offset);
    return Read(logical_offset, bytes.data(), available) &&
           DecodeVarint(bytes.data(), static_cast<size_t>(available), value,
                        length);
  }

  std::vector<PhysicalSpan> Slice(const uint64_t logical_offset,
                                  const uint64_t length) const {
    std::vector<PhysicalSpan> result;
    if (!AddFits(logical_offset, length, size_)) {
      return result;
    }
    uint64_t logical_cursor = 0;
    uint64_t wanted_start = logical_offset;
    uint64_t remaining = length;
    for (const PhysicalSpan& span : *spans_) {
      const uint64_t span_start = logical_cursor;
      const uint64_t span_end = logical_cursor + span.length;
      logical_cursor = span_end;
      if (remaining == 0) {
        break;
      }
      if (wanted_start >= span_end) {
        continue;
      }
      const uint64_t within =
          wanted_start > span_start ? wanted_start - span_start : 0;
      const uint64_t count = std::min(remaining, span.length - within);
      result.push_back({span.offset + within, count});
      remaining -= count;
      wanted_start += count;
    }
    if (remaining != 0) {
      result.clear();
    }
    return result;
  }

 private:
  RandomAccessFile* file_;
  const std::vector<PhysicalSpan>* spans_;
  uint64_t size_;
};

bool ReadInteger(const PayloadReader& payload,
                 const uint64_t offset,
                 const uint64_t serial_type,
                 int64_t* value) {
  if (serial_type == 8) {
    *value = 0;
    return true;
  }
  if (serial_type == 9) {
    *value = 1;
    return true;
  }
  if (serial_type < 1 || serial_type > 6) {
    return false;
  }
  bool valid = false;
  const uint64_t length = SerialTypeLength(serial_type, &valid);
  if (!valid || length == 0 || length > 8) {
    return false;
  }
  std::array<unsigned char, 8> bytes{};
  if (!payload.Read(offset, bytes.data(), length)) {
    return false;
  }
  uint64_t decoded = (bytes[0] & 0x80) != 0
                         ? std::numeric_limits<uint64_t>::max()
                         : 0;
  for (uint64_t index = 0; index < length; ++index) {
    decoded = (decoded << 8) | bytes[index];
  }
  *value = static_cast<int64_t>(decoded);
  return true;
}

class SQLiteDescriptorParser {
 public:
  SQLiteDescriptorParser(RandomAccessFile* file,
                         const uint32_t page_size,
                         const uint32_t reserved_bytes,
                         const uint32_t page_count,
                         const std::map<int64_t, DescriptorMetadata>& metadata,
                         PWSQLiteDescriptorTransformStats* stats)
      : file_(file),
        page_size_(page_size),
        usable_size_(page_size - reserved_bytes),
        page_count_(page_count),
        metadata_(metadata),
        stats_(stats) {}

  bool Parse(const uint32_t root_page,
             std::vector<DescriptorLocation>* locations) {
    locations_ = locations;
    if (!WalkTable(root_page, 0)) {
      return false;
    }
    if (seen_rows_.size() != metadata_.size()) {
      g_last_error = "descriptors b-tree rows do not match SQLite query";
      return false;
    }
    return true;
  }

 private:
  bool ReadPage(const uint32_t page_number,
                std::vector<unsigned char>* page) {
    if (page_number == 0 || page_number > page_count_) {
      g_last_error = "SQLite page number is out of range";
      return false;
    }
    page->resize(page_size_);
    const uint64_t offset =
        (static_cast<uint64_t>(page_number) - 1) * page_size_;
    if (!file_->Read(offset, page->data(), page_size_)) {
      g_last_error = "could not read SQLite page";
      return false;
    }
    return true;
  }

  bool WalkTable(const uint32_t page_number, const uint32_t depth) {
    if (depth > kMaxBtreeDepth) {
      g_last_error = "SQLite b-tree depth exceeds safety limit";
      return false;
    }
    if (!btree_pages_.insert(page_number).second ||
        overflow_pages_.count(page_number) != 0) {
      g_last_error = "SQLite b-tree page is reused or cyclic";
      return false;
    }

    std::vector<unsigned char> page;
    if (!ReadPage(page_number, &page)) {
      return false;
    }
    const uint32_t header_offset = page_number == 1 ? 100 : 0;
    if (header_offset + 12 > usable_size_) {
      g_last_error = "SQLite b-tree page header is truncated";
      return false;
    }
    const unsigned char page_type = page[header_offset];
    if (page_type != 0x05 && page_type != 0x0d) {
      g_last_error = "descriptors root contains a non-table b-tree page";
      return false;
    }
    const uint32_t header_size = page_type == 0x05 ? 12 : 8;
    const uint32_t cell_count = ReadBigEndian16(&page[header_offset + 3]);
    const uint64_t pointer_end =
        static_cast<uint64_t>(header_offset) + header_size +
        static_cast<uint64_t>(cell_count) * 2;
    if (pointer_end > usable_size_) {
      g_last_error = "SQLite cell pointer array is out of bounds";
      return false;
    }

    for (uint32_t cell_index = 0; cell_index < cell_count; ++cell_index) {
      const uint32_t pointer_offset =
          header_offset + header_size + cell_index * 2;
      const uint32_t cell_offset =
          ReadBigEndian16(&page[pointer_offset]);
      if (cell_offset < pointer_end || cell_offset >= usable_size_) {
        g_last_error = "SQLite cell offset is out of bounds";
        return false;
      }
      if (page_type == 0x05) {
        if (cell_offset + 4 > usable_size_) {
          g_last_error = "SQLite interior cell is truncated";
          return false;
        }
        if (!WalkTable(ReadBigEndian32(&page[cell_offset]), depth + 1)) {
          return false;
        }
      } else if (!ParseLeafCell(page_number, page, cell_offset)) {
        return false;
      }
    }

    if (page_type == 0x05) {
      const uint32_t right_child =
          ReadBigEndian32(&page[header_offset + 8]);
      if (!WalkTable(right_child, depth + 1)) {
        return false;
      }
    }
    return true;
  }

  bool ParseLeafCell(const uint32_t page_number,
                     const std::vector<unsigned char>& page,
                     const uint32_t cell_offset) {
    uint64_t payload_size = 0;
    size_t payload_varint_length = 0;
    if (!DecodeVarint(&page[cell_offset], usable_size_ - cell_offset,
                      &payload_size, &payload_varint_length)) {
      g_last_error = "SQLite cell payload varint is invalid";
      return false;
    }
    uint64_t row_id_bits = 0;
    size_t rowid_varint_length = 0;
    const uint64_t rowid_offset =
        static_cast<uint64_t>(cell_offset) + payload_varint_length;
    if (rowid_offset >= usable_size_ ||
        !DecodeVarint(&page[rowid_offset], usable_size_ - rowid_offset,
                      &row_id_bits, &rowid_varint_length)) {
      g_last_error = "SQLite cell rowid varint is invalid";
      return false;
    }
    const int64_t row_id = static_cast<int64_t>(row_id_bits);
    const auto metadata = metadata_.find(row_id);
    if (metadata == metadata_.end() || !seen_rows_.insert(row_id).second) {
      g_last_error = "SQLite descriptors rowid is missing or duplicated";
      return false;
    }

    const uint64_t max_local = usable_size_ - 35;
    const uint64_t min_local =
        ((static_cast<uint64_t>(usable_size_) - 12) * 32 / 255) - 23;
    uint64_t local_payload = payload_size;
    if (payload_size > max_local) {
      const uint64_t candidate =
          min_local +
          ((payload_size - min_local) % (usable_size_ - 4));
      local_payload = candidate <= max_local ? candidate : min_local;
    }
    const uint64_t payload_offset =
        rowid_offset + rowid_varint_length;
    const uint64_t overflow_pointer_bytes =
        payload_size > local_payload ? 4 : 0;
    if (!AddFits(payload_offset, local_payload + overflow_pointer_bytes,
                 usable_size_)) {
      g_last_error = "SQLite local cell payload is out of bounds";
      return false;
    }

    std::vector<PhysicalSpan> payload_spans;
    if (local_payload != 0) {
      payload_spans.push_back(
          {(static_cast<uint64_t>(page_number) - 1) * page_size_ +
               payload_offset,
           local_payload});
    }
    uint64_t remaining = payload_size - local_payload;
    uint32_t overflow_page = 0;
    if (remaining != 0) {
      overflow_page = ReadBigEndian32(&page[payload_offset + local_payload]);
    }
    while (remaining != 0) {
      if (overflow_page == 0 || overflow_page > page_count_ ||
          btree_pages_.count(overflow_page) != 0 ||
          !overflow_pages_.insert(overflow_page).second) {
        g_last_error = "SQLite overflow chain is invalid or cyclic";
        return false;
      }
      std::vector<unsigned char> overflow;
      if (!ReadPage(overflow_page, &overflow)) {
        return false;
      }
      const uint32_t next_page = ReadBigEndian32(overflow.data());
      const uint64_t chunk =
          std::min<uint64_t>(remaining, usable_size_ - 4);
      payload_spans.push_back(
          {(static_cast<uint64_t>(overflow_page) - 1) * page_size_ + 4,
           chunk});
      remaining -= chunk;
      ++stats_->overflow_pages;
      if ((remaining == 0 && next_page != 0) ||
          (remaining != 0 && next_page == 0)) {
        g_last_error = "SQLite overflow chain length does not match payload";
        return false;
      }
      overflow_page = next_page;
    }

    return ParseRecord(row_id, payload_size, payload_spans, metadata->second);
  }

  bool ParseRecord(const int64_t row_id,
                   const uint64_t payload_size,
                   const std::vector<PhysicalSpan>& payload_spans,
                   const DescriptorMetadata& metadata) {
    PayloadReader payload(file_, &payload_spans, payload_size);
    uint64_t header_size = 0;
    size_t header_varint_length = 0;
    if (!payload.ReadVarint(0, &header_size, &header_varint_length) ||
        header_size < header_varint_length || header_size > payload_size) {
      g_last_error = "SQLite record header size is invalid";
      return false;
    }

    std::array<uint64_t, 5> serial_types{};
    uint64_t header_offset = header_varint_length;
    for (uint64_t& serial_type : serial_types) {
      size_t serial_length = 0;
      if (!payload.ReadVarint(header_offset, &serial_type, &serial_length) ||
          !AddFits(header_offset, serial_length, header_size)) {
        g_last_error = "SQLite record serial type is invalid";
        return false;
      }
      header_offset += serial_length;
    }
    if (header_offset != header_size) {
      g_last_error = "SQLite descriptors record has unexpected columns";
      return false;
    }
    if (serial_types[0] != 0 ||
        !IsIntegerSerialType(serial_types[1]) ||
        !IsIntegerSerialType(serial_types[2]) ||
        !IsIntegerSerialType(serial_types[3])) {
      g_last_error = "SQLite descriptors record types are incompatible";
      return false;
    }

    std::array<uint64_t, 5> value_offsets{};
    uint64_t value_offset = header_size;
    std::array<uint64_t, 5> value_lengths{};
    for (size_t index = 0; index < serial_types.size(); ++index) {
      bool valid = false;
      value_lengths[index] = SerialTypeLength(serial_types[index], &valid);
      value_offsets[index] = value_offset;
      if (!valid || !AddFits(value_offset, value_lengths[index], payload_size)) {
        g_last_error = "SQLite descriptors record value is out of bounds";
        return false;
      }
      value_offset += value_lengths[index];
    }
    if (value_offset != payload_size) {
      g_last_error = "SQLite descriptors record payload length is inconsistent";
      return false;
    }

    int64_t rows = 0;
    int64_t columns = 0;
    if (!ReadInteger(payload, value_offsets[2], serial_types[2], &rows) ||
        !ReadInteger(payload, value_offsets[3], serial_types[3], &columns) ||
        rows < 0 || columns != static_cast<int64_t>(kDescriptorColumns) ||
        rows != metadata.rows || columns != metadata.columns ||
        metadata.bytes < 0) {
      g_last_error = "SQLite descriptors dimensions are incompatible";
      return false;
    }
    if (static_cast<uint64_t>(rows) >
            std::numeric_limits<uint64_t>::max() / kDescriptorColumns ||
        static_cast<uint64_t>(rows) * kDescriptorColumns !=
            static_cast<uint64_t>(metadata.bytes)) {
      g_last_error = "SQLite descriptors byte length does not match dimensions";
      return false;
    }

    const uint64_t descriptor_bytes = static_cast<uint64_t>(metadata.bytes);
    const bool empty_null = descriptor_bytes == 0 && serial_types[4] == 0;
    const bool blob = serial_types[4] >= 12 && serial_types[4] % 2 == 0;
    if ((!empty_null && !blob) || value_lengths[4] != descriptor_bytes ||
        descriptor_bytes > kMaxDescriptorBytes) {
      g_last_error = "SQLite descriptors data is not a supported BLOB";
      return false;
    }
    std::vector<PhysicalSpan> descriptor_spans =
        payload.Slice(value_offsets[4], descriptor_bytes);
    if (descriptor_bytes != 0 && descriptor_spans.empty()) {
      g_last_error = "SQLite descriptor BLOB span mapping failed";
      return false;
    }
    locations_->push_back(
        {row_id, static_cast<uint64_t>(rows), std::move(descriptor_spans)});
    ++stats_->descriptor_records;
    stats_->descriptor_bytes += descriptor_bytes;
    return true;
  }

  RandomAccessFile* file_;
  uint32_t page_size_;
  uint32_t usable_size_;
  uint32_t page_count_;
  const std::map<int64_t, DescriptorMetadata>& metadata_;
  PWSQLiteDescriptorTransformStats* stats_;
  std::vector<DescriptorLocation>* locations_ = nullptr;
  std::set<uint32_t> btree_pages_;
  std::set<uint32_t> overflow_pages_;
  std::set<int64_t> seen_rows_;
};

bool ReadSchemaAndMetadata(
    const std::string& path,
    uint32_t* root_page,
    std::map<int64_t, DescriptorMetadata>* metadata) {
  sqlite3* database = nullptr;
  const std::string immutable_uri = "file:" + path + "?immutable=1";
  const int open_status = sqlite3_open_v2(
      immutable_uri.c_str(), &database,
      SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_URI, nullptr);
  if (open_status != SQLITE_OK) {
    g_last_error = database == nullptr ? "could not open SQLite database"
                                       : sqlite3_errmsg(database);
    if (database != nullptr) {
      sqlite3_close(database);
    }
    return false;
  }

  bool valid = true;
  sqlite3_stmt* statement = nullptr;
  const std::array<const char*, 5> expected_names = {
      "image_id", "type", "rows", "cols", "data"};
  const std::array<const char*, 5> expected_types = {
      "INTEGER", "INTEGER", "INTEGER", "INTEGER", "BLOB"};
  if (sqlite3_prepare_v2(database, "PRAGMA table_info(descriptors);", -1,
                         &statement, nullptr) != SQLITE_OK) {
    valid = false;
  }
  size_t column = 0;
  while (valid && sqlite3_step(statement) == SQLITE_ROW) {
    if (!ContinueOperation()) {
      valid = false;
      break;
    }
    if (column >= expected_names.size()) {
      valid = false;
      break;
    }
    const char* name =
        reinterpret_cast<const char*>(sqlite3_column_text(statement, 1));
    const char* type =
        reinterpret_cast<const char*>(sqlite3_column_text(statement, 2));
    const int not_null = sqlite3_column_int(statement, 3);
    const int primary_key = sqlite3_column_int(statement, 5);
    if (name == nullptr || type == nullptr ||
        std::strcmp(name, expected_names[column]) != 0 ||
        std::strcmp(type, expected_types[column]) != 0 ||
        not_null != (column == 4 ? 0 : 1) ||
        primary_key != (column == 0 ? 1 : 0)) {
      valid = false;
      break;
    }
    ++column;
  }
  if (statement != nullptr) {
    sqlite3_finalize(statement);
    statement = nullptr;
  }
  if (!valid || column != expected_names.size()) {
    g_last_error = "SQLite descriptors schema is incompatible";
    sqlite3_close(database);
    return false;
  }

  if (sqlite3_prepare_v2(
          database,
          "SELECT rootpage FROM sqlite_master "
          "WHERE type='table' AND name='descriptors';",
          -1, &statement, nullptr) != SQLITE_OK ||
      sqlite3_step(statement) != SQLITE_ROW) {
    g_last_error = "SQLite descriptors root page is unavailable";
    if (statement != nullptr) {
      sqlite3_finalize(statement);
    }
    sqlite3_close(database);
    return false;
  }
  const sqlite3_int64 root = sqlite3_column_int64(statement, 0);
  sqlite3_finalize(statement);
  statement = nullptr;
  if (root <= 0 || root > std::numeric_limits<uint32_t>::max()) {
    g_last_error = "SQLite descriptors root page is invalid";
    sqlite3_close(database);
    return false;
  }
  *root_page = static_cast<uint32_t>(root);

  if (sqlite3_prepare_v2(
          database,
          "SELECT image_id,rows,cols,length(data),typeof(data) "
          "FROM descriptors ORDER BY image_id;",
          -1, &statement, nullptr) != SQLITE_OK) {
    g_last_error = "SQLite descriptors metadata query failed";
    sqlite3_close(database);
    return false;
  }
  while (sqlite3_step(statement) == SQLITE_ROW) {
    if (!ContinueOperation()) {
      sqlite3_finalize(statement);
      sqlite3_close(database);
      return false;
    }
    const int64_t row_id = sqlite3_column_int64(statement, 0);
    DescriptorMetadata row;
    row.rows = sqlite3_column_int64(statement, 1);
    row.columns = sqlite3_column_int64(statement, 2);
    row.bytes = sqlite3_column_type(statement, 3) == SQLITE_NULL
                    ? 0
                    : sqlite3_column_int64(statement, 3);
    const char* storage =
        reinterpret_cast<const char*>(sqlite3_column_text(statement, 4));
    if (row.rows < 0 || row.columns != 128 || row.bytes < 0 ||
        (storage == nullptr ||
         (std::strcmp(storage, "blob") != 0 &&
          !(row.bytes == 0 && std::strcmp(storage, "null") == 0))) ||
        !metadata->emplace(row_id, row).second) {
      g_last_error = "SQLite descriptors metadata is incompatible";
      sqlite3_finalize(statement);
      sqlite3_close(database);
      return false;
    }
  }
  sqlite3_finalize(statement);
  if (sqlite3_close(database) != SQLITE_OK) {
    g_last_error = "could not close SQLite metadata connection";
    return false;
  }
  return true;
}

bool ReadHeader(RandomAccessFile* file,
                uint32_t* page_size,
                uint32_t* reserved_bytes,
                uint32_t* page_count) {
  std::array<unsigned char, 100> header{};
  if (file->size() < header.size() ||
      !file->Read(0, header.data(), header.size())) {
    g_last_error = "SQLite database header is truncated";
    return false;
  }
  if (!std::equal(kSQLiteMagic.begin(), kSQLiteMagic.end(), header.begin())) {
    g_last_error = "SQLite database magic is invalid";
    return false;
  }
  uint32_t decoded_page_size = ReadBigEndian16(&header[16]);
  if (decoded_page_size == 1) {
    decoded_page_size = 65536;
  }
  if (decoded_page_size < 512 || decoded_page_size > 65536 ||
      (decoded_page_size & (decoded_page_size - 1)) != 0) {
    g_last_error = "SQLite page size is invalid";
    return false;
  }
  const uint32_t decoded_reserved_bytes = header[20];
  if (decoded_reserved_bytes >= decoded_page_size ||
      decoded_page_size - decoded_reserved_bytes < 480) {
    g_last_error = "SQLite reserved-byte count is invalid";
    return false;
  }
  if (file->size() % decoded_page_size != 0 ||
      file->size() / decoded_page_size >
          std::numeric_limits<uint32_t>::max()) {
    g_last_error = "SQLite file size is not page aligned";
    return false;
  }
  const uint32_t actual_pages =
      static_cast<uint32_t>(file->size() / decoded_page_size);
  const uint32_t header_pages = ReadBigEndian32(&header[28]);
  if (actual_pages == 0 || header_pages != actual_pages) {
    g_last_error = "SQLite header page count does not match file size";
    return false;
  }
  *page_size = decoded_page_size;
  *reserved_bytes = decoded_reserved_bytes;
  *page_count = actual_pages;
  return true;
}

bool ReadSpans(RandomAccessFile* file,
               const std::vector<PhysicalSpan>& spans,
               std::vector<unsigned char>* bytes) {
  uint64_t total = 0;
  for (const PhysicalSpan& span : spans) {
    if (!AddFits(total, span.length, kMaxDescriptorBytes)) {
      return false;
    }
    total += span.length;
  }
  bytes->resize(static_cast<size_t>(total));
  uint64_t cursor = 0;
  for (const PhysicalSpan& span : spans) {
    if (!file->Read(span.offset, bytes->data() + cursor, span.length)) {
      return false;
    }
    cursor += span.length;
  }
  return true;
}

bool WriteSpans(RandomAccessFile* file,
                const std::vector<PhysicalSpan>& spans,
                const std::vector<unsigned char>& bytes) {
  uint64_t cursor = 0;
  for (const PhysicalSpan& span : spans) {
    if (!AddFits(cursor, span.length, bytes.size()) ||
        !file->Write(span.offset, bytes.data() + cursor, span.length)) {
      return false;
    }
    cursor += span.length;
  }
  return cursor == bytes.size();
}

bool ReadTrackEdges(const std::string& path,
                    const std::map<int64_t, DescriptorRange>& ranges,
                    std::vector<MatchEdge>* edges) {
  sqlite3* database = nullptr;
  const std::string immutable_uri = "file:" + path + "?immutable=1";
  const int open_status = sqlite3_open_v2(
      immutable_uri.c_str(), &database,
      SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_URI, nullptr);
  if (open_status != SQLITE_OK) {
    g_last_error = database == nullptr
                       ? "could not open SQLite match database"
                       : sqlite3_errmsg(database);
    if (database != nullptr) {
      sqlite3_close(database);
    }
    return false;
  }

  sqlite3_stmt* statement = nullptr;
  if (sqlite3_prepare_v2(
          database,
          "SELECT pair_id,rows,cols,data,typeof(data) "
          "FROM two_view_geometries WHERE rows>0 ORDER BY pair_id;",
          -1, &statement, nullptr) != SQLITE_OK) {
    g_last_error = "SQLite verified-match query failed";
    sqlite3_close(database);
    return false;
  }

  bool valid = true;
  while (valid && sqlite3_step(statement) == SQLITE_ROW) {
    if (!ContinueOperation()) {
      valid = false;
      break;
    }
    const int64_t pair_id = sqlite3_column_int64(statement, 0);
    const int64_t rows = sqlite3_column_int64(statement, 1);
    const int64_t columns = sqlite3_column_int64(statement, 2);
    const int blob_bytes = sqlite3_column_bytes(statement, 3);
    const auto* blob = static_cast<const unsigned char*>(
        sqlite3_column_blob(statement, 3));
    const char* storage = reinterpret_cast<const char*>(
        sqlite3_column_text(statement, 4));
    if (pair_id <= 0 || rows <= 0 || columns != 2 || blob_bytes < 0 ||
        rows > std::numeric_limits<int>::max() / 8 || blob_bytes != rows * 8 ||
        blob == nullptr || storage == nullptr ||
        std::strcmp(storage, "blob") != 0) {
      g_last_error = "SQLite verified-match record is incompatible";
      valid = false;
      break;
    }

    const int64_t image_id2 = pair_id % kColmapMaxImageId;
    const int64_t image_id1 = pair_id / kColmapMaxImageId;
    if (image_id1 <= 0 || image_id2 <= image_id1 ||
        image_id2 >= kColmapMaxImageId) {
      g_last_error = "COLMAP image pair identifier is invalid";
      valid = false;
      break;
    }
    const auto left_range = ranges.find(image_id1);
    const auto right_range = ranges.find(image_id2);
    if (left_range == ranges.end() || right_range == ranges.end()) {
      continue;
    }

    for (int64_t row = 0; row < rows; ++row) {
      const uint32_t left_row = ReadLittleEndian32(blob + row * 8);
      const uint32_t right_row = ReadLittleEndian32(blob + row * 8 + 4);
      if (left_row >= left_range->second.rows ||
          right_row >= right_range->second.rows) {
        g_last_error = "verified match descriptor index is out of range";
        valid = false;
        break;
      }
      uint64_t left = left_range->second.first_node + left_row;
      uint64_t right = right_range->second.first_node + right_row;
      if (left == right) {
        continue;
      }
      if (right < left) {
        std::swap(left, right);
      }
      edges->push_back({left, right});
    }
  }

  sqlite3_finalize(statement);
  if (sqlite3_close(database) != SQLITE_OK && valid) {
    g_last_error = "could not close SQLite match connection";
    valid = false;
  }
  if (!valid) {
    return false;
  }
  std::sort(edges->begin(), edges->end());
  edges->erase(std::unique(edges->begin(), edges->end()), edges->end());
  return true;
}

bool BuildTrackForest(const uint64_t node_count,
                      const std::vector<MatchEdge>& edges,
                      std::vector<uint64_t>* parent,
                      std::vector<uint64_t>* traversal,
                      uint64_t* matched_nodes) {
  DisjointSet sets(node_count);
  std::vector<MatchEdge> tree_edges;
  tree_edges.reserve(edges.size());
  for (const MatchEdge& edge : edges) {
    if (!ContinueOperation()) return false;
    if (edge.left >= node_count || edge.right >= node_count) {
      g_last_error = "verified match node is out of range";
      return false;
    }
    if (sets.Join(edge.left, edge.right)) {
      tree_edges.push_back(edge);
    }
  }

  std::vector<uint64_t> offsets(node_count + 1, 0);
  for (const MatchEdge& edge : tree_edges) {
    ++offsets[edge.left + 1];
    ++offsets[edge.right + 1];
  }
  for (uint64_t node = 0; node < node_count; ++node) {
    offsets[node + 1] += offsets[node];
  }
  std::vector<uint64_t> cursor = offsets;
  std::vector<uint64_t> neighbors(tree_edges.size() * 2);
  for (const MatchEdge& edge : tree_edges) {
    neighbors[cursor[edge.left]++] = edge.right;
    neighbors[cursor[edge.right]++] = edge.left;
  }
  for (uint64_t node = 0; node < node_count; ++node) {
    std::sort(neighbors.begin() + static_cast<std::ptrdiff_t>(offsets[node]),
              neighbors.begin() +
                  static_cast<std::ptrdiff_t>(offsets[node + 1]));
  }

  parent->assign(node_count, kNoDescriptorNode);
  traversal->clear();
  traversal->reserve(tree_edges.size() * 2);
  std::vector<uint64_t> queue;
  for (uint64_t root = 0; root < node_count; ++root) {
    if (!ContinueOperation()) return false;
    if (offsets[root] == offsets[root + 1] || sets.Find(root) != root) {
      continue;
    }
    const size_t component_begin = traversal->size();
    queue.clear();
    queue.push_back(root);
    (*parent)[root] = root;
    for (size_t head = 0; head < queue.size(); ++head) {
      const uint64_t node = queue[head];
      traversal->push_back(node);
      for (uint64_t index = offsets[node]; index < offsets[node + 1]; ++index) {
        const uint64_t neighbor = neighbors[index];
        if ((*parent)[neighbor] != kNoDescriptorNode) {
          continue;
        }
        (*parent)[neighbor] = node;
        queue.push_back(neighbor);
      }
    }
    if (traversal->size() == component_begin) {
      g_last_error = "verified match component traversal failed";
      return false;
    }
  }
  *matched_nodes = traversal->size();
  return true;
}

unsigned char* DescriptorNodeBytes(std::vector<DescriptorBuffer>* buffers,
                                   const uint64_t node) {
  auto upper = std::upper_bound(
      buffers->begin(), buffers->end(), node,
      [](const uint64_t value, const DescriptorBuffer& buffer) {
        return value < buffer.first_node;
      });
  if (upper == buffers->begin()) {
    return nullptr;
  }
  --upper;
  const uint64_t row = node - upper->first_node;
  if (upper->location == nullptr || row >= upper->location->rows) {
    return nullptr;
  }
  return upper->bytes.data() + row * kDescriptorColumns;
}

bool TransformTrackDelta(RandomAccessFile* file,
                         const std::string& path,
                         std::vector<DescriptorLocation>* locations,
                         const bool inverse,
                         PWSQLiteDescriptorTransformStats* stats) {
  std::sort(locations->begin(), locations->end(),
            [](const DescriptorLocation& left,
               const DescriptorLocation& right) {
              return left.row_id < right.row_id;
            });
  std::map<int64_t, DescriptorRange> ranges;
  std::vector<DescriptorBuffer> buffers;
  buffers.reserve(locations->size());
  uint64_t total_nodes = 0;
  uint64_t total_bytes = 0;
  for (const DescriptorLocation& location : *locations) {
    if (!ContinueOperation()) return false;
    const uint64_t bytes = location.rows * kDescriptorColumns;
    if (!AddFits(total_bytes, bytes, kMaxTotalDescriptorBytes) ||
        !ranges.emplace(location.row_id,
                        DescriptorRange{total_nodes, location.rows})
             .second) {
      g_last_error = "total descriptor bytes exceed track-transform limit";
      return false;
    }
    DescriptorBuffer buffer;
    buffer.location = &location;
    buffer.first_node = total_nodes;
    if (!ReadSpans(file, location.spans, &buffer.bytes) ||
        buffer.bytes.size() != bytes) {
      g_last_error = "could not read track descriptor bytes";
      return false;
    }
    buffers.push_back(std::move(buffer));
    total_nodes += location.rows;
    total_bytes += bytes;
  }

  std::vector<MatchEdge> edges;
  if (!ReadTrackEdges(path, ranges, &edges)) {
    return false;
  }
  std::vector<uint64_t> parent;
  std::vector<uint64_t> traversal;
  uint64_t matched_nodes = 0;
  if (!BuildTrackForest(total_nodes, edges, &parent, &traversal,
                        &matched_nodes)) {
    return false;
  }

  if (inverse) {
    for (const uint64_t node : traversal) {
      if (!ContinueOperation()) return false;
      const uint64_t parent_node = parent[node];
      if (parent_node == node) {
        continue;
      }
      unsigned char* child = DescriptorNodeBytes(&buffers, node);
      unsigned char* parent_bytes = DescriptorNodeBytes(&buffers, parent_node);
      if (child == nullptr || parent_bytes == nullptr) {
        g_last_error = "track descriptor node mapping failed";
        return false;
      }
      for (uint64_t column = 0; column < kDescriptorColumns; ++column) {
        child[column] = static_cast<unsigned char>(child[column] +
                                                   parent_bytes[column]);
      }
    }
  } else {
    for (auto iterator = traversal.rbegin(); iterator != traversal.rend();
         ++iterator) {
      if (!ContinueOperation()) return false;
      const uint64_t node = *iterator;
      const uint64_t parent_node = parent[node];
      if (parent_node == node) {
        continue;
      }
      unsigned char* child = DescriptorNodeBytes(&buffers, node);
      unsigned char* parent_bytes = DescriptorNodeBytes(&buffers, parent_node);
      if (child == nullptr || parent_bytes == nullptr) {
        g_last_error = "track descriptor node mapping failed";
        return false;
      }
      for (uint64_t column = 0; column < kDescriptorColumns; ++column) {
        child[column] = static_cast<unsigned char>(child[column] -
                                                   parent_bytes[column]);
      }
    }
  }

  for (const DescriptorBuffer& buffer : buffers) {
    if (!ContinueOperation()) return false;
    if (!WriteSpans(file, buffer.location->spans, buffer.bytes)) {
      g_last_error = "could not write track descriptor bytes";
      return false;
    }
  }
  stats->verified_match_edges = edges.size();
  stats->matched_descriptor_nodes = matched_nodes;
  stats->predicted_descriptor_nodes =
      matched_nodes == 0
          ? 0
          : static_cast<uint64_t>(std::count_if(
                traversal.begin(), traversal.end(),
                [&parent](const uint64_t node) { return parent[node] != node; }));
  return true;
}

bool TransformTranspose(RandomAccessFile* file,
                        const DescriptorLocation& location,
                        const int32_t transform,
                        const bool inverse) {
  std::vector<unsigned char> input;
  if (!ReadSpans(file, location.spans, &input) ||
      input.size() != location.rows * kDescriptorColumns) {
    g_last_error = "could not read descriptor BLOB spans";
    return false;
  }
  std::vector<unsigned char> transposed(input.size());
  if (inverse) {
    for (uint64_t column = 0; column < kDescriptorColumns; ++column) {
      unsigned char previous = 0;
      for (uint64_t row = 0; row < location.rows; ++row) {
        const size_t index = static_cast<size_t>(column * location.rows + row);
        const unsigned char encoded = input[index];
        unsigned char current = encoded;
        if (row != 0 && transform == PW_SQLITE_DESCRIPTOR_TRANSPOSE_XOR) {
          current = static_cast<unsigned char>(encoded ^ previous);
        } else if (row != 0 &&
                   transform == PW_SQLITE_DESCRIPTOR_TRANSPOSE_DELTA) {
          current = static_cast<unsigned char>(encoded + previous);
        }
        transposed[index] = current;
        previous = current;
      }
    }
  } else {
    for (uint64_t row = 0; row < location.rows; ++row) {
      for (uint64_t column = 0; column < kDescriptorColumns; ++column) {
        transposed[column * location.rows + row] =
            input[row * kDescriptorColumns + column];
      }
    }
  }

  std::vector<unsigned char> output(input.size());
  if (inverse) {
    for (uint64_t row = 0; row < location.rows; ++row) {
      for (uint64_t column = 0; column < kDescriptorColumns; ++column) {
        output[row * kDescriptorColumns + column] =
            transposed[column * location.rows + row];
      }
    }
  } else if (transform == PW_SQLITE_DESCRIPTOR_TRANSPOSE) {
    output = std::move(transposed);
  } else {
    for (uint64_t column = 0; column < kDescriptorColumns; ++column) {
      unsigned char previous = 0;
      for (uint64_t row = 0; row < location.rows; ++row) {
        const size_t index = static_cast<size_t>(column * location.rows + row);
        const unsigned char current = transposed[index];
        output[index] =
            row == 0
                ? current
                : transform == PW_SQLITE_DESCRIPTOR_TRANSPOSE_XOR
                      ? static_cast<unsigned char>(current ^ previous)
                      : static_cast<unsigned char>(current - previous);
        previous = current;
      }
    }
  }
  if (!WriteSpans(file, location.spans, output)) {
    g_last_error = "could not write transformed descriptor BLOB spans";
    return false;
  }
  return true;
}

bool SyncPath(const char* path) {
  const int descriptor = open(path, O_RDONLY);
  if (descriptor < 0) {
    return false;
  }
  const bool synced = fsync(descriptor) == 0;
  close(descriptor);
  return synced;
}

}  // namespace

const char* pw_sqlite_descriptor_transform_last_error(void) {
  return g_last_error.c_str();
}

int32_t pw_sqlite_descriptor_integrity_check_file(const char* database_path) {
  g_last_error.clear();
  if (database_path == nullptr || database_path[0] == '\0') {
    g_last_error = "database path is empty";
    return 0;
  }
  sqlite3* database = nullptr;
  const std::string immutable_uri =
      std::string("file:") + database_path + "?immutable=1";
  if (sqlite3_open_v2(immutable_uri.c_str(), &database,
                      SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX |
                          SQLITE_OPEN_URI,
                      nullptr) != SQLITE_OK) {
    g_last_error = database == nullptr ? "could not open SQLite database"
                                       : sqlite3_errmsg(database);
    if (database != nullptr) sqlite3_close(database);
    return 0;
  }
  sqlite3_stmt* statement = nullptr;
  const bool ok =
      sqlite3_prepare_v2(database, "PRAGMA integrity_check;", -1, &statement,
                         nullptr) == SQLITE_OK &&
      sqlite3_step(statement) == SQLITE_ROW &&
      sqlite3_column_text(statement, 0) != nullptr &&
      std::strcmp(reinterpret_cast<const char*>(
                      sqlite3_column_text(statement, 0)),
                  "ok") == 0;
  if (!ok) {
    g_last_error = "SQLite integrity_check did not return ok";
  }
  if (statement != nullptr) sqlite3_finalize(statement);
  if (sqlite3_close(database) != SQLITE_OK) {
    g_last_error = "could not close SQLite integrity connection";
    return 0;
  }
  return ok ? 1 : 0;
}

int32_t pw_sqlite_descriptor_transform_file(
    const char* source_path,
    const char* output_path,
    const int32_t transform,
    const int32_t inverse,
    PWSQLiteDescriptorTransformStats* stats) {
  g_last_error.clear();
  PWSQLiteDescriptorTransformStats local_stats{};
  PWSQLiteDescriptorTransformStats* output_stats =
      stats == nullptr ? &local_stats : stats;
  *output_stats = {};

  if (!ContinueOperation()) {
    std::remove(output_path);
    return PW_SQLITE_DESCRIPTOR_TRANSFORM_CANCELLED;
  }

  if (source_path == nullptr || output_path == nullptr ||
      source_path[0] == '\0' || output_path[0] == '\0' ||
      std::strcmp(source_path, output_path) == 0) {
    g_last_error = "source and output paths must be distinct";
    return PW_SQLITE_DESCRIPTOR_TRANSFORM_INVALID_ARGUMENT;
  }
  if (transform != PW_SQLITE_DESCRIPTOR_TRANSPOSE &&
      transform != PW_SQLITE_DESCRIPTOR_TRANSPOSE_XOR &&
      transform != PW_SQLITE_DESCRIPTOR_TRANSPOSE_DELTA &&
      transform != PW_SQLITE_DESCRIPTOR_TRACK_DELTA) {
    g_last_error = "descriptor transform is not implemented";
    return PW_SQLITE_DESCRIPTOR_TRANSFORM_UNSUPPORTED;
  }

  try {
    if (!CopyFile(source_path, output_path)) {
      std::remove(output_path);
      return CurrentOperationCancelled()
                 ? PW_SQLITE_DESCRIPTOR_TRANSFORM_CANCELLED
                 : PW_SQLITE_DESCRIPTOR_TRANSFORM_OUTPUT_FAILED;
    }

    std::map<int64_t, DescriptorMetadata> metadata;
    uint32_t root_page = 0;
    if (!ReadSchemaAndMetadata(output_path, &root_page, &metadata)) {
      std::remove(output_path);
      return CurrentOperationCancelled()
                 ? PW_SQLITE_DESCRIPTOR_TRANSFORM_CANCELLED
                 : PW_SQLITE_DESCRIPTOR_TRANSFORM_SCHEMA_FAILED;
    }

    RandomAccessFile file(output_path);
    if (!file.valid()) {
      g_last_error = "could not open transformed database for random access";
      std::remove(output_path);
      return PW_SQLITE_DESCRIPTOR_TRANSFORM_OUTPUT_FAILED;
    }
    uint32_t page_size = 0;
    uint32_t reserved_bytes = 0;
    uint32_t page_count = 0;
    if (!ReadHeader(&file, &page_size, &reserved_bytes, &page_count)) {
      std::remove(output_path);
      return PW_SQLITE_DESCRIPTOR_TRANSFORM_MALFORMED;
    }

    std::vector<DescriptorLocation> locations;
    SQLiteDescriptorParser parser(&file, page_size, reserved_bytes, page_count,
                                  metadata, output_stats);
    if (!parser.Parse(root_page, &locations)) {
      std::remove(output_path);
      return CurrentOperationCancelled()
                 ? PW_SQLITE_DESCRIPTOR_TRANSFORM_CANCELLED
                 : PW_SQLITE_DESCRIPTOR_TRANSFORM_MALFORMED;
    }
    if (transform == PW_SQLITE_DESCRIPTOR_TRACK_DELTA) {
      if (!TransformTrackDelta(&file, output_path, &locations, inverse != 0,
                               output_stats)) {
        std::remove(output_path);
        return CurrentOperationCancelled()
                   ? PW_SQLITE_DESCRIPTOR_TRANSFORM_CANCELLED
                   : PW_SQLITE_DESCRIPTOR_TRANSFORM_OUTPUT_FAILED;
      }
    } else {
      for (const DescriptorLocation& location : locations) {
        if (!TransformTranspose(&file, location, transform, inverse != 0)) {
          std::remove(output_path);
          return CurrentOperationCancelled()
                     ? PW_SQLITE_DESCRIPTOR_TRANSFORM_CANCELLED
                     : PW_SQLITE_DESCRIPTOR_TRANSFORM_OUTPUT_FAILED;
        }
      }
    }
    if (!file.Flush() || !SyncPath(output_path)) {
      g_last_error = "could not durably flush transformed database";
      std::remove(output_path);
      return PW_SQLITE_DESCRIPTOR_TRANSFORM_OUTPUT_FAILED;
    }
    if (!ContinueOperation()) {
      std::remove(output_path);
      return PW_SQLITE_DESCRIPTOR_TRANSFORM_CANCELLED;
    }
    return PW_SQLITE_DESCRIPTOR_TRANSFORM_OK;
  } catch (const std::bad_alloc&) {
    g_last_error = "descriptor transform allocation failed";
    std::remove(output_path);
    return PW_SQLITE_DESCRIPTOR_TRANSFORM_ALLOCATION_FAILED;
  } catch (const std::exception& error) {
    g_last_error = error.what();
    std::remove(output_path);
    return PW_SQLITE_DESCRIPTOR_TRANSFORM_MALFORMED;
  } catch (...) {
    g_last_error = "unknown descriptor transform failure";
    std::remove(output_path);
    return PW_SQLITE_DESCRIPTOR_TRANSFORM_MALFORMED;
  }
}

uint64_t pw_sqlite_descriptor_transform_cancellation_generation(void) {
  return g_cancellation_generation.load(std::memory_order_acquire);
}

void pw_sqlite_descriptor_transform_request_cancel(void) {
  g_cancellation_generation.fetch_add(1, std::memory_order_acq_rel);
}

int32_t pw_sqlite_descriptor_transform_file_cancellable(
    const char* source_path,
    const char* output_path,
    const int32_t transform,
    const int32_t inverse,
    const uint64_t cancellation_generation,
    PWSQLiteDescriptorTransformStats* stats) {
  ScopedCancellationOperation operation(cancellation_generation);
  return pw_sqlite_descriptor_transform_file(source_path, output_path,
                                             transform, inverse, stats);
}
