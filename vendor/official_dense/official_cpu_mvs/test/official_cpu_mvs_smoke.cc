#include "official_cpu_mvs/bridge.h"

#include <cstdlib>

int main() {
  if (pw_official_cpu_mvs_default_options_smoke() != 0) {
    return EXIT_FAILURE;
  }
  if (pw_official_cpu_mvs_run_unavailable() != -1) {
    return EXIT_FAILURE;
  }
  return EXIT_SUCCESS;
}

