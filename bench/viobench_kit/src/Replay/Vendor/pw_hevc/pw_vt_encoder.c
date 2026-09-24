// pw_vt_encoder.c — VideoToolbox 硬件 HEVC 编码的同步 C 适配层
//
// 为什么存在这个文件:VTCompressionSession 的输出是异步 C 回调,而 Dart FFI 的
// NativeCallable 要么不能跨线程同步调用(isolateLocal)、要么不能保证在
// CMSampleBuffer 生命周期内完成拷贝(listener)。这里用信号量把回调收敛成
// 同步调用,Dart 侧拿到的是普通的 malloc 缓冲区。
//
// 语言边界声明:本文件是纯 C(产品纪律:算法与编排在 Dart,平台适配在 C,
// 零 Swift/Objective-C)。iOS 与 macOS 共用本文件——VideoToolbox 在两端是
// 同一个 C API。Android 对应层直接用 AMediaCodec NDK C API,无需本适配
// (它本来就是同步拉取式)。
//
// 输出格式:Annex-B(起始码 00 00 00 01),关键帧前置 VPS/SPS/PPS。
// 这样产物可被任何标准 HEVC 解码器直接消费,便于跨端校验。

#include <VideoToolbox/VideoToolbox.h>
#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>
#include <dispatch/dispatch.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    uint8_t *data;
    size_t len;
    int32_t is_keyframe;
    OSStatus status;
} PwOutput;

typedef struct PwVtEncoder {
    VTCompressionSessionRef session;
    dispatch_semaphore_t done;
    PwOutput pending;
    int32_t width;
    int32_t height;
} PwVtEncoder;

static void append_bytes(uint8_t **buf, size_t *len, size_t *cap,
                         const uint8_t *src, size_t n) {
    if (*len + n > *cap) {
        *cap = (*len + n) * 2 + 1024;
        *buf = realloc(*buf, *cap);
    }
    memcpy(*buf + *len, src, n);
    *len += n;
}

static const uint8_t kStartCode[4] = {0, 0, 0, 1};

// 回调在 VideoToolbox 内部线程执行;必须在返回前完成所有拷贝。
static void output_callback(void *refcon, void *frame_refcon, OSStatus status,
                            VTEncodeInfoFlags flags, CMSampleBufferRef sample) {
    PwVtEncoder *enc = (PwVtEncoder *)refcon;
    PwOutput *out = &enc->pending;
    out->status = status;
    out->data = NULL;
    out->len = 0;
    out->is_keyframe = 0;

    if (status == noErr && sample != NULL) {
        CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample, false);
        int32_t keyframe = 1;
        if (attachments && CFArrayGetCount(attachments) > 0) {
            CFDictionaryRef att = CFArrayGetValueAtIndex(attachments, 0);
            keyframe = !CFDictionaryContainsKey(att, kCMSampleAttachmentKey_NotSync);
        }
        out->is_keyframe = keyframe;

        uint8_t *buf = NULL;
        size_t len = 0, cap = 0;

        if (keyframe) {
            CMFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(sample);
            size_t ps_count = 0;
            CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fmt, 0, NULL, NULL,
                                                               &ps_count, NULL);
            for (size_t i = 0; i < ps_count; i++) {
                const uint8_t *ps = NULL;
                size_t ps_len = 0;
                if (CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                        fmt, i, &ps, &ps_len, NULL, NULL) == noErr) {
                    append_bytes(&buf, &len, &cap, kStartCode, 4);
                    append_bytes(&buf, &len, &cap, ps, ps_len);
                }
            }
        }

        CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sample);
        size_t total = CMBlockBufferGetDataLength(block);
        uint8_t *raw = malloc(total);
        CMBlockBufferCopyDataBytes(block, 0, total, raw);
        // AVCC/HVCC 长度前缀 → Annex-B 起始码
        size_t pos = 0;
        while (pos + 4 <= total) {
            uint32_t nal_len = ((uint32_t)raw[pos] << 24) | ((uint32_t)raw[pos + 1] << 16) |
                               ((uint32_t)raw[pos + 2] << 8) | raw[pos + 3];
            if (pos + 4 + nal_len > total) break;
            append_bytes(&buf, &len, &cap, kStartCode, 4);
            append_bytes(&buf, &len, &cap, raw + pos + 4, nal_len);
            pos += 4 + nal_len;
        }
        free(raw);
        out->data = buf;
        out->len = len;
    }
    dispatch_semaphore_signal(enc->done);
}

// [2026-08-12] 省电模式 A/B 探针用:多一个显式旋钮,生产入口 pw_vt_create
// 原样委托 power_efficient=1(现状),行为零变化。
PwVtEncoder *pw_vt_create_ex(int32_t width, int32_t height, int32_t gop,
                             double quality, int64_t avg_bitrate,
                             int32_t power_efficient);

PwVtEncoder *pw_vt_create(int32_t width, int32_t height, int32_t gop,
                          double quality, int64_t avg_bitrate) {
    return pw_vt_create_ex(width, height, gop, quality, avg_bitrate, 1);
}

