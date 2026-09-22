// Copyright (c) 2026, PocketWorld contributors.
// SPDX-License-Identifier: BSD-3-Clause

#include "official_dense/anchored_transaction_c.h"

#include <exception>
#include <new>
#include <string>

#include "anchored_transaction.h"

using pocketworld::official_dense::file_transaction::AnchoredTransaction;

struct pwofficial_dense_tx_v1 {
  AnchoredTransaction transaction;
};

namespace {

thread_local std::string g_last_error;

bool IsNonEmpty(const char* value) noexcept {
  return value != nullptr && value[0] != '\0';
}

int32_t Invalid(const char* message) noexcept {
  try {
    g_last_error = message;
  } catch (...) {
    g_last_error.clear();
  }
  return 1;
}

int32_t OperationResult(bool success, std::string error) noexcept {
  try {
    g_last_error = std::move(error);
  } catch (...) {
    g_last_error.clear();
  }
  return success ? 0 : 2;
}

int32_t ExceptionResult(const char* message) noexcept {
  try {
    g_last_error = message;
  } catch (...) {
    g_last_error.clear();
  }
  return 3;
}

}  // namespace

extern "C" int32_t pwofficial_dense_tx_open_v1(
    const char* capture_path,
    const char* dense_relative_path,
    const char* run_relative_path,
    pwofficial_dense_tx_v1_t** transaction) {
  try {
    g_last_error.clear();
    if (transaction == nullptr) return Invalid("transaction output is null");
    *transaction = nullptr;
    if (!IsNonEmpty(capture_path) || !IsNonEmpty(dense_relative_path) ||
        !IsNonEmpty(run_relative_path)) {
      return Invalid("transaction paths must be non-empty");
    }
    auto* handle = new (std::nothrow) pwofficial_dense_tx_v1_t;
    if (handle == nullptr) return ExceptionResult("transaction allocation failed");
    std::string error;
    if (!AnchoredTransaction::Open(capture_path, dense_relative_path,
                                   run_relative_path, &handle->transaction,
                                   &error)) {
      delete handle;
      return OperationResult(false, std::move(error));
    }
    *transaction = handle;
    return 0;
  } catch (const std::exception& error) {
    return ExceptionResult(error.what());
  } catch (...) {
    return ExceptionResult("unknown transaction open exception");
  }
}

extern "C" int32_t pwofficial_dense_tx_remove_run_entry_v1(
    pwofficial_dense_tx_v1_t* transaction,
    const char* run_relative_path) {
  try {
    if (transaction == nullptr || !IsNonEmpty(run_relative_path)) {
      return Invalid("invalid run cleanup argument");
    }
    std::string error;
    return OperationResult(
        transaction->transaction.RemoveRunOwnedEntry(run_relative_path, &error),
        std::move(error));
  } catch (const std::exception& error) {
    return ExceptionResult(error.what());
  } catch (...) {
    return ExceptionResult("unknown run cleanup exception");
  }
}

extern "C" int32_t pwofficial_dense_tx_remove_run_directory_v1(
    pwofficial_dense_tx_v1_t* transaction) {
  try {
    if (transaction == nullptr) return Invalid("invalid run cleanup argument");
    std::string error;
    return OperationResult(transaction->transaction.RemoveRunDirectory(&error),
                           std::move(error));
  } catch (const std::exception& error) {
    return ExceptionResult(error.what());
  } catch (...) {
    return ExceptionResult("unknown dense cleanup exception");
  }
}

extern "C" int32_t pwofficial_dense_tx_publish_ply_v1(
    pwofficial_dense_tx_v1_t* transaction,
    const char* run_relative_source,
    const char* dense_relative_destination) {
  try {
    if (transaction == nullptr || !IsNonEmpty(run_relative_source) ||
        !IsNonEmpty(dense_relative_destination)) {
      return Invalid("invalid PLY publication argument");
    }
    std::string error;
    return OperationResult(transaction->transaction.PublishPly(
                               run_relative_source, dense_relative_destination,
                               &error),
                           std::move(error));
  } catch (const std::exception& error) {
    return ExceptionResult(error.what());
  } catch (...) {
    return ExceptionResult("unknown PLY publication exception");
  }
}

extern "C" const char* pwofficial_dense_tx_last_error_v1(void) {
  return g_last_error.c_str();
}

extern "C" void pwofficial_dense_tx_close_v1(
    pwofficial_dense_tx_v1_t* transaction) {
  delete transaction;
}
