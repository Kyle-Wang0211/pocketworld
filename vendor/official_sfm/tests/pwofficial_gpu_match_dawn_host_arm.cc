// pwofficial_gpu_match_dawn_host_arm.cc — host test arm that drives the
// PRODUCTION Dawn matcher TU (pwofficial_gpu_match_dawn.cc, compiled with
// -DPWOFFICIAL_DAWN_HOST_TEST=1) through its C ABI on an H2 fixture, with the
// same argv / output contract as the harness's fair_match_portable_arm so the
// frozen parity suite (fair_match_parity_suite.sh, 19 triple goldens) and the
// 696-pair full gate (run_fullgate.sh) can be pointed at it unchanged.
//
// usage: <fixture_dir> <out_dir> <reps> <warmup> <ratio> <label>
//   label is free text (e.g. dawntu); env selects the backend variant:
//   OFFICIAL_AETHER_MATCH_DAWN_KERNEL=tiled forces the V1/V2 fallback,
//   OFFICIAL_AETHER_MATCH_CHUNK_TARGET_MS=0 forces the monolithic submit.
// Output: <out_dir>/portable_<label>_pairs.bin + one PORTABLE_RESULT JSON line
// with pairs / OutAB / OutBA SHA-256 digests (triple golden) and timing.

#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "fair_match_common.h"

static double fairmatch_now_ms() {
  using namespace std::chrono;
  return duration<double, std::milli>(steady_clock::now().time_since_epoch())
      .count();
}

extern "C" int pwdawn_gpu_match_gemm_pairs(const uint8_t* dA, int nA,
                                           const uint8_t* dB, int nB,
                                           double max_ratio,
                                           uint32_t* out_pairs, int max_pairs,
                                           int* out_num_matches);
extern "C" int pwdawn_gpu_match_last_error(char* buf, int cap);
extern "C" int pwdawn_gpu_match_backend_info(char* buf, int cap);
extern "C" void pwdawn_gpu_match_debug_last_dirmaps(const int32_t** ab, int* na,
                                                    const int32_t** ba, int* nb);
extern "C" void pwdawn_gpu_match_debug_last_timing(double* upload_ms,
                                                   double* submit_ms,
                                                   double* readback_ms);
// Observation globals defined by the TU in the host build (KNIFE-C chunk
// count / GPU ms / duty-cycle sleep, accumulated across calls).
extern "C" int aether_match_chunks;
extern "C" double aether_match_gpu_ms;
extern "C" double aether_match_sleep_ms;

