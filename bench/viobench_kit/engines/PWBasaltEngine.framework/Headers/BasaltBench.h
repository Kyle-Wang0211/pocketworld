#ifndef BASALT_VIO_BENCH_NATIVE_H
#define BASALT_VIO_BENCH_NATIVE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Stable C boundary for the pinned official Basalt VIO pipeline. Coordinates
 * are Basalt IMU/world coordinates; no ARKit state enters this interface.
 * Camera and IMU timestamps must already share one monotonic nanosecond clock.
 * The bridge passes them through unchanged, so calibration/time mapping must be
 * applied exactly once by the transport before submission.
 */
typedef struct basalt_bench basalt_bench_t;

typedef enum basalt_bench_status {
    BASALT_BENCH_OK = 0,
    BASALT_BENCH_INVALID_ARGUMENT = 1,
    BASALT_BENCH_BACKEND_UNAVAILABLE = 2,
    BASALT_BENCH_IO_ERROR = 3,
    BASALT_BENCH_CONFIG_ERROR = 4,
    BASALT_BENCH_INVALID_STATE = 5,
    BASALT_BENCH_TIMESTAMP_REGRESSION = 6,
    BASALT_BENCH_QUEUE_FULL = 7,
    BASALT_BENCH_INPUT_SEALED = 8,
    BASALT_BENCH_NO_OUTPUT = 9,
    BASALT_BENCH_END_OF_STREAM = 10,
    BASALT_BENCH_INTERNAL_ERROR = 11
} basalt_bench_status_t;

typedef enum basalt_bench_phase {
    BASALT_BENCH_PHASE_RUNNING = 0,
    BASALT_BENCH_PHASE_SEALED = 1,
    BASALT_BENCH_PHASE_DRAINING = 2,
    BASALT_BENCH_PHASE_DRAINED = 3,
    BASALT_BENCH_PHASE_STOPPED = 4,
    BASALT_BENCH_PHASE_FAILED = 5
} basalt_bench_phase_t;

typedef struct basalt_bench_create_options {
    size_t struct_size;
    const char *config_path;
    const char *calibration_path;
    uint32_t pose_queue_capacity;
} basalt_bench_create_options_t;

typedef struct basalt_bench_image_plane {
    const uint8_t *pixels;
    uint32_t width;
    uint32_t height;
    uint32_t bytes_per_row;
} basalt_bench_image_plane_t;

typedef struct basalt_bench_pose {
    int64_t timestamp_ns;
    /* Row-major homogeneous T_w_i (IMU/body to world). */
    double T_w_i[16];
    /* x, y, z, w; redundant with T_w_i and convenient for Swift. */
    double quaternion_xyzw[4];
    double translation_xyz[3];
    double velocity_xyz[3];
    double gyro_bias_xyz[3];
    double accel_bias_xyz[3];
    uint64_t camera_accepted_monotonic_ns;
    uint64_t output_monotonic_ns;
    uint64_t pipeline_latency_ns;
} basalt_bench_pose_t;

typedef struct basalt_bench_counters {
    uint64_t camera_offered;
    uint64_t camera_accepted;
    uint64_t camera_dropped_queue_full;
    uint64_t camera_rejected_timestamp;
    uint64_t camera_rejected_sealed;
    uint64_t camera_bytes_copied;
    uint64_t camera_copy_service_ns_total;
    uint64_t camera_copy_service_ns_max;
    uint64_t imu_offered;
    uint64_t imu_accepted;
    uint64_t imu_dropped_queue_full;
    uint64_t imu_rejected_timestamp;
    uint64_t imu_rejected_sealed;
    uint64_t poses_produced;
    uint64_t poses_polled;
    uint64_t poses_dropped_bridge_queue;
    uint64_t nonfinite_pose_rejected;
    uint64_t pipeline_latency_ns_total;
    uint64_t pipeline_latency_ns_max;
    uint64_t image_eof_sentinels_sent;
    uint64_t imu_eof_sentinels_sent;
    uint64_t pose_eof_sentinels_received;
} basalt_bench_counters_t;

typedef struct basalt_bench_snapshot {
    basalt_bench_phase_t phase;
    int stop_requested;
    int64_t last_camera_timestamp_ns;
    int64_t last_imu_timestamp_ns;
    int64_t last_output_timestamp_ns;
    uint32_t optical_flow_input_queue_size;
    uint32_t optical_flow_input_queue_capacity;
    uint32_t vio_vision_queue_size;
    uint32_t vio_imu_queue_size;
    uint32_t vio_imu_queue_capacity;
    uint32_t bridge_pose_queue_size;
    uint32_t optical_flow_input_queue_peak;
    uint32_t vio_vision_queue_peak;
    uint32_t vio_imu_queue_peak;
    uint32_t bridge_pose_queue_peak;
    uint32_t observed_tbb_active_parallelism;
    basalt_bench_counters_t counters;
} basalt_bench_snapshot_t;

int basalt_bench_backend_available(void);

/* Returns BACKEND_UNAVAILABLE and leaves *out_bench null in a stub build. */
basalt_bench_status_t basalt_bench_create(
    const basalt_bench_create_options_t *options,
    basalt_bench_t **out_bench);

/*
 * Nonblocking input. Planes must match calibration order/resolution. Each
 * uint8 grayscale sample is copied as sample << 8, as in official readers.
 */
basalt_bench_status_t basalt_bench_submit_camera(
    basalt_bench_t *bench,
    int64_t timestamp_ns,
    const basalt_bench_image_plane_t *planes,
    size_t plane_count,
    uint64_t accepted_monotonic_ns);

/*
 * One paired official ImuData sample. The caller must use gyro timestamps and
 * linearly interpolate the two adjacent accelerometer samples to that time,
 * matching Basalt's T265 ingestion path. Independent sensor events must never
 * be submitted out of order.
 */
basalt_bench_status_t basalt_bench_submit_imu(
    basalt_bench_t *bench,
    int64_t timestamp_ns,
    double accel_x,
    double accel_y,
    double accel_z,
    double gyro_x,
    double gyro_y,
    double gyro_z);

basalt_bench_status_t basalt_bench_poll_pose(
    basalt_bench_t *bench,
    basalt_bench_pose_t *out_pose);

/*
 * Shutdown order: seal enqueues exact image/IMU null sentinels; drain calls
 * maybe_join then drain_input_queues and consumes the output null sentinel;
 * stop releases OpticalFlow (joining its worker) then releases VIO.
 */
basalt_bench_status_t basalt_bench_seal_inputs(basalt_bench_t *bench);
basalt_bench_status_t basalt_bench_drain(basalt_bench_t *bench);
basalt_bench_status_t basalt_bench_stop(basalt_bench_t *bench);

basalt_bench_status_t basalt_bench_get_snapshot(
    basalt_bench_t *bench,
    basalt_bench_snapshot_t *out_snapshot);

void basalt_bench_request_stop_for_run(basalt_bench_t *bench);
int basalt_bench_stop_requested(const basalt_bench_t *bench);
void basalt_bench_request_stop(void);

/* Safe on null; a valid run follows seal/drain/stop before deletion. */
void basalt_bench_destroy(basalt_bench_t *bench);
const char *basalt_bench_status_name(basalt_bench_status_t status);

#ifdef __cplusplus
}
#endif

#endif
