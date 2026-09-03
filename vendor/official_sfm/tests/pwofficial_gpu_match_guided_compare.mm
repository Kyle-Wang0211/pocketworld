// pwofficial_gpu_match_guided_compare.mm — guided matcher comparator: the
// shipped Metal TU (aether_gpu_match_gemm_pairs_guided, default v1 two-pass
// path) vs the production Dawn TU (pwdawn_gpu_match_gemm_pairs_guided) on
// one guided fixture (see pwofficial_gpu_match_guided_fixtures.py).
//
// Reports the two ordered pair lists' digests, the symmetric difference, and
// for every A row where the two disagree, the boundary evidence: the exact
// (double precision) residual ratio r = residual/maxResidual of every
// candidate involved (both directions), so a divergence can be classified as
// boundary-confined (min |r − 1| tiny) or structural. Expected outcome per
// the Metal TU header: divergences only within ~1e-3 relative of the
// threshold, ±1 match/pair scale.
//
// usage: <fixture_dir> <out_dir>
// Env: OFFICIAL_AETHER_MATCH_V2 / _V2_GUIDED_FUSED default (guided → Metal v1).

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <set>
#include <string>
#include <utility>
#include <vector>

#include "fair_match_common.h"

extern "C" int aether_gpu_match_gemm_pairs_guided(
    const uint8_t* dA, int nA, const float* xyA, const uint8_t* dB, int nB,
    const float* xyB, double max_ratio, const float* matrixAB,
    const float* matrixBA, int guide_mode, float max_residual,
    uint32_t* out_pairs, int max_pairs, int* out_num_matches);
extern "C" int pwdawn_gpu_match_gemm_pairs_guided(
    const uint8_t* dA, int nA, const float* xyA, const uint8_t* dB, int nB,
    const float* xyB, double max_ratio, const float* matrixAB,
    const float* matrixBA, int guide_mode, float max_residual,
    uint32_t* out_pairs, int max_pairs, int* out_num_matches);
extern "C" int pwdawn_gpu_match_last_error(char* buf, int cap);
extern "C" int aether_gpu_match_last_error(char* buf, int cap);
extern "C" void pwdawn_gpu_match_debug_last_dirmaps(const int32_t** ab, int* na,
                                                    const int32_t** ba, int* nb);

namespace {

std::vector<float> ReadF32(const std::string& p) {
  std::vector<uint8_t> b = fairmatch::ReadFileBytes(p);
  std::vector<float> v(b.size() / 4);
  std::memcpy(v.data(), b.data(), v.size() * 4);
  return v;
}

double JsonNumber(const std::string& text, const char* key, double dflt) {
  const std::string needle = std::string("\"") + key + "\":";
  size_t at = text.find(needle);
  if (at == std::string::npos) return dflt;
  at += needle.size();
  while (at < text.size() && text[at] == ' ') ++at;
  return std::strtod(text.c_str() + at, nullptr);
}

// Exact-arithmetic residual ratio of candidate (q, d) under matrix M for the
// given mode (q = query point, d = database point, M = query→database).
double ResidualRatio(int mode, const double* M, double qx, double qy,
                     double dx, double dy, double maxResidual) {
  if (mode == 1) {
    const double p1[3] = {qx, qy, 1.0}, p2[3] = {dx, dy, 1.0};
    const double line2[3] = {M[0] * p1[0] + M[1] * p1[1] + M[2],
                             M[3] * p1[0] + M[4] * p1[1] + M[5],
                             M[6] * p1[0] + M[7] * p1[1] + M[8]};
    const double line1[3] = {M[0] * p2[0] + M[3] * p2[1] + M[6],
                             M[1] * p2[0] + M[4] * p2[1] + M[7],
                             M[2] * p2[0] + M[5] * p2[1] + M[8]};
    const double nom = p2[0] * line2[0] + p2[1] * line2[1] + p2[2] * line2[2];
    const double denom = line2[0] * line2[0] + line2[1] * line2[1] +
                         line1[0] * line1[0] + line1[1] * line1[1];
    if (denom <= 1e-12) return INFINITY;
    return (nom * nom / denom) / maxResidual;
  }
  const double hx = M[0] * qx + M[1] * qy + M[2];
  const double hy = M[3] * qx + M[4] * qy + M[5];
  const double hz = M[6] * qx + M[7] * qy + M[8];
  if (std::fabs(hz) <= 1e-8) return INFINITY;
  const double ex = hx / hz - dx, ey = hy / hz - dy;
  return (ex * ex + ey * ey) / maxResidual;
}

}  // namespace