int main(int argc, char** argv) {
  if (argc != 7) {
    std::fprintf(stderr,
                 "usage: %s <fixture_dir> <out_dir> <reps> <warmup> <ratio> "
                 "<label>\n",
                 argv[0]);
    return 1;
  }
  const std::string fixture_dir = argv[1];
  const std::string out_dir = argv[2];
  const int reps = std::atoi(argv[3]);
  const int warmup = std::atoi(argv[4]);
  const double ratio = std::atof(argv[5]);
  const std::string label = argv[6];

  const fairmatch::Fixture f = fairmatch::LoadFixture(fixture_dir);
  if (f.na == 0 || f.nb == 0) {
    // Production contract: empty sides never reach the matcher (rc=1).
    fairmatch::WriteFileBytes(out_dir + "/portable_" + label + "_pairs.bin", "",
                              0);
    std::printf(
        "PORTABLE_RESULT {\"arm\":\"portable_wgsl_%s\",\"count\":0,"
        "\"pairs_sha256\":\"%s\",\"empty_input_early_return\":true}\n",
        label.c_str(), fairmatch::Sha256Hex("", 0).c_str());
    return 0;
  }

  char info[512] = {0};
  pwdawn_gpu_match_backend_info(info, sizeof(info));
  std::printf("PORTABLE_ARM tu=pwofficial_gpu_match_dawn label=%s na=%u nb=%u "
              "ratio=%.3f %s\n",
              label.c_str(), f.na, f.nb, ratio, info);

  const int cap = (int)(f.na < f.nb ? f.na : f.nb);
  std::vector<uint32_t> pairs((size_t)cap * 2);
  std::vector<uint32_t> final_pairs;
  std::vector<double> wall, submit_v, upload_v, readback_v;
  std::string digest, dir_ab, dir_ba;
  int count = -1;
  for (int r = 0; r < warmup + reps; ++r) {
    const bool record = r >= warmup;
    const double t0 = fairmatch_now_ms();
    const int chunks_before = aether_match_chunks;
    int n = 0;
    const int rc = pwdawn_gpu_match_gemm_pairs(f.a.data(), (int)f.na, f.b.data(),
                                               (int)f.nb, ratio, pairs.data(),
                                               cap, &n);
    const double t1 = fairmatch_now_ms();
    if (rc != 0) {
      char err[256] = {0};
      pwdawn_gpu_match_last_error(err, sizeof(err));
      std::fprintf(stderr, "FAIL pwdawn_gpu_match_gemm_pairs rc=%d: %s\n", rc,
                   err);
      return 20 + rc;
    }
    const int32_t* ab = nullptr;
    const int32_t* ba = nullptr;
    int na = 0, nb = 0;
    pwdawn_gpu_match_debug_last_dirmaps(&ab, &na, &ba, &nb);
    if (na != (int)f.na || nb != (int)f.nb) {
      std::fprintf(stderr, "FAIL direction map sizes %d/%d vs %u/%u\n", na, nb,
                   f.na, f.nb);
      return 35;
    }
    // Self-consistency: the TU's emitted pairs must equal the shared host
    // reference cross-check over its own direction maps.
    const std::vector<uint32_t> ref =
        fairmatch::MutualPairs(ab, f.na, ba, f.nb);
    if ((int)(ref.size() / 2) != n ||
        std::memcmp(ref.data(), pairs.data(), ref.size() * 4) != 0) {
      std::fprintf(stderr, "FAIL TU pairs != host MutualPairs(dirmaps)\n");
      return 36;
    }
    const std::string d_ab = fairmatch::Sha256Hex(ab, (size_t)na * 4);
    const std::string d_ba = fairmatch::Sha256Hex(ba, (size_t)nb * 4);
    const std::string d = fairmatch::Sha256Hex(pairs.data(), (size_t)n * 8);
    double up = 0, sub = 0, rb = 0;
    pwdawn_gpu_match_debug_last_timing(&up, &sub, &rb);
    if (record) {
      if (count < 0) {
        count = n;
        digest = d;
        dir_ab = d_ab;
        dir_ba = d_ba;
        final_pairs.assign(pairs.begin(), pairs.begin() + (size_t)n * 2);
      } else if (n != count || d != digest || d_ab != dir_ab || d_ba != dir_ba) {
        std::fprintf(stderr, "FAIL output not deterministic across reps\n");
        return 32;
      }
      wall.push_back(t1 - t0);
      upload_v.push_back(up);
      submit_v.push_back(sub);
      readback_v.push_back(rb);
      std::printf("  rep complete_ms=%.3f upload=%.3f submit=%.3f readback=%.3f "
                  "chunks=%d count=%d\n",
                  t1 - t0, up, sub, rb, aether_match_chunks - chunks_before, n);
    }
  }
  fairmatch::WriteFileBytes(out_dir + "/portable_" + label + "_pairs.bin",
                            final_pairs.data(), final_pairs.size() * 4);
  std::printf(
      "PORTABLE_RESULT {\"arm\":\"portable_wgsl_%s\",\"count\":%d,"
      "\"pairs_sha256\":\"%s\",\"wall_ms\":[%s],\"p50_ms\":%.3f,"
      "\"p95_ms\":%.3f,\"gpu_p50_ms\":%.3f,\"upload_p50_ms\":%.3f,"
      "\"readback_p50_ms\":%.3f,\"outab_sha256\":\"%s\",\"outba_sha256\":\"%s\"}\n",
      label.c_str(), count, digest.c_str(), fairmatch::JoinMs(wall).c_str(),
      fairmatch::Percentile(wall, 0.5), fairmatch::Percentile(wall, 0.95),
      fairmatch::Percentile(submit_v, 0.5), fairmatch::Percentile(upload_v, 0.5),
      fairmatch::Percentile(readback_v, 0.5), dir_ab.c_str(), dir_ba.c_str());
  return 0;
}
