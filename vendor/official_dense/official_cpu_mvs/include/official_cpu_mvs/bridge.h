#pragma once

#ifdef __cplusplus
extern "C" {
#endif

// A small link/runtime probe. It constructs COLMAP's official default
// StereoFusionOptions and returns 0 only when its documented defaults match.
int pw_official_cpu_mvs_default_options_smoke(void);

// Dense execution is deliberately unavailable until a validated workspace is
// passed through the product bridge. This closure does not invent synthetic
// production inputs.
int pw_official_cpu_mvs_run_unavailable(void);

#ifdef __cplusplus
}
#endif

