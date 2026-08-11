// pw_vt_decoder.c — VideoToolbox 硬件 HEVC 解码的同步 C 适配层
//
// 与编码器同一纪律:纯 C、iOS/macOS 共用、零 Swift。
// VTDecompressionSessionDecodeFrame 不带异步 flag 时回调在返回前同步触发,
// 因此这里比编码侧更简单,不需要信号量。
//
// 输入:单个 Annex-B access unit(一帧,关键帧可带 VPS/SPS/PPS 前缀)。
// 输出:NV12(Y 平面 + 交错 UV 平面),写入调用方缓冲区。

#include <VideoToolbox/VideoToolbox.h>
#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>
#include <stdlib.h>
#include <string.h>

typedef struct PwVtDecoder {
    VTDecompressionSessionRef session;
    CMVideoFormatDescriptionRef format;
    int32_t width;
    int32_t height;
    uint8_t *out_y;      // 本次解码的目标缓冲区(调用期间有效)
    uint8_t *out_uv;
    OSStatus cb_status;
} PwVtDecoder;

static void decode_callback(void *refcon, void *frame_refcon, OSStatus status,
                            VTDecodeInfoFlags flags, CVImageBufferRef image,
                            CMTime pts, CMTime duration) {
    PwVtDecoder *dec = (PwVtDecoder *)refcon;
    dec->cb_status = status;
    if (status != noErr || image == NULL) return;
    CVPixelBufferLockBaseAddress(image, kCVPixelBufferLock_ReadOnly);
    const uint8_t *y = CVPixelBufferGetBaseAddressOfPlane(image, 0);
    size_t sy = CVPixelBufferGetBytesPerRowOfPlane(image, 0);
    for (int r = 0; r < dec->height; r++)
        memcpy(dec->out_y + (size_t)r * dec->width, y + r * sy, dec->width);
    const uint8_t *uv = CVPixelBufferGetBaseAddressOfPlane(image, 1);
    size_t suv = CVPixelBufferGetBytesPerRowOfPlane(image, 1);
    for (int r = 0; r < dec->height / 2; r++)
        memcpy(dec->out_uv + (size_t)r * dec->width, uv + r * suv, dec->width);
    CVPixelBufferUnlockBaseAddress(image, kCVPixelBufferLock_ReadOnly);
}

// 在 Annex-B 字节流中枚举 NAL:返回下一个 NAL 的起点与长度(不含起始码)。
static const uint8_t *next_nal(const uint8_t *p, const uint8_t *end,
                               const uint8_t **nal, size_t *nal_len) {
    // 找起始码
    const uint8_t *s = p;
    while (s + 3 < end && !(s[0] == 0 && s[1] == 0 && s[2] == 1)) s++;
    if (s + 3 >= end) return NULL;
    s += 3;
    // 找下一个起始码或结尾
    const uint8_t *e = s;
    while (e + 3 < end && !(e[0] == 0 && e[1] == 0 && e[2] == 1)) e++;
    if (e + 3 >= end) e = end;
    else if (e > s && e[-1] == 0) e--;  // 4 字节起始码的前导 0
    *nal = s;
    *nal_len = (size_t)(e - s);
    return e;
}

