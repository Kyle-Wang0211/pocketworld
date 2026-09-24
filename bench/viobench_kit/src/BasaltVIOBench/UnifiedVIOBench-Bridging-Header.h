#ifndef UNIFIED_VIO_BENCH_BRIDGING_HEADER_H
#define UNIFIED_VIO_BENCH_BRIDGING_HEADER_H

#include "BasaltBench.h"
#include "XRSLAMBench.h"

#endif

// Production's VideoToolbox HEVC codec, vendored verbatim from
// pocketworld packages/pw_hevc/src at e20a5dd. The archive this bench writes is
// the archive production writes, so the encoder is production's rather than one
// written to look like it.
typedef struct PwVtEncoder PwVtEncoder;
typedef struct PwVtDecoder PwVtDecoder;

PwVtEncoder *pw_vt_create_ex(int32_t width, int32_t height, int32_t gop,
                             double quality, int64_t avg_bitrate,
                             int32_t power_efficient);
int32_t pw_vt_encode_nv12(PwVtEncoder *enc, const uint8_t *y, const uint8_t *uv,
                          int64_t pts_ms, int64_t duration_ms,
                          uint8_t **out_data, int64_t *out_len,
                          int32_t *out_keyframe);
void pw_vt_free(uint8_t *p);
void pw_vt_destroy(PwVtEncoder *enc);

PwVtDecoder *pw_vt_dec_create(int32_t width, int32_t height,
                              const uint8_t *keyframe_au, int64_t au_len);
int32_t pw_vt_dec_decode(PwVtDecoder *dec, const uint8_t *annexb, int64_t len,
                         uint8_t *out_y, uint8_t *out_uv);
void pw_vt_dec_destroy(PwVtDecoder *dec);
