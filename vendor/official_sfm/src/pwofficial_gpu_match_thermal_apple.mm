// pwofficial_gpu_match_thermal_apple.mm — Apple provider of the weak
// platform hook consumed by the cross-platform Dawn matcher TU
// (pwofficial_gpu_match_dawn.cc). Returns NSProcessInfo.thermalState on the
// same 0..3 scale the C core uses for aether_sfm_set_thermal_state
// (NSProcessInfoThermalStateNominal=0 · Fair=1 · Serious=2 · Critical=3), so
// the Dawn backend's KNIFE-C chunk targets and duty-cycle gaps fire on
// exactly the same states as the Metal TU's own NSProcessInfo reads.
// Pure observation; no matcher logic lives here. Android/HarmonyOS builds
// omit this file and feed aether_gpu_match_set_thermal_state instead.

#import <Foundation/Foundation.h>

extern "C" int pwofficial_platform_thermal_state(void) {
  if (@available(iOS 11.0, macOS 10.10.3, *)) {
    return (int)NSProcessInfo.processInfo.thermalState;
  }
  return 0;
}
