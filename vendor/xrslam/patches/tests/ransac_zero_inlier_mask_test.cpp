#include <xrslam/utility/ransac.h>

#include <algorithm>
#include <array>
#include <cassert>
#include <vector>

namespace {

struct Solver {
  int operator()(const std::array<int, 1>& sample) const { return sample[0]; }
};

struct ZeroInlierEvaluator {
  explicit ZeroInlierEvaluator(int) {}
  double operator()(int) const { return 1.0; }
};

struct AllInlierEvaluator {
  explicit AllInlierEvaluator(int) {}
  double operator()(int) const { return 0.0; }
};

}  // namespace

int main() {
  const std::vector<int> data{1, 2, 3, 4};

  xrslam::Ransac<1, int, Solver, ZeroInlierEvaluator> zero_inliers(
      0.0, 0.999, 8, 7);
  zero_inliers.solve(data);
  assert(zero_inliers.inlier_count == 0);
  assert(zero_inliers.inlier_mask.size() == data.size());
  assert(std::all_of(zero_inliers.inlier_mask.begin(),
                     zero_inliers.inlier_mask.end(),
                     [](char value) { return value == 0; }));

  xrslam::Ransac<1, int, Solver, AllInlierEvaluator> all_inliers(
      0.0, 0.999, 8, 7);
  all_inliers.solve(data);
  assert(all_inliers.inlier_count == data.size());
  assert(all_inliers.inlier_mask.size() == data.size());
  assert(std::all_of(all_inliers.inlier_mask.begin(),
                     all_inliers.inlier_mask.end(),
                     [](char value) { return value == 1; }));
}
