// fair_match_common.h — shared host code for the H2 fair native-vs-portable
// matcher harness (2026-08-01). Both arms include this header so fixture
// loading, mutual cross-check, ordered pair emission, digesting, and stats are
// byte-identical host semantics by construction.
//
// Contract: openspec/changes/portable-sfm-speedup-v1/evidence/
//           host-first-open-source-speed-screen-2026-08-01.md §7
#pragma once

#include <CommonCrypto/CommonDigest.h>

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>

namespace fairmatch {

inline std::string Sha256Hex(const void* data, size_t n) {
  unsigned char d[CC_SHA256_DIGEST_LENGTH];
  CC_SHA256(data, (CC_LONG)n, d);
  char hex[2 * CC_SHA256_DIGEST_LENGTH + 1];
  for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; ++i)
    std::snprintf(hex + 2 * i, 3, "%02x", d[i]);
  return std::string(hex, 2 * CC_SHA256_DIGEST_LENGTH);
}

inline std::vector<uint8_t> ReadFileBytes(const std::string& path) {
  std::ifstream in(path, std::ios::binary);
  if (!in) {
    std::fprintf(stderr, "FAIL cannot read %s\n", path.c_str());
    std::exit(10);
  }
  return std::vector<uint8_t>((std::istreambuf_iterator<char>(in)),
                              std::istreambuf_iterator<char>());
}

inline void WriteFileBytes(const std::string& path, const void* data,
                           size_t n) {
  std::ofstream out(path, std::ios::binary);
  out.write(reinterpret_cast<const char*>(data), (std::streamsize)n);
  if (!out) {
    std::fprintf(stderr, "FAIL cannot write %s\n", path.c_str());
    std::exit(11);
  }
}

// Minimal manifest field extraction: `"key": <uint>` or `"key": "<hex>"`.
inline uint64_t ManifestUInt(const std::string& text, const char* key) {
  const std::string needle = std::string("\"") + key + "\":";
  const size_t at = text.find(needle);
  if (at == std::string::npos) {
    std::fprintf(stderr, "FAIL manifest missing %s\n", key);
    std::exit(12);
  }
  return std::strtoull(text.c_str() + at + needle.size(), nullptr, 10);
}

inline std::string ManifestStr(const std::string& text, const char* key) {
  const std::string needle = std::string("\"") + key + "\": \"";
  const size_t at = text.find(needle);
  if (at == std::string::npos) {
    std::fprintf(stderr, "FAIL manifest missing %s\n", key);
    std::exit(13);
  }
  const size_t start = at + needle.size();
  const size_t end = text.find('"', start);
  return text.substr(start, end - start);
}

struct Fixture {
  std::vector<uint8_t> a, b;  // raw uint8 rows x 128
  uint32_t na = 0, nb = 0;
  std::string sha_a, sha_b;
};

// Loads a.u8/b.u8 + manifest.json from dir and verifies the recorded hashes,
// so both arms provably consume identical bytes.
inline Fixture LoadFixture(const std::string& dir) {
  Fixture f;
  std::vector<uint8_t> mf = ReadFileBytes(dir + "/manifest.json");
  const std::string m(mf.begin(), mf.end());
  f.na = (uint32_t)ManifestUInt(m, "rows_a");
  f.nb = (uint32_t)ManifestUInt(m, "rows_b");
  f.a = ReadFileBytes(dir + "/a.u8");
  f.b = ReadFileBytes(dir + "/b.u8");
  if (f.a.size() != (size_t)f.na * 128 || f.b.size() != (size_t)f.nb * 128) {
    std::fprintf(stderr, "FAIL fixture size mismatch\n");
    std::exit(14);
  }
  f.sha_a = Sha256Hex(f.a.data(), f.a.size());
  f.sha_b = Sha256Hex(f.b.data(), f.b.size());
  if (f.sha_a != ManifestStr(m, "sha256_a") ||
      f.sha_b != ManifestStr(m, "sha256_b")) {
    std::fprintf(stderr, "FAIL fixture hash mismatch vs manifest\n");
    std::exit(15);
  }
  return f;
}

// Production mutual cross-check + deterministic ordered emission — verbatim
// semantics of official_gpu_match.mm matchPairsImpl lines 670-685: ascending i
// over A, j = mAB[i], keep iff j in range and mBA[j] == i.
inline std::vector<uint32_t> MutualPairs(const int32_t* mAB, uint32_t nA,
                                         const int32_t* mBA, uint32_t nB) {
  std::vector<uint32_t> pairs;
  pairs.reserve(1024);
  for (uint32_t i = 0; i < nA; ++i) {
    const int32_t j = mAB[i];
    if (j >= 0 && (uint32_t)j < nB && mBA[j] == (int32_t)i) {
      pairs.push_back(i);
      pairs.push_back((uint32_t)j);
    }
  }
  return pairs;
}

inline double Percentile(std::vector<double> v, double q) {
  if (v.empty()) return 0.0;
  std::sort(v.begin(), v.end());
  const double idx = q * (double)(v.size() - 1);
  const size_t lo = (size_t)idx;
  const size_t hi = lo + 1 < v.size() ? lo + 1 : lo;
  const double w = idx - (double)lo;
  return v[lo] * (1.0 - w) + v[hi] * w;
}

inline std::string JoinMs(const std::vector<double>& v) {
  std::string s;
  char buf[32];
  for (size_t i = 0; i < v.size(); ++i) {
    std::snprintf(buf, sizeof(buf), "%s%.3f", i ? "," : "", v[i]);
    s += buf;
  }
  return s;
}

}  // namespace fairmatch
