// pwofficial_gpu_match_dawn_abi_test.cc — exercises the Dawn matcher TU's
// ABI surface that the parity suite / full gate do NOT reach, so no path
// ships untested (silent-exit discipline):
//   1. argument validation → rc 1 on every entry;
//   2. probe_batch: K candidates of assorted sizes (incl. sub-128 and
//      >8192-row-count edge cases) must report EXACTLY the per-pair mutual
//      counts of gemm_pairs, across one or several submissions (cost-model
//      grouping is forced through the chunk-target env by the caller);
//   3. descriptor residency V1 (env OFFICIAL_AETHER_DESCRIPTOR_RESIDENCY_V1=1
//      set by the caller): resident vs upload-per-call pairs byte-identical,
//      stats report hits after the second call, invalidate/clear_session
//      drop entries, and a generation bump replaces the stale table;
//   4. guided validation (mode 0 / 3, missing points, residual <= 0 → rc 1).
// usage: <fixture_dir (8192-ish H2 fixture)>
// Exit 0 = all checks passed; prints ABI_TEST lines.

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "fair_match_common.h"

extern "C" {
int pwdawn_gpu_match_gemm_pairs(const uint8_t*, int, const uint8_t*, int, double,
                                uint32_t*, int, int*);
int pwdawn_gpu_match_gemm_pairs_resident(uint64_t, uint32_t, uint32_t,
                                         const uint8_t*, int, uint32_t, uint32_t,
                                         const uint8_t*, int, double, uint32_t*,
                                         int, int*);
void pwdawn_gpu_match_descriptor_residency_invalidate(uint64_t, uint32_t);
void pwdawn_gpu_match_descriptor_residency_clear_session(uint64_t);
int pwdawn_gpu_match_descriptor_residency_stats(uint64_t, uint64_t*, uint64_t*,
                                                uint64_t*, uint64_t*, uint64_t*,
                                                uint64_t*, uint64_t*, uint64_t*,
                                                uint64_t*);
int pwdawn_gpu_match_probe_batch(const uint8_t*, int, const uint8_t* const*,
                                 const int*, int, double, int*);
int pwdawn_gpu_match_gemm_pairs_guided(const uint8_t*, int, const float*,
                                       const uint8_t*, int, const float*, double,
                                       const float*, const float*, int, float,
                                       uint32_t*, int, int*);
int pwdawn_gpu_match_last_error(char*, int);
int pwdawn_gpu_match_backend_info(char*, int);
}

static int g_fail = 0;
#define CHECK(cond, ...)                                              \
  do {                                                                \
    if (cond) {                                                       \
      std::printf("ABI_TEST PASS " __VA_ARGS__);                      \
      std::printf("\n");                                              \
    } else {                                                          \
      std::printf("ABI_TEST FAIL " __VA_ARGS__);                      \
      std::printf("\n");                                              \
      ++g_fail;                                                       \
    }                                                                 \
  } while (0)

static std::string Digest(const std::vector<uint32_t>& p, int n) {
  return fairmatch::Sha256Hex(p.data(), (size_t)n * 8);
}

