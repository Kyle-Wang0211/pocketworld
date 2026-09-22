#include "device_probe_main.h"

#include <cstdio>

int main(int argc, char** argv) {
  if (argc < 1 || argv == nullptr || argv[0] == nullptr || argv[0][0] == '\0') {
    std::fprintf(stderr, "missing executable path\n");
    return 2;
  }
  return RunDeviceProbeSequence(argv[0]);
}
