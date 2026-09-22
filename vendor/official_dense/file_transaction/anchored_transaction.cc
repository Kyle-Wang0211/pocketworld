// Copyright (c) 2026, PocketWorld contributors.
// SPDX-License-Identifier: BSD-3-Clause

#include "anchored_transaction.h"

#include <cerrno>
#include <cstring>
#include <string_view>
#include <utility>
#include <vector>

#if defined(__APPLE__) || defined(__ANDROID__) || defined(__linux__) || \
    defined(__OHOS__)
#define PW_OFFICIAL_DENSE_HAS_POSIX_DIRFD 1
#include <dirent.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>
#else
#define PW_OFFICIAL_DENSE_HAS_POSIX_DIRFD 0
#endif

namespace pocketworld::official_dense::file_transaction {
namespace {

void SetError(std::string* error, std::string message) noexcept {
  if (error != nullptr) {
    *error = std::move(message);
  }
}

#if PW_OFFICIAL_DENSE_HAS_POSIX_DIRFD

constexpr int DirectoryOpenFlags() noexcept {
  int flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW;
#ifdef O_CLOEXEC
  flags |= O_CLOEXEC;
#endif
  return flags;
}

constexpr int FileOpenFlags() noexcept {
  int flags = O_RDONLY | O_NOFOLLOW | O_NONBLOCK;
#ifdef O_CLOEXEC
  flags |= O_CLOEXEC;
#endif
  return flags;
}

std::string ErrnoMessage(std::string_view operation) {
  std::string message(operation);
  message.append(": ");
  message.append(std::strerror(errno));
  return message;
}

bool SameFileIdentity(const struct stat& lhs, const struct stat& rhs) noexcept {
  return lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino;
}

int DuplicateCloexec(int fd, std::string* error) noexcept {
#ifdef F_DUPFD_CLOEXEC
  const int cloexec_duplicate = ::fcntl(fd, F_DUPFD_CLOEXEC, 0);
  if (cloexec_duplicate >= 0) {
    return cloexec_duplicate;
  }
  if (errno != EINVAL) {
    SetError(error, ErrnoMessage("fcntl(F_DUPFD_CLOEXEC)"));
    return -1;
  }
#endif
  const int plain_duplicate = ::dup(fd);
  if (plain_duplicate < 0) {
    SetError(error, ErrnoMessage("dup"));
    return -1;
  }
  if (::fcntl(plain_duplicate, F_SETFD, FD_CLOEXEC) != 0) {
    const int saved_errno = errno;
    ::close(plain_duplicate);
    errno = saved_errno;
    SetError(error, ErrnoMessage("fcntl(F_SETFD)"));
    return -1;
  }
  return plain_duplicate;
}

bool SplitRelativePath(const std::string& path,
                       std::vector<std::string>* components,
                       std::string* error) noexcept {
  if (components == nullptr) {
    SetError(error, "path component output is null");
    return false;
  }
  components->clear();
  if (path.empty() || path.front() == '/' ||
      path.find('\0') != std::string::npos) {
    SetError(error, "path must be a non-empty relative path");
    return false;
  }

  std::size_t begin = 0;
  while (begin <= path.size()) {
    const std::size_t separator = path.find('/', begin);
    const std::size_t end =
        separator == std::string::npos ? path.size() : separator;
    const std::string component = path.substr(begin, end - begin);
    if (component.empty() || component == "." || component == "..") {
      SetError(error, "path contains an unsafe component");
      components->clear();
      return false;
    }
    components->push_back(component);
    if (separator == std::string::npos) {
      break;
    }
    begin = separator + 1;
  }
  return !components->empty();
}

bool SplitAbsolutePath(const std::string& path,
                       std::vector<std::string>* components,
                       std::string* error) noexcept {
  if (components == nullptr) {
    SetError(error, "path component output is null");
    return false;
  }
  components->clear();
  if (path.empty() || path.front() != '/' || path.back() == '/' ||
      path.find('\0') != std::string::npos) {
    SetError(error, "capture path must be absolute");
    return false;
  }
  if (path == "/") {
    SetError(error, "filesystem root cannot be a capture directory");
    return false;
  }

  std::size_t begin = 1;
  while (begin < path.size()) {
    const std::size_t separator = path.find('/', begin);
    const std::size_t end =
        separator == std::string::npos ? path.size() : separator;
    const std::string component = path.substr(begin, end - begin);
    if (component.empty() || component == "." || component == "..") {
      SetError(error, "capture path contains an unsafe component");
      components->clear();
      return false;
    }
    components->push_back(component);
    if (separator == std::string::npos) {
      break;
    }
    begin = separator + 1;
  }
  if (components->empty()) {
    SetError(error, "capture path has no directory component");
    return false;
  }
  return true;
}

int OpenDirectoryComponent(int parent_fd,
                           const std::string& component,
                           std::string* error) noexcept {
  struct stat before {};
  if (::fstatat(parent_fd, component.c_str(), &before,
                AT_SYMLINK_NOFOLLOW) != 0) {
    SetError(error, ErrnoMessage("fstatat(directory)"));
    return -1;
  }
  if (!S_ISDIR(before.st_mode)) {
    SetError(error, "directory component is not a real directory");
    return -1;
  }

  const int child_fd =
      ::openat(parent_fd, component.c_str(), DirectoryOpenFlags());
  if (child_fd < 0) {
    SetError(error, ErrnoMessage("openat(directory, O_NOFOLLOW)"));
    return -1;
  }

  struct stat after {};
  if (::fstat(child_fd, &after) != 0) {
    const int saved_errno = errno;
    ::close(child_fd);
    errno = saved_errno;
    SetError(error, ErrnoMessage("fstat(open directory)"));
    return -1;
  }
  if (!S_ISDIR(after.st_mode) || !SameFileIdentity(before, after)) {
    ::close(child_fd);
    SetError(error, "directory component changed while it was opened");
    return -1;
  }
  return child_fd;
}

int OpenAbsoluteDirectory(const std::string& path,
                          std::string* error) noexcept {
  std::vector<std::string> components;
  if (!SplitAbsolutePath(path, &components, error)) {
    return -1;
  }

  int current_fd = ::open("/", DirectoryOpenFlags());
  if (current_fd < 0) {
    SetError(error, ErrnoMessage("open(filesystem root)"));
    return -1;
  }
  for (const std::string& component : components) {
    const int next_fd = OpenDirectoryComponent(current_fd, component, error);
    ::close(current_fd);
    if (next_fd < 0) {
      return -1;
    }
    current_fd = next_fd;
  }
  return current_fd;
}

int OpenRelativeDirectory(int root_fd,
                          const std::string& path,
                          std::string* error) noexcept {
  std::vector<std::string> components;
  if (!SplitRelativePath(path, &components, error)) {
    return -1;
  }
  int current_fd = DuplicateCloexec(root_fd, error);
  if (current_fd < 0) {
    return -1;
  }
  for (const std::string& component : components) {
    const int next_fd = OpenDirectoryComponent(current_fd, component, error);
    ::close(current_fd);
    if (next_fd < 0) {
      return -1;
    }
    current_fd = next_fd;
  }
  return current_fd;
}

struct ParentAndName {
  int parent_fd = -1;
  std::string name;
};

bool OpenParent(int root_fd,
                const std::string& path,
                ParentAndName* output,
                std::string* error) noexcept {
  if (output == nullptr) {
    SetError(error, "parent output is null");
    return false;
  }
  output->parent_fd = -1;
  output->name.clear();

  std::vector<std::string> components;
  if (!SplitRelativePath(path, &components, error)) {
    return false;
  }
  int parent_fd = DuplicateCloexec(root_fd, error);
  if (parent_fd < 0) {
    return false;
  }
  for (std::size_t index = 0; index + 1 < components.size(); ++index) {
    const int next_fd =
        OpenDirectoryComponent(parent_fd, components[index], error);
    ::close(parent_fd);
    if (next_fd < 0) {
      return false;
    }
    parent_fd = next_fd;
  }
  output->parent_fd = parent_fd;
  output->name = std::move(components.back());
  return true;
}

bool IsPlyName(const std::string& name) noexcept {
  constexpr std::string_view suffix = ".ply";
  return name.size() > suffix.size() &&
         std::string_view(name).substr(name.size() - suffix.size()) == suffix;
}

bool RemoveEntryAt(int parent_fd,
                   const std::string& name,
                   std::string* error) noexcept {
  struct stat entry_stat {};
  if (::fstatat(parent_fd, name.c_str(), &entry_stat,
                AT_SYMLINK_NOFOLLOW) != 0) {
    if (errno == ENOENT) {
      return true;
    }
    SetError(error, ErrnoMessage("fstatat(remove entry)"));
    return false;
  }

  if (!S_ISDIR(entry_stat.st_mode)) {
    if (::unlinkat(parent_fd, name.c_str(), 0) != 0) {
      SetError(error, ErrnoMessage("unlinkat(file)"));
      return false;
    }
    return true;
  }

  const int opened_fd =
      ::openat(parent_fd, name.c_str(), DirectoryOpenFlags());
  if (opened_fd < 0) {
    SetError(error, ErrnoMessage("openat(remove directory, O_NOFOLLOW)"));
    return false;
  }

  struct stat opened_stat {};
  if (::fstat(opened_fd, &opened_stat) != 0 ||
      !S_ISDIR(opened_stat.st_mode) ||
      !SameFileIdentity(entry_stat, opened_stat)) {
    const int saved_errno = errno;
    ::close(opened_fd);
    errno = saved_errno;
    SetError(error, "directory changed while cleanup opened it");
    return false;
  }

  DIR* directory = ::fdopendir(opened_fd);
  if (directory == nullptr) {
    const int saved_errno = errno;
    ::close(opened_fd);
    errno = saved_errno;
    SetError(error, ErrnoMessage("fdopendir"));
    return false;
  }

  bool success = true;
  errno = 0;
  while (const struct dirent* entry = ::readdir(directory)) {
    const std::string_view child(entry->d_name);
    if (child == "." || child == "..") {
      errno = 0;
      continue;
    }
    if (!RemoveEntryAt(::dirfd(directory), std::string(child), error)) {
      success = false;
      break;
    }
    errno = 0;
  }
  if (success && errno != 0) {
    SetError(error, ErrnoMessage("readdir"));
    success = false;
  }
  if (::closedir(directory) != 0 && success) {
    SetError(error, ErrnoMessage("closedir"));
    success = false;
  }
  if (!success) {
    return false;
  }

  struct stat current_stat {};
  if (::fstatat(parent_fd, name.c_str(), &current_stat,
                AT_SYMLINK_NOFOLLOW) != 0) {
    SetError(error, ErrnoMessage("fstatat(directory before unlink)"));
    return false;
  }
  if (!S_ISDIR(current_stat.st_mode) ||
      !SameFileIdentity(entry_stat, current_stat)) {
    SetError(error, "directory changed before cleanup could unlink it");
    return false;
  }
  if (::unlinkat(parent_fd, name.c_str(), AT_REMOVEDIR) != 0) {
    SetError(error, ErrnoMessage("unlinkat(directory)"));
    return false;
  }
  return true;
}

#endif  // PW_OFFICIAL_DENSE_HAS_POSIX_DIRFD

}  // namespace

AnchoredTransaction::AnchoredTransaction(int capture_fd,
                                         int dense_fd,
                                         int run_fd,
                                         std::string run_relative_path) noexcept
    : capture_fd_(capture_fd),
      dense_fd_(dense_fd),
      run_fd_(run_fd),
      run_relative_path_(std::move(run_relative_path)) {}

AnchoredTransaction::~AnchoredTransaction() noexcept { Reset(); }

AnchoredTransaction::AnchoredTransaction(AnchoredTransaction&& other) noexcept
    : capture_fd_(std::exchange(other.capture_fd_, -1)),
      dense_fd_(std::exchange(other.dense_fd_, -1)),
      run_fd_(std::exchange(other.run_fd_, -1)),
      run_relative_path_(std::move(other.run_relative_path_)) {}

AnchoredTransaction& AnchoredTransaction::operator=(
    AnchoredTransaction&& other) noexcept {
  if (this != &other) {
    Reset();
    capture_fd_ = std::exchange(other.capture_fd_, -1);
    dense_fd_ = std::exchange(other.dense_fd_, -1);
    run_fd_ = std::exchange(other.run_fd_, -1);
    run_relative_path_ = std::move(other.run_relative_path_);
  }
  return *this;
}

void AnchoredTransaction::Reset() noexcept {
#if PW_OFFICIAL_DENSE_HAS_POSIX_DIRFD
  if (run_fd_ >= 0) {
    ::close(run_fd_);
  }
  if (dense_fd_ >= 0) {
    ::close(dense_fd_);
  }
  if (capture_fd_ >= 0) {
    ::close(capture_fd_);
  }
#endif
  capture_fd_ = -1;
  dense_fd_ = -1;
  run_fd_ = -1;
  run_relative_path_.clear();
}

bool AnchoredTransaction::Open(const std::string& capture_path,
                               const std::string& dense_relative_path,
                               const std::string& run_relative_path,
                               AnchoredTransaction* transaction,
                               std::string* error) noexcept {
  if (transaction == nullptr) {
    SetError(error, "transaction output is null");
    return false;
  }
  transaction->Reset();
#if PW_OFFICIAL_DENSE_HAS_POSIX_DIRFD
  int capture_fd = OpenAbsoluteDirectory(capture_path, error);
  if (capture_fd < 0) {
    return false;
  }
  int dense_fd =
      OpenRelativeDirectory(capture_fd, dense_relative_path, error);
  if (dense_fd < 0) {
    ::close(capture_fd);
    return false;
  }
  int run_fd = OpenRelativeDirectory(dense_fd, run_relative_path, error);
  if (run_fd < 0) {
    ::close(dense_fd);
    ::close(capture_fd);
    return false;
  }
  *transaction = AnchoredTransaction(capture_fd, dense_fd, run_fd,
                                     run_relative_path);
  if (error != nullptr) {
    error->clear();
  }
  return true;
#else
  (void)capture_path;
  (void)dense_relative_path;
  (void)run_relative_path;
  SetError(error, "POSIX directory-descriptor transactions are unavailable");
  return false;
#endif
}

bool AnchoredTransaction::valid() const noexcept {
#if PW_OFFICIAL_DENSE_HAS_POSIX_DIRFD
  return capture_fd_ >= 0 && dense_fd_ >= 0 && run_fd_ >= 0;
#else
  return false;
#endif
}

bool AnchoredTransaction::RemoveRunOwnedEntry(
    const std::string& run_relative_path,
    std::string* error) const noexcept {
#if PW_OFFICIAL_DENSE_HAS_POSIX_DIRFD
  if (!valid()) {
    SetError(error, "transaction is not open");
    return false;
  }
  ParentAndName entry;
  if (!OpenParent(run_fd_, run_relative_path, &entry, error)) {
    return false;
  }
  const bool success = RemoveEntryAt(entry.parent_fd, entry.name, error);
  ::close(entry.parent_fd);
  if (success && error != nullptr) {
    error->clear();
  }
  return success;
#else
  (void)run_relative_path;
  SetError(error, "POSIX directory-descriptor transactions are unavailable");
  return false;
#endif
}

bool AnchoredTransaction::RemoveRunDirectory(std::string* error) const noexcept {
#if PW_OFFICIAL_DENSE_HAS_POSIX_DIRFD
  if (!valid()) {
    SetError(error, "transaction is not open");
    return false;
  }
  ParentAndName entry;
  if (!OpenParent(dense_fd_, run_relative_path_, &entry, error)) {
    return false;
  }
  struct stat anchored_stat {};
  struct stat named_stat {};
  if (::fstat(run_fd_, &anchored_stat) != 0 ||
      ::fstatat(entry.parent_fd, entry.name.c_str(), &named_stat,
                AT_SYMLINK_NOFOLLOW) != 0 ||
      !S_ISDIR(named_stat.st_mode) ||
      !SameFileIdentity(anchored_stat, named_stat)) {
    ::close(entry.parent_fd);
    SetError(error, "run directory identity changed before cleanup");
    return false;
  }
  const bool success = RemoveEntryAt(entry.parent_fd, entry.name, error);
  ::close(entry.parent_fd);
  if (success && error != nullptr) {
    error->clear();
  }
  return success;
#else
  SetError(error, "POSIX directory-descriptor transactions are unavailable");
  return false;
#endif
}

bool AnchoredTransaction::PublishPly(
    const std::string& run_relative_source,
    const std::string& dense_relative_destination,
    std::string* error) const noexcept {
#if PW_OFFICIAL_DENSE_HAS_POSIX_DIRFD
  if (!valid()) {
    SetError(error, "transaction is not open");
    return false;
  }
  ParentAndName source;
  if (!OpenParent(run_fd_, run_relative_source, &source, error)) {
    return false;
  }
  ParentAndName destination;
  if (!OpenParent(dense_fd_, dense_relative_destination, &destination, error)) {
    ::close(source.parent_fd);
    return false;
  }
  if (!IsPlyName(source.name) || !IsPlyName(destination.name)) {
    ::close(destination.parent_fd);
    ::close(source.parent_fd);
    SetError(error, "source and destination must have a .ply suffix");
    return false;
  }

  struct stat source_name_stat {};
  if (::fstatat(source.parent_fd, source.name.c_str(), &source_name_stat,
                AT_SYMLINK_NOFOLLOW) != 0 ||
      !S_ISREG(source_name_stat.st_mode) || source_name_stat.st_size <= 0) {
    ::close(destination.parent_fd);
    ::close(source.parent_fd);
    SetError(error, "source PLY must be a non-empty regular file");
    return false;
  }

  const int source_fd =
      ::openat(source.parent_fd, source.name.c_str(), FileOpenFlags());
  if (source_fd < 0) {
    ::close(destination.parent_fd);
    ::close(source.parent_fd);
    SetError(error, ErrnoMessage("openat(source PLY, O_NOFOLLOW)"));
    return false;
  }
  struct stat source_stat {};
  if (::fstat(source_fd, &source_stat) != 0 ||
      !S_ISREG(source_stat.st_mode) || source_stat.st_size <= 0 ||
      !SameFileIdentity(source_name_stat, source_stat)) {
    ::close(source_fd);
    ::close(destination.parent_fd);
    ::close(source.parent_fd);
    SetError(error, "source PLY must be a non-empty regular file");
    return false;
  }

  if (::fstatat(source.parent_fd, source.name.c_str(), &source_name_stat,
                AT_SYMLINK_NOFOLLOW) != 0 ||
      !S_ISREG(source_name_stat.st_mode) ||
      !SameFileIdentity(source_stat, source_name_stat)) {
    ::close(source_fd);
    ::close(destination.parent_fd);
    ::close(source.parent_fd);
    SetError(error, "source PLY changed while it was validated");
    return false;
  }

  struct stat destination_stat {};
  if (::fstatat(destination.parent_fd, destination.name.c_str(),
                &destination_stat, AT_SYMLINK_NOFOLLOW) == 0) {
    if (!S_ISREG(destination_stat.st_mode)) {
      ::close(source_fd);
      ::close(destination.parent_fd);
      ::close(source.parent_fd);
      SetError(error, "destination PLY is not a regular file");
      return false;
    }
  } else if (errno != ENOENT) {
    const std::string message = ErrnoMessage("fstatat(destination PLY)");
    ::close(source_fd);
    ::close(destination.parent_fd);
    ::close(source.parent_fd);
    SetError(error, message);
    return false;
  }

  if (::renameat(source.parent_fd, source.name.c_str(), destination.parent_fd,
                 destination.name.c_str()) != 0) {
    const std::string message = ErrnoMessage("renameat(publish PLY)");
    ::close(source_fd);
    ::close(destination.parent_fd);
    ::close(source.parent_fd);
    SetError(error, message);
    return false;
  }

  struct stat published_stat {};
  const bool published =
      ::fstatat(destination.parent_fd, destination.name.c_str(),
                &published_stat, AT_SYMLINK_NOFOLLOW) == 0 &&
      S_ISREG(published_stat.st_mode) && published_stat.st_size > 0 &&
      SameFileIdentity(source_stat, published_stat);
  ::close(source_fd);
  ::close(destination.parent_fd);
  ::close(source.parent_fd);
  if (!published) {
    SetError(error, "published PLY identity verification failed");
    return false;
  }
  if (error != nullptr) {
    error->clear();
  }
  return true;
#else
  (void)run_relative_source;
  (void)dense_relative_destination;
  SetError(error, "POSIX directory-descriptor transactions are unavailable");
  return false;
#endif
}

}  // namespace pocketworld::official_dense::file_transaction
