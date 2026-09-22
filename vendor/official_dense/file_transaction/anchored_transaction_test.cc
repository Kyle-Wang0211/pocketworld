// Copyright (c) 2026, PocketWorld contributors.
// SPDX-License-Identifier: BSD-3-Clause

#include "anchored_transaction.h"
#include "official_dense/anchored_transaction_c.h"

#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <limits.h>
#include <string>
#include <system_error>
#include <utility>

#include <sys/stat.h>
#include <unistd.h>

namespace fs = std::filesystem;
using pocketworld::official_dense::file_transaction::AnchoredTransaction;

namespace {

int failures = 0;

void Check(bool condition, const char* expression, int line) {
  if (!condition) {
    std::cerr << "line " << line << ": check failed: " << expression << '\n';
    ++failures;
  }
}

#define CHECK(expression) Check((expression), #expression, __LINE__)

class TemporaryDirectory final {
 public:
  TemporaryDirectory() {
    char path_template[] = "/tmp/pw-anchored-transaction.XXXXXX";
    char* created = ::mkdtemp(path_template);
    if (created == nullptr) {
      std::abort();
    }
    char canonical[PATH_MAX];
    if (::realpath(created, canonical) == nullptr) {
      std::abort();
    }
    path_ = canonical;
  }

  ~TemporaryDirectory() {
    std::error_code ignored;
    fs::remove_all(path_, ignored);
  }

  TemporaryDirectory(const TemporaryDirectory&) = delete;
  TemporaryDirectory& operator=(const TemporaryDirectory&) = delete;

  const fs::path& path() const { return path_; }

