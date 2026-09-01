#ifndef PW_XRSLAM_RANSAC_TEST_RANDOM_H
#define PW_XRSLAM_RANSAC_TEST_RANDOM_H

#include <algorithm>
#include <cstddef>
#include <numeric>
#include <random>
#include <vector>

namespace xrslam {

class LotBox {
 public:
  explicit LotBox(std::size_t size) : cap_(0), lots_(size) {
    std::iota(lots_.begin(), lots_.end(), 0);
  }

  void seed(unsigned int value) { engine_.seed(value); }
  void refill_all() { cap_ = 0; }

  std::size_t draw_without_replacement() {
    std::uniform_int_distribution<std::size_t> distribution(
        cap_, lots_.size() - 1);
    std::swap(lots_[cap_], lots_[distribution(engine_)]);
    return lots_[cap_++];
  }

 private:
  std::size_t cap_;
  std::vector<std::size_t> lots_;
  std::default_random_engine engine_;
};

}  // namespace xrslam

#endif