int main(int argc, char** argv) {
  if (argc != 3) {
    std::fprintf(stderr, "usage: %s <fixture_dir> <out_dir>\n", argv[0]);
    return 1;
  }
  const std::string dir = argv[1], out = argv[2];
  const fairmatch::Fixture f = fairmatch::LoadFixture(dir);
  const std::vector<float> xyA = ReadF32(dir + "/xy_a.f32");
  const std::vector<float> xyB = ReadF32(dir + "/xy_b.f32");
  const std::vector<float> mAB = ReadF32(dir + "/mat_ab.f32");
  const std::vector<float> mBA = ReadF32(dir + "/mat_ba.f32");
  if (xyA.size() != (size_t)f.na * 2 || xyB.size() != (size_t)f.nb * 2 ||
      mAB.size() != 9 || mBA.size() != 9) {
    std::fprintf(stderr, "FAIL guided fixture shape\n");
    return 2;
  }
  std::vector<uint8_t> gj = fairmatch::ReadFileBytes(dir + "/guided.json");
  const std::string gtext(gj.begin(), gj.end());
  const int mode = (int)JsonNumber(gtext, "mode", 0);
  const float maxResidual = (float)JsonNumber(gtext, "max_residual", 0.0);
  const double ratio = JsonNumber(gtext, "ratio", 0.8);
  if (mode < 1 || mode > 2 || maxResidual <= 0.0f) {
    std::fprintf(stderr, "FAIL guided.json mode/max_residual\n");
    return 2;
  }
  const int cap = (int)std::min(f.na, f.nb);
  std::vector<uint32_t> pm((size_t)cap * 2), pd((size_t)cap * 2);
  int nm = 0, nd = 0;
  int rc = aether_gpu_match_gemm_pairs_guided(
      f.a.data(), (int)f.na, xyA.data(), f.b.data(), (int)f.nb, xyB.data(),
      ratio, mAB.data(), mBA.data(), mode, maxResidual, pm.data(), cap, &nm);
  if (rc != 0) {
    char e[256] = {0};
    aether_gpu_match_last_error(e, sizeof(e));
    std::fprintf(stderr, "FAIL metal guided rc=%d %s\n", rc, e);
    return 10 + rc;
  }
  rc = pwdawn_gpu_match_gemm_pairs_guided(
      f.a.data(), (int)f.na, xyA.data(), f.b.data(), (int)f.nb, xyB.data(),
      ratio, mAB.data(), mBA.data(), mode, maxResidual, pd.data(), cap, &nd);
  if (rc != 0) {
    char e[256] = {0};
    pwdawn_gpu_match_last_error(e, sizeof(e));
    std::fprintf(stderr, "FAIL dawn guided rc=%d %s\n", rc, e);
    return 20 + rc;
  }
  pm.resize((size_t)nm * 2);
  pd.resize((size_t)nd * 2);
  fairmatch::WriteFileBytes(out + "/metal_pairs.bin", pm.data(), pm.size() * 4);
  fairmatch::WriteFileBytes(out + "/dawn_pairs.bin", pd.data(), pd.size() * 4);
  const std::string sm = fairmatch::Sha256Hex(pm.data(), pm.size() * 4);
  const std::string sd = fairmatch::Sha256Hex(pd.data(), pd.size() * 4);

  std::set<std::pair<uint32_t, uint32_t>> SM, SD;
  for (int i = 0; i < nm; ++i) SM.insert({pm[2 * i], pm[2 * i + 1]});
  for (int i = 0; i < nd; ++i) SD.insert({pd[2 * i], pd[2 * i + 1]});
  std::vector<std::pair<uint32_t, uint32_t>> onlyM, onlyD;
  for (const auto& p : SM) if (!SD.count(p)) onlyM.push_back(p);
  for (const auto& p : SD) if (!SM.count(p)) onlyD.push_back(p);
  const size_t inter = SM.size() - onlyM.size();
  const double jaccard = (SM.size() + SD.size() - inter) > 0
                             ? (double)inter / (double)(SM.size() + SD.size() - inter)
                             : 1.0;

  // Boundary evidence: for every pair in the symmetric difference, the exact
  // residual ratio of that candidate in both directions.
  double MABd[9], MBAd[9];
  for (int i = 0; i < 9; ++i) { MABd[i] = mAB[i]; MBAd[i] = mBA[i]; }
  double min_dist = INFINITY, max_dist = 0.0;
  int n_boundary_1e3 = 0, n_boundary_1e2 = 0, n_diff = 0;
  std::string diff_json;
  auto note = [&](const char* side, uint32_t i, uint32_t j) {
    const double rAB = ResidualRatio(mode, MABd, xyA[2 * i], xyA[2 * i + 1],
                                     xyB[2 * j], xyB[2 * j + 1], maxResidual);
    const double rBA = ResidualRatio(mode, MBAd, xyB[2 * j], xyB[2 * j + 1],
                                     xyA[2 * i], xyA[2 * i + 1], maxResidual);
    const double dist = std::min(std::fabs(rAB - 1.0), std::fabs(rBA - 1.0));
    min_dist = std::min(min_dist, dist);
    max_dist = std::max(max_dist, dist);
    if (dist < 1e-3) ++n_boundary_1e3;
    if (dist < 1e-2) ++n_boundary_1e2;
    ++n_diff;
    if (diff_json.size() < 4000) {
      char b[200];
      std::snprintf(b, sizeof(b), "%s{\"only\":\"%s\",\"i\":%u,\"j\":%u,\"rAB\":%.6g,\"rBA\":%.6g}",
                    diff_json.empty() ? "" : ",", side, i, j, rAB, rBA);
      diff_json += b;
    }
  };
  for (const auto& p : onlyM) note("metal", p.first, p.second);
  for (const auto& p : onlyD) note("dawn", p.first, p.second);

  std::printf(
      "GUIDED_COMPARE {\"fixture\":\"%s\",\"mode\":%d,\"max_residual\":%.9g,"
      "\"na\":%u,\"nb\":%u,\"metal_count\":%d,\"dawn_count\":%d,"
      "\"metal_sha256\":\"%s\",\"dawn_sha256\":\"%s\",\"identical\":%s,"
      "\"only_metal\":%zu,\"only_dawn\":%zu,\"jaccard\":%.6f,"
      "\"diff_min_rel_dist\":%.3g,\"diff_max_rel_dist\":%.3g,"
      "\"diff_within_1e-3\":%d,\"diff_within_1e-2\":%d,\"diffs\":[%s]}\n",
      dir.c_str(), mode, (double)maxResidual, f.na, f.nb, nm, nd, sm.c_str(),
      sd.c_str(), sm == sd ? "true" : "false", onlyM.size(), onlyD.size(),
      jaccard, n_diff ? min_dist : 0.0, n_diff ? max_dist : 0.0,
      n_boundary_1e3, n_boundary_1e2, diff_json.c_str());
  return 0;
}