 private:
  fs::path path_;
};

void WriteFile(const fs::path& path, const std::string& contents) {
  fs::create_directories(path.parent_path());
  std::ofstream stream(path, std::ios::binary | std::ios::trunc);
  stream << contents;
  stream.close();
  if (!stream) {
    std::abort();
  }
}

std::string ReadFile(const fs::path& path) {
  std::ifstream stream(path, std::ios::binary);
  return std::string(std::istreambuf_iterator<char>(stream),
                     std::istreambuf_iterator<char>());
}

void MakeCapture(const fs::path& capture) {
  fs::create_directories(capture / "official_dense" / "runs" / "run-1");
}

AnchoredTransaction OpenTransaction(const fs::path& capture) {
  AnchoredTransaction transaction;
  std::string error;
  CHECK(AnchoredTransaction::Open(capture.string(), "official_dense",
                                  "runs/run-1", &transaction, &error));
  CHECK(error.empty());
  CHECK(transaction.valid());
  return transaction;
}

void TestOpenRejectsLinksAndTraversal() {
  TemporaryDirectory temporary;
  const fs::path capture = temporary.path() / "capture";
  MakeCapture(capture);

  AnchoredTransaction transaction = OpenTransaction(capture);
  AnchoredTransaction moved(std::move(transaction));
  CHECK(!transaction.valid());
  CHECK(moved.valid());

  std::string error;
  AnchoredTransaction rejected;
  CHECK(!AnchoredTransaction::Open("relative/capture", "official_dense",
                                   "runs/run-1", &rejected, &error));
  CHECK(!error.empty());
  CHECK(!AnchoredTransaction::Open(capture.string(), "../official_dense",
                                   "runs/run-1", &rejected, &error));
  CHECK(!AnchoredTransaction::Open(capture.string(), "official_dense",
                                   "runs/../run-1", &rejected, &error));
  CHECK(!AnchoredTransaction::Open(
      capture.string() + std::string("\0ignored", 8), "official_dense",
      "runs/run-1", &rejected, &error));
  CHECK(!AnchoredTransaction::Open(
      capture.string(), std::string("official_dense\0ignored", 22),
      "runs/run-1", &rejected, &error));
  CHECK(!AnchoredTransaction::Open(capture.string() + "/", "official_dense",
                                   "runs/run-1", &rejected, &error));

  const fs::path capture_link = temporary.path() / "capture-link";
  fs::create_directory_symlink(capture, capture_link);
  CHECK(!AnchoredTransaction::Open(capture_link.string(), "official_dense",
                                   "runs/run-1", &rejected, &error));

  const fs::path second_capture = temporary.path() / "capture-2";
  fs::create_directories(second_capture);
  fs::create_directory_symlink(capture / "official_dense",
                               second_capture / "official_dense");
  CHECK(!AnchoredTransaction::Open(second_capture.string(), "official_dense",
                                   "runs/run-1", &rejected, &error));

  const fs::path third_capture = temporary.path() / "capture-3";
  fs::create_directories(third_capture / "official_dense" / "runs");
  fs::create_directory_symlink(capture / "official_dense" / "runs" / "run-1",
                               third_capture / "official_dense" / "runs" /
                                   "run-1");
  CHECK(!AnchoredTransaction::Open(third_capture.string(), "official_dense",
                                   "runs/run-1", &rejected, &error));
}

void TestAnchoredCleanupNeverFollowsLinks() {
  TemporaryDirectory temporary;
  const fs::path capture = temporary.path() / "capture";
  const fs::path victim = temporary.path() / "victim";
  MakeCapture(capture);
  const fs::path dense = capture / "official_dense";
  WriteFile(victim / "keep.txt", "victim");

  const fs::path run = capture / "official_dense" / "runs" / "run-1";
  WriteFile(run / "owned" / "nested" / "delete.txt", "owned");
  fs::create_directory_symlink(victim, run / "owned" / "victim-link");
  AnchoredTransaction transaction = OpenTransaction(capture);

  std::string error;
  CHECK(transaction.RemoveRunOwnedEntry("owned", &error));
  CHECK(error.empty());
  CHECK(!fs::exists(run / "owned"));
  CHECK(ReadFile(victim / "keep.txt") == "victim");

  fs::create_directory_symlink(victim, run / "escape-parent");
  CHECK(!transaction.RemoveRunOwnedEntry("escape-parent/keep.txt", &error));
  CHECK(ReadFile(victim / "keep.txt") == "victim");
  CHECK(transaction.RemoveRunOwnedEntry("escape-parent", &error));
  CHECK(transaction.RemoveRunOwnedEntry("owned", &error));

  fs::create_directory_symlink(victim, run / "top-link");
  CHECK(transaction.RemoveRunOwnedEntry("top-link", &error));
  CHECK(!fs::exists(run / "top-link"));
  CHECK(ReadFile(victim / "keep.txt") == "victim");

  CHECK(!transaction.RemoveRunOwnedEntry("../victim", &error));
  CHECK(!transaction.RemoveRunOwnedEntry("nested/../../victim", &error));
  CHECK(ReadFile(victim / "keep.txt") == "victim");
}

void TestPublishAcceptsOnlyNonEmptyRegularPly() {
  TemporaryDirectory temporary;
  const fs::path capture = temporary.path() / "capture";
  MakeCapture(capture);
  const fs::path dense = capture / "official_dense";
  const fs::path run = dense / "runs" / "run-1";
  fs::create_directories(run / "outputs");
  fs::create_directories(dense / "published");
  AnchoredTransaction transaction = OpenTransaction(capture);

  std::string error;
  WriteFile(run / "outputs" / "fused.ply", "ply-new");
  WriteFile(dense / "published" / "fused.ply", "ply-old");
  CHECK(transaction.PublishPly("outputs/fused.ply", "published/fused.ply",
                               &error));
  CHECK(error.empty());
  CHECK(!fs::exists(run / "outputs" / "fused.ply"));
  CHECK(ReadFile(dense / "published" / "fused.ply") == "ply-new");

  WriteFile(run / "empty.ply", "");
  CHECK(!transaction.PublishPly("empty.ply", "empty.ply", &error));
  CHECK(fs::exists(run / "empty.ply"));

  WriteFile(run / "not-ply.bin", "content");
  CHECK(!transaction.PublishPly("not-ply.bin", "not-ply.bin", &error));
  CHECK(fs::exists(run / "not-ply.bin"));

  fs::create_directories(run / "directory.ply");
  CHECK(!transaction.PublishPly("directory.ply", "directory.ply", &error));

  const fs::path fifo = run / "fifo.ply";
  CHECK(::mkfifo(fifo.c_str(), 0600) == 0);
  CHECK(!transaction.PublishPly("fifo.ply", "fifo.ply", &error));

  const fs::path victim = temporary.path() / "victim.ply";
  WriteFile(victim, "victim");
  fs::create_symlink(victim, run / "source-link.ply");
  CHECK(!transaction.PublishPly("source-link.ply", "source-link.ply", &error));
  CHECK(ReadFile(victim) == "victim");

  WriteFile(run / "destination-link-source.ply", "source");
  fs::create_symlink(victim, dense / "destination-link.ply");
  CHECK(!transaction.PublishPly("destination-link-source.ply",
                                "destination-link.ply", &error));
  CHECK(ReadFile(victim) == "victim");
  CHECK(fs::exists(run / "destination-link-source.ply"));

  WriteFile(run / "destination-directory-source.ply", "source");
  fs::create_directories(dense / "destination-directory.ply");
  CHECK(!transaction.PublishPly("destination-directory-source.ply",
                                "destination-directory.ply", &error));
  CHECK(fs::exists(run / "destination-directory-source.ply"));

  const fs::path source_parent_victim = temporary.path() / "source-parent";
  WriteFile(source_parent_victim / "fused.ply", "victim-source");
  fs::create_directory_symlink(source_parent_victim,
                               run / "source-parent-link");
  CHECK(!transaction.PublishPly("source-parent-link/fused.ply",
                                "source-parent-link.ply", &error));
  CHECK(ReadFile(source_parent_victim / "fused.ply") == "victim-source");

  const fs::path destination_parent_victim =
      temporary.path() / "destination-parent";
  fs::create_directories(destination_parent_victim);
  WriteFile(run / "destination-parent-source.ply", "source");
  fs::create_directory_symlink(destination_parent_victim,
                               dense / "destination-parent-link");
  CHECK(!transaction.PublishPly(
      "destination-parent-source.ply",
      "destination-parent-link/published.ply", &error));
  CHECK(!fs::exists(destination_parent_victim / "published.ply"));
  CHECK(fs::exists(run / "destination-parent-source.ply"));

  CHECK(!transaction.PublishPly("../outside.ply", "outside.ply", &error));
  CHECK(!transaction.PublishPly("destination-link-source.ply",
                                "../outside.ply", &error));
}

void TestParentPathSymlinkSwapCannotRedirectOperations() {
  TemporaryDirectory temporary;
  const fs::path capture_path = temporary.path() / "capture";
  const fs::path anchored_capture = temporary.path() / "anchored-capture";
  const fs::path victim_capture = temporary.path() / "victim-capture";
  MakeCapture(capture_path);
  MakeCapture(victim_capture);

  const fs::path original_run =
      capture_path / "official_dense" / "runs" / "run-1";
  const fs::path victim_run =
      victim_capture / "official_dense" / "runs" / "run-1";
  WriteFile(original_run / "owned" / "delete.txt", "owned");
  WriteFile(original_run / "fused.ply", "anchored-ply");
  WriteFile(victim_run / "owned" / "keep.txt", "victim-owned");
  WriteFile(victim_capture / "official_dense" / "published.ply",
            "victim-ply");

  AnchoredTransaction transaction = OpenTransaction(capture_path);

  fs::rename(capture_path, anchored_capture);
  fs::create_directory_symlink(victim_capture, capture_path);

  std::string error;
  CHECK(transaction.RemoveRunOwnedEntry("owned", &error));
  CHECK(transaction.PublishPly("fused.ply", "published.ply", &error));
  CHECK(transaction.RemoveRunDirectory(&error));

  CHECK(!fs::exists(anchored_capture / "official_dense" / "runs" / "run-1" /
                    "owned"));
  CHECK(ReadFile(anchored_capture / "official_dense" / "published.ply") ==
        "anchored-ply");
  CHECK(ReadFile(victim_run / "owned" / "keep.txt") == "victim-owned");
  CHECK(ReadFile(victim_capture / "official_dense" / "published.ply") ==
        "victim-ply");

  fs::remove(capture_path);
}

void TestVersionedCApiUsesTheSameAnchoredOperations() {
  TemporaryDirectory temporary;
  const fs::path capture_path = temporary.path() / "capture";
  const fs::path anchored_capture = temporary.path() / "anchored-capture";
  const fs::path victim_capture = temporary.path() / "victim-capture";
  MakeCapture(capture_path);
  MakeCapture(victim_capture);
  WriteFile(capture_path / "official_dense" / "runs" / "run-1" /
                "fused.ply",
            "anchored-ply");
  WriteFile(victim_capture / "official_dense" / "runs" / "run-1" /
                "keep.txt",
            "victim");

  pwofficial_dense_tx_v1_t* transaction = nullptr;
  CHECK(pwofficial_dense_tx_open_v1(capture_path.c_str(), "official_dense",
                                    "runs/run-1", &transaction) == 0);
  CHECK(transaction != nullptr);
  fs::rename(capture_path, anchored_capture);
  fs::create_directory_symlink(victim_capture, capture_path);

  CHECK(pwofficial_dense_tx_publish_ply_v1(transaction, "fused.ply",
                                           "published.ply") == 0);
  CHECK(pwofficial_dense_tx_remove_run_directory_v1(transaction) == 0);
  CHECK(ReadFile(anchored_capture / "official_dense" / "published.ply") ==
        "anchored-ply");
  CHECK(ReadFile(victim_capture / "official_dense" / "runs" / "run-1" /
                     "keep.txt") == "victim");
  CHECK(!fs::exists(victim_capture / "official_dense" / "published.ply"));
  CHECK(std::string(pwofficial_dense_tx_last_error_v1()).empty());
  pwofficial_dense_tx_close_v1(transaction);
  fs::remove(capture_path);
}

}  // namespace

int main() {
  TestOpenRejectsLinksAndTraversal();
  TestAnchoredCleanupNeverFollowsLinks();
  TestPublishAcceptsOnlyNonEmptyRegularPly();
  TestParentPathSymlinkSwapCannotRedirectOperations();
  TestVersionedCApiUsesTheSameAnchoredOperations();
  if (failures != 0) {
    std::cerr << failures << " anchored transaction checks failed\n";
    return 1;
  }
  std::cout << "anchored transaction checks passed\n";
  return 0;
}
