#ifndef POCKETWORLD_OFFICIAL_DENSE_ANCHORED_TRANSACTION_C_H_
#define POCKETWORLD_OFFICIAL_DENSE_ANCHORED_TRANSACTION_C_H_

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// A separate, versioned auxiliary ABI for filesystem transactions. The frozen
// six-symbol algorithm ABI in pwofficial_dense_c.h remains unchanged.
typedef struct pwofficial_dense_tx_v1 pwofficial_dense_tx_v1_t;

int32_t pwofficial_dense_tx_open_v1(
    const char* capture_path,
    const char* dense_relative_path,
    const char* run_relative_path,
    pwofficial_dense_tx_v1_t** transaction);

int32_t pwofficial_dense_tx_remove_run_entry_v1(
    pwofficial_dense_tx_v1_t* transaction,
    const char* run_relative_path);

int32_t pwofficial_dense_tx_remove_run_directory_v1(
    pwofficial_dense_tx_v1_t* transaction);

int32_t pwofficial_dense_tx_publish_ply_v1(
    pwofficial_dense_tx_v1_t* transaction,
    const char* run_relative_source,
    const char* dense_relative_destination);

const char* pwofficial_dense_tx_last_error_v1(void);

void pwofficial_dense_tx_close_v1(pwofficial_dense_tx_v1_t* transaction);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // POCKETWORLD_OFFICIAL_DENSE_ANCHORED_TRANSACTION_C_H_
