// Copyright (c) 2026, PocketWorld contributors.
// SPDX-License-Identifier: BSD-3-Clause

#ifndef POCKETWORLD_OFFICIAL_DENSE_FILE_TRANSACTION_ANCHORED_TRANSACTION_H_
#define POCKETWORLD_OFFICIAL_DENSE_FILE_TRANSACTION_ANCHORED_TRANSACTION_H_

#include <string>

namespace pocketworld::official_dense::file_transaction {

// Owns directory descriptors for one capture's dense run. Directory
// descriptors, rather than path strings, are the authority after Open().
// This prevents a later rename or symlink replacement of a pathname ancestor
// from redirecting cleanup or publication into a different tree.
class AnchoredTransaction final {
 public:
  AnchoredTransaction() noexcept = default;
  ~AnchoredTransaction() noexcept;

  AnchoredTransaction(const AnchoredTransaction&) = delete;
  AnchoredTransaction& operator=(const AnchoredTransaction&) = delete;

  AnchoredTransaction(AnchoredTransaction&& other) noexcept;
  AnchoredTransaction& operator=(AnchoredTransaction&& other) noexcept;

  // capture_path must be an absolute path whose existing components are real
  // directories, never symbolic links. dense_relative_path is resolved below
  // capture; run_relative_path is resolved below dense. Relative paths reject
  // empty, ".", "..", absolute, and empty components.
  static bool Open(const std::string& capture_path,
                   const std::string& dense_relative_path,
                   const std::string& run_relative_path,
                   AnchoredTransaction* transaction,
                   std::string* error) noexcept;

  [[nodiscard]] bool valid() const noexcept;

  // Idempotently removes a task-owned entry below the anchored run directory.
  // A directory is traversed only after openat(O_DIRECTORY | O_NOFOLLOW) and
  // inode verification. A symbolic link encountered inside an owned tree is
  // unlinked as a link and is never followed.
  bool RemoveRunOwnedEntry(const std::string& run_relative_path,
                           std::string* error) const noexcept;

  // Idempotently removes exactly the run directory passed to Open(). The
  // currently named directory must still have the same device/inode identity
  // as the anchored run descriptor. Callers cannot select another dense entry.
  bool RemoveRunDirectory(std::string* error) const noexcept;

  // Atomically moves a non-empty regular .ply from the anchored run directory
  // to the anchored dense directory. Both arguments may name existing parent
  // directories below their respective anchors, but every path component must
  // be a safe relative component and every parent must be a real directory.
  // An existing destination must be a regular file; directories, links, and
  // other file types are rejected.
  bool PublishPly(const std::string& run_relative_source,
                  const std::string& dense_relative_destination,
                  std::string* error) const noexcept;

 private:
  explicit AnchoredTransaction(int capture_fd,
                               int dense_fd,
                               int run_fd,
                               std::string run_relative_path) noexcept;
  void Reset() noexcept;

  int capture_fd_ = -1;
  int dense_fd_ = -1;
  int run_fd_ = -1;
  std::string run_relative_path_;
};

}  // namespace pocketworld::official_dense::file_transaction

#endif  // POCKETWORLD_OFFICIAL_DENSE_FILE_TRANSACTION_ANCHORED_TRANSACTION_H_