int main(int argc, char** argv) {
  if (argc != 2) {
    std::fprintf(stderr, "usage: %s <fixture_dir>\n", argv[0]);
    return 1;
  }
  const fairmatch::Fixture f = fairmatch::LoadFixture(argv[1]);
  char info[512] = {0};
  pwdawn_gpu_match_backend_info(info, sizeof(info));
  std::printf("ABI_TEST backend %s\n", info);
  const double ratio = 0.8;

  // ── 1. argument validation ──
  {
    int n = -1;
    uint32_t dummy[2];
    CHECK(pwdawn_gpu_match_gemm_pairs(nullptr, 1, f.b.data(), 1, ratio, dummy, 1, &n) == 1 && n == 0,
          "gemm_pairs null desc → rc1");
    CHECK(pwdawn_gpu_match_gemm_pairs(f.a.data(), 0, f.b.data(), 1, ratio, dummy, 1, &n) == 1,
          "gemm_pairs nA=0 → rc1");
    CHECK(pwdawn_gpu_match_gemm_pairs(f.a.data(), 1, f.b.data(), 1, ratio, dummy, 0, &n) == 1,
          "gemm_pairs max_pairs=0 with out → rc1");
    int counts[1];
    const uint8_t* dbs[1] = {f.b.data()};
    int nbs[1] = {0};
    CHECK(pwdawn_gpu_match_probe_batch(f.a.data(), 512, dbs, nbs, 1, ratio, counts) == 1,
          "probe_batch nB=0 → rc1");
    CHECK(pwdawn_gpu_match_probe_batch(f.a.data(), 512, dbs, nbs, 0, ratio, counts) == 1,
          "probe_batch n_cands=0 → rc1");
    std::vector<float> xy((size_t)f.na * 2, 0.0f), xyb((size_t)f.nb * 2, 0.0f);
    float M[9] = {1, 0, 0, 0, 1, 0, 0, 0, 1};
    CHECK(pwdawn_gpu_match_gemm_pairs_guided(f.a.data(), (int)f.na, xy.data(), f.b.data(), (int)f.nb,
                                             xyb.data(), ratio, M, M, 0, 1.0f, dummy, 1, &n) == 1,
          "guided mode 0 → rc1");
    CHECK(pwdawn_gpu_match_gemm_pairs_guided(f.a.data(), (int)f.na, xy.data(), f.b.data(), (int)f.nb,
                                             xyb.data(), ratio, M, M, 3, 1.0f, dummy, 1, &n) == 1,
          "guided mode 3 → rc1");
    CHECK(pwdawn_gpu_match_gemm_pairs_guided(f.a.data(), (int)f.na, nullptr, f.b.data(), (int)f.nb,
                                             xyb.data(), ratio, M, M, 1, 1.0f, dummy, 1, &n) == 1,
          "guided null xy → rc1");
    CHECK(pwdawn_gpu_match_gemm_pairs_guided(f.a.data(), (int)f.na, xy.data(), f.b.data(), (int)f.nb,
                                             xyb.data(), ratio, M, M, 1, 0.0f, dummy, 1, &n) == 1,
          "guided residual 0 → rc1");
  }

  // ── 2. probe batch vs per-pair counts ──
  {
    const int nA = 512;  // production probe subset size
    std::vector<int> sizes = {(int)f.nb, 4000, 1000, 513, 512, 129, 128, 127, 64, 7, 1, 2500};
    std::vector<const uint8_t*> dbs;
    std::vector<int> nbs;
    for (int s : sizes) {
      if (s > (int)f.nb) s = (int)f.nb;
      dbs.push_back(f.b.data());
      nbs.push_back(s);
    }
    std::vector<int> expect(sizes.size(), -1);
    for (size_t k = 0; k < sizes.size(); ++k) {
      int n = 0;
      const int rc = pwdawn_gpu_match_gemm_pairs(f.a.data(), nA, dbs[k], nbs[k], ratio, nullptr, 0, &n);
      if (rc != 0) {
        char e[256] = {0};
        pwdawn_gpu_match_last_error(e, sizeof(e));
        std::printf("ABI_TEST FAIL per-pair rc=%d (%s)\n", rc, e);
        return 2;
      }
      expect[k] = n;
    }
    std::vector<int> counts(sizes.size(), -1);
    const int rc = pwdawn_gpu_match_probe_batch(f.a.data(), nA, dbs.data(), nbs.data(), (int)sizes.size(),
                                                ratio, counts.data());
    char e[256] = {0};
    pwdawn_gpu_match_last_error(e, sizeof(e));
    CHECK(rc == 0, "probe_batch rc=%d %s", rc, e);
    bool all = rc == 0;
    for (size_t k = 0; k < sizes.size(); ++k) {
      if (counts[k] != expect[k]) {
        all = false;
        std::printf("ABI_TEST   cand %zu nB=%d batch=%d per-pair=%d\n", k, nbs[k], counts[k], expect[k]);
      }
    }
    CHECK(all, "probe_batch counts == per-pair counts for %zu candidates (sum=%d)", sizes.size(),
          [&] { int s = 0; for (int c : expect) s += c; return s; }());
  }

  // ── 3. descriptor residency ──
  {
    const bool enabled = [] {
      const char* v = std::getenv("OFFICIAL_AETHER_DESCRIPTOR_RESIDENCY_V1");
      return v && v[0] == '1' && v[1] == '\0';
    }();
    const int cap = (int)std::min(f.na, f.nb);
    std::vector<uint32_t> p0((size_t)cap * 2), p1((size_t)cap * 2), p2((size_t)cap * 2);
    int n0 = 0, n1 = 0, n2 = 0;
    CHECK(pwdawn_gpu_match_gemm_pairs(f.a.data(), (int)f.na, f.b.data(), (int)f.nb, ratio, p0.data(), cap, &n0) == 0,
          "plain gemm_pairs rc0 (n=%d)", n0);
    const uint64_t nonce = 0x5eed1234u;
    CHECK(pwdawn_gpu_match_gemm_pairs_resident(nonce, 7, 1, f.a.data(), (int)f.na, 9, 1, f.b.data(), (int)f.nb,
                                               ratio, p1.data(), cap, &n1) == 0,
          "resident #1 rc0 (n=%d)", n1);
    CHECK(pwdawn_gpu_match_gemm_pairs_resident(nonce, 7, 1, f.a.data(), (int)f.na, 9, 1, f.b.data(), (int)f.nb,
                                               ratio, p2.data(), cap, &n2) == 0,
          "resident #2 rc0 (n=%d)", n2);
    CHECK(n0 == n1 && n1 == n2 && Digest(p0, n0) == Digest(p1, n1) && Digest(p1, n1) == Digest(p2, n2),
          "plain == resident#1 == resident#2 (sha %s)", Digest(p0, n0).substr(0, 12).c_str());
    uint64_t hits = 0, misses = 0, ev = 0, stale = 0, up = 0, resb = 0, ents = 0, af = 0, dr = 0;
    const int have = pwdawn_gpu_match_descriptor_residency_stats(nonce, &hits, &misses, &ev, &stale, &up,
                                                                &resb, &ents, &af, &dr);
    std::printf("ABI_TEST residency enabled=%d have=%d hits=%llu misses=%llu ev=%llu stale=%llu "
                "upload=%llu resident=%llu entries=%llu allocfail=%llu resets=%llu\n",
                (int)enabled, have, (unsigned long long)hits, (unsigned long long)misses,
                (unsigned long long)ev, (unsigned long long)stale, (unsigned long long)up,
                (unsigned long long)resb, (unsigned long long)ents, (unsigned long long)af,
                (unsigned long long)dr);
    if (enabled) {
      CHECK(have == 1 && hits == 2 && misses == 2 && ents == 2 && resb > 0, "residency stats after two calls: hits=2 misses=2 entries=2");
      // generation bump replaces the stale table (frame 9 gen 2), same result
      CHECK(pwdawn_gpu_match_gemm_pairs_resident(nonce, 7, 1, f.a.data(), (int)f.na, 9, 2, f.b.data(), (int)f.nb,
                                                 ratio, p2.data(), cap, &n2) == 0 && n2 == n0 && Digest(p2, n2) == Digest(p0, n0),
            "generation bump → same pairs");
      pwdawn_gpu_match_descriptor_residency_stats(nonce, &hits, &misses, &ev, &stale, &up, &resb, &ents, &af, &dr);
      CHECK(stale == 1 && ents == 2, "stale replacement counted (stale=%llu entries=%llu)", (unsigned long long)stale, (unsigned long long)ents);
      pwdawn_gpu_match_descriptor_residency_invalidate(nonce, 7);
      pwdawn_gpu_match_descriptor_residency_stats(nonce, &hits, &misses, &ev, &stale, &up, &resb, &ents, &af, &dr);
      CHECK(ents == 1, "invalidate frame 7 → entries=1 (%llu)", (unsigned long long)ents);
      CHECK(pwdawn_gpu_match_gemm_pairs_resident(nonce, 7, 1, f.a.data(), (int)f.na, 9, 2, f.b.data(), (int)f.nb,
                                                 ratio, p2.data(), cap, &n2) == 0 && Digest(p2, n2) == Digest(p0, n0),
            "re-upload after invalidate → same pairs");
      pwdawn_gpu_match_descriptor_residency_clear_session(nonce);
      CHECK(pwdawn_gpu_match_descriptor_residency_stats(nonce, &hits, &misses, &ev, &stale, &up, &resb, &ents, &af, &dr) == 0,
            "clear_session → session gone");
    } else {
      CHECK(have == 0, "residency disabled → no session recorded");
    }
  }

  // ── 4. guided smoke on identity geometry (mode 2, huge residual) ==
  //     plain vs guided differ only by the distance domain, so the guided
  //     count must be > 0 and every guided pair must be a top-1 mutual match
  //     under the L2 gate — here we just assert rc 0 and non-empty.
  {
    std::vector<float> xa((size_t)f.na * 2, 0.0f), xb((size_t)f.nb * 2, 0.0f);
    float M[9] = {1, 0, 0, 0, 1, 0, 0, 0, 1};
    const int cap = (int)std::min(f.na, f.nb);
    std::vector<uint32_t> p((size_t)cap * 2);
    int n = 0;
    const int rc = pwdawn_gpu_match_gemm_pairs_guided(f.a.data(), (int)f.na, xa.data(), f.b.data(), (int)f.nb,
                                                      xb.data(), ratio, M, M, 2, 1e6f, p.data(), cap, &n);
    CHECK(rc == 0 && n > 0, "guided mode2 identity/open gate rc=%d n=%d", rc, n);
  }

  std::printf("ABI_TEST %s (%d failures)\n", g_fail ? "FAIL" : "PASS", g_fail);
  return g_fail ? 3 : 0;
}