PwVtEncoder *pw_vt_create_ex(int32_t width, int32_t height, int32_t gop,
                             double quality, int64_t avg_bitrate,
                             int32_t power_efficient) {
    PwVtEncoder *enc = calloc(1, sizeof(PwVtEncoder));
    enc->done = dispatch_semaphore_create(0);
    enc->width = width;
    enc->height = height;
    OSStatus st = VTCompressionSessionCreate(
        NULL, width, height, kCMVideoCodecType_HEVC, NULL, NULL, NULL,
        output_callback, enc, &enc->session);
    if (st != noErr) { free(enc); return NULL; }

    VTSessionSetProperty(enc->session, kVTCompressionPropertyKey_ProfileLevel,
                         kVTProfileLevel_HEVC_Main_AutoLevel);
    VTSessionSetProperty(enc->session, kVTCompressionPropertyKey_RealTime,
                         kCFBooleanFalse);
    // [2026-08-10] 效率门归因:满屏幕亮度下编码功耗会挤压 SoC 热余量,
    // GPU 匹配阶段被微降频拖慢(match_ms +9~32%)。走低功耗编码路径,
    // 用略慢的编码换零 DVFS 压力——编码本来就只需跟上 ~1.2s/帧 的节奏。
    VTSessionSetProperty(enc->session,
                         kVTCompressionPropertyKey_MaximizePowerEfficiency,
                         power_efficient ? kCFBooleanTrue : kCFBooleanFalse);
    VTSessionSetProperty(enc->session, kVTCompressionPropertyKey_AllowFrameReordering,
                         kCFBooleanFalse);
    CFNumberRef g = CFNumberCreate(NULL, kCFNumberSInt32Type, &gop);
    VTSessionSetProperty(enc->session, kVTCompressionPropertyKey_MaxKeyFrameInterval, g);
    CFRelease(g);
    if (avg_bitrate > 0) {
        int32_t br = (int32_t)avg_bitrate;
        CFNumberRef b = CFNumberCreate(NULL, kCFNumberSInt32Type, &br);
        VTSessionSetProperty(enc->session, kVTCompressionPropertyKey_AverageBitRate, b);
        CFRelease(b);
    } else {
        CFNumberRef q = CFNumberCreate(NULL, kCFNumberDoubleType, &quality);
        VTSessionSetProperty(enc->session, kVTCompressionPropertyKey_Quality, q);
        CFRelease(q);
    }
    VTCompressionSessionPrepareToEncodeFrames(enc->session);
    return enc;
}

// 同步编码一帧 NV12。返回 0 成功;输出缓冲区归调用方,用 pw_vt_free 释放。
int32_t pw_vt_encode_nv12(PwVtEncoder *enc, const uint8_t *y, const uint8_t *uv,
                          int64_t pts_ms, int64_t duration_ms,
                          uint8_t **out_data, int64_t *out_len,
                          int32_t *out_keyframe) {
    CVPixelBufferRef pb = NULL;
    CVReturn cv = CVPixelBufferCreate(NULL, enc->width, enc->height,
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, NULL, &pb);
    if (cv != kCVReturnSuccess) return -100;

    CVPixelBufferLockBaseAddress(pb, 0);
    uint8_t *dst_y = CVPixelBufferGetBaseAddressOfPlane(pb, 0);
    size_t stride_y = CVPixelBufferGetBytesPerRowOfPlane(pb, 0);
    for (int r = 0; r < enc->height; r++)
        memcpy(dst_y + r * stride_y, y + (size_t)r * enc->width, enc->width);
    uint8_t *dst_uv = CVPixelBufferGetBaseAddressOfPlane(pb, 1);
    size_t stride_uv = CVPixelBufferGetBytesPerRowOfPlane(pb, 1);
    for (int r = 0; r < enc->height / 2; r++)
        memcpy(dst_uv + r * stride_uv, uv + (size_t)r * enc->width, enc->width);
    CVPixelBufferUnlockBaseAddress(pb, 0);

    CMTime pts = CMTimeMake(pts_ms, 1000);
    CMTime dur = CMTimeMake(duration_ms, 1000);
    OSStatus st = VTCompressionSessionEncodeFrame(enc->session, pb, pts, dur,
                                                  NULL, NULL, NULL);
    CVPixelBufferRelease(pb);
    if (st != noErr) return st;

    // AllowFrameReordering=false ⇒ 每帧一出;等待本帧回调完成。
    dispatch_semaphore_wait(enc->done, DISPATCH_TIME_FOREVER);
    if (enc->pending.status != noErr) return enc->pending.status;
    *out_data = enc->pending.data;
    *out_len = (int64_t)enc->pending.len;
    *out_keyframe = enc->pending.is_keyframe;
    return 0;
}

int32_t pw_vt_flush(PwVtEncoder *enc) {
    return VTCompressionSessionCompleteFrames(enc->session, kCMTimeInvalid);
}

void pw_vt_free(uint8_t *p) { free(p); }

void pw_vt_destroy(PwVtEncoder *enc) {
    if (!enc) return;
    if (enc->session) {
        VTCompressionSessionInvalidate(enc->session);
        CFRelease(enc->session);
    }
    free(enc);
}

// ---- 生产路径:CVPixelBuffer 零拷贝直喂 ----
// ARKit/相机回调给出的就是 CVPixelBufferRef;直接入编码器,零 memcpy。
// 调用方负责在返回前保持 buffer 存活(编码是同步的,返回即可释放)。
int32_t pw_vt_encode_cvpb(PwVtEncoder *enc, void *pixel_buffer,
                          int64_t pts_ms, int64_t duration_ms,
                          uint8_t **out_data, int64_t *out_len,
                          int32_t *out_keyframe) {
    CVPixelBufferRef pb = (CVPixelBufferRef)pixel_buffer;
    CMTime pts = CMTimeMake(pts_ms, 1000);
    CMTime dur = CMTimeMake(duration_ms, 1000);
    OSStatus st = VTCompressionSessionEncodeFrame(enc->session, pb, pts, dur,
                                                  NULL, NULL, NULL);
    if (st != noErr) return st;
    dispatch_semaphore_wait(enc->done, DISPATCH_TIME_FOREVER);
    if (enc->pending.status != noErr) return enc->pending.status;
    *out_data = enc->pending.data;
    *out_len = (int64_t)enc->pending.len;
    *out_keyframe = enc->pending.is_keyframe;
    return 0;
}