PwVtDecoder *pw_vt_dec_create(int32_t width, int32_t height,
                              const uint8_t *keyframe_au, int64_t au_len) {
    // 从关键帧 AU 中提取 VPS(32)/SPS(33)/PPS(34)
    const uint8_t *ps[3] = {NULL, NULL, NULL};
    size_t ps_len[3] = {0, 0, 0};
    const uint8_t *p = keyframe_au, *end = keyframe_au + au_len;
    const uint8_t *nal; size_t nal_len;
    while ((p = next_nal(p, end, &nal, &nal_len)) != NULL) {
        int type = (nal[0] >> 1) & 0x3F;
        if (type == 32 && !ps[0]) { ps[0] = nal; ps_len[0] = nal_len; }
        if (type == 33 && !ps[1]) { ps[1] = nal; ps_len[1] = nal_len; }
        if (type == 34 && !ps[2]) { ps[2] = nal; ps_len[2] = nal_len; }
    }
    if (!ps[0] || !ps[1] || !ps[2]) return NULL;

    PwVtDecoder *dec = calloc(1, sizeof(PwVtDecoder));
    dec->width = width;
    dec->height = height;
    OSStatus st = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
        NULL, 3, ps, ps_len, 4, NULL, &dec->format);
    if (st != noErr) { free(dec); return NULL; }

    int32_t pf = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
    CFNumberRef pfn = CFNumberCreate(NULL, kCFNumberSInt32Type, &pf);
    const void *keys[] = {kCVPixelBufferPixelFormatTypeKey};
    const void *vals[] = {pfn};
    CFDictionaryRef attrs = CFDictionaryCreate(NULL, keys, vals, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    VTDecompressionOutputCallbackRecord cb = {decode_callback, dec};
    st = VTDecompressionSessionCreate(NULL, dec->format, NULL, attrs, &cb,
                                      &dec->session);
    CFRelease(attrs); CFRelease(pfn);
    if (st != noErr) { CFRelease(dec->format); free(dec); return NULL; }
    return dec;
}

// 同步解码一个 access unit;输出写入 out_y/out_uv(尺寸 w*h 与 w*h/2)。
int32_t pw_vt_dec_decode(PwVtDecoder *dec, const uint8_t *annexb, int64_t len,
                         uint8_t *out_y, uint8_t *out_uv) {
    // Annex-B → AVCC(4 字节长度前缀),跳过参数集(已在 format 里)
    uint8_t *avcc = malloc((size_t)len + 64);
    size_t alen = 0;
    const uint8_t *p = annexb, *end = annexb + len;
    const uint8_t *nal; size_t nal_len;
    while ((p = next_nal(p, end, &nal, &nal_len)) != NULL) {
        int type = (nal[0] >> 1) & 0x3F;
        if (type == 32 || type == 33 || type == 34) continue;
        avcc[alen++] = (uint8_t)(nal_len >> 24);
        avcc[alen++] = (uint8_t)(nal_len >> 16);
        avcc[alen++] = (uint8_t)(nal_len >> 8);
        avcc[alen++] = (uint8_t)(nal_len);
        memcpy(avcc + alen, nal, nal_len);
        alen += nal_len;
    }
    CMBlockBufferRef block = NULL;
    // blockAllocator 必须是 kCFAllocatorNull:所有权留在本函数,结尾统一 free。
    // 传 NULL 会被当作默认分配器接管所有权,导致双重释放(SIGABRT)。
    OSStatus st = CMBlockBufferCreateWithMemoryBlock(NULL, avcc, alen,
        kCFAllocatorNull, NULL, 0, alen, 0, &block);
    if (st != noErr) { free(avcc); return st; }
    CMSampleBufferRef sample = NULL;
    size_t sizes[] = {alen};
    st = CMSampleBufferCreateReady(NULL, block, dec->format, 1, 0, NULL, 1,
                                   sizes, &sample);
    if (st != noErr) { CFRelease(block); free(avcc); return st; }

    dec->out_y = out_y;
    dec->out_uv = out_uv;
    dec->cb_status = -1;
    // 不带异步 flag ⇒ 回调在返回前同步触发
    st = VTDecompressionSessionDecodeFrame(dec->session, sample, 0, NULL, NULL);
    CFRelease(sample); CFRelease(block); free(avcc);
    if (st != noErr) return st;
    return dec->cb_status;
}

void pw_vt_dec_destroy(PwVtDecoder *dec) {
    if (!dec) return;
    if (dec->session) {
        VTDecompressionSessionInvalidate(dec->session);
        CFRelease(dec->session);
    }
    if (dec->format) CFRelease(dec->format);
    free(dec);
}
