// pw_nv12_jpeg.c — NV12 平面 → JPEG 文件(纯 C,CoreVideo+ImageIO)
// PWVA 归档按需物化用:解码出的帧重新落成 JPEG 供既有路径契约的消费者
// (native SfM 喂帧/取色)使用。像素级重编码,不承诺字节等同源 JPEG。
#include <ImageIO/ImageIO.h>
#include <CoreGraphics/CoreGraphics.h>
#include <CoreVideo/CoreVideo.h>
#include <CoreFoundation/CoreFoundation.h>
#include <VideoToolbox/VideoToolbox.h>
#include <string.h>

int32_t pw_nv12_to_jpeg_file(const uint8_t *y, const uint8_t *uv,
                             int32_t w, int32_t h, double quality,
                             const char *path) {
    CVPixelBufferRef pb = NULL;
    if (CVPixelBufferCreate(NULL, w, h,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, NULL, &pb)
        != kCVReturnSuccess) return -1;
    CVPixelBufferLockBaseAddress(pb, 0);
    uint8_t *dstY = CVPixelBufferGetBaseAddressOfPlane(pb, 0);
    uint8_t *dstUV = CVPixelBufferGetBaseAddressOfPlane(pb, 1);
    size_t strideY = CVPixelBufferGetBytesPerRowOfPlane(pb, 0);
    size_t strideUV = CVPixelBufferGetBytesPerRowOfPlane(pb, 1);
    for (int32_t r = 0; r < h; r++)
        memcpy(dstY + r * strideY, y + (size_t)r * w, w);
    for (int32_t r = 0; r < h / 2; r++)
        memcpy(dstUV + r * strideUV, uv + (size_t)r * w, w);
    CVPixelBufferUnlockBaseAddress(pb, 0);

    CGImageRef img = NULL;
    OSStatus st = VTCreateCGImageFromCVPixelBuffer(pb, NULL, &img);
    CVPixelBufferRelease(pb);
    if (st != noErr || !img) { if (img) CGImageRelease(img); return -2; }

    CFStringRef s = CFStringCreateWithCString(NULL, path, kCFStringEncodingUTF8);
    CFURLRef url = CFURLCreateWithFileSystemPath(NULL, s, kCFURLPOSIXPathStyle, false);
    CFRelease(s);
    CGImageDestinationRef dest =
        CGImageDestinationCreateWithURL(url, CFSTR("public.jpeg"), 1, NULL);
    CFRelease(url);
    if (!dest) { CGImageRelease(img); return -3; }
    CFNumberRef q = CFNumberCreate(NULL, kCFNumberDoubleType, &quality);
    const void *keys[] = {kCGImageDestinationLossyCompressionQuality};
    const void *vals[] = {q};
    CFDictionaryRef opts = CFDictionaryCreate(NULL, keys, vals, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CGImageDestinationAddImage(dest, img, opts);
    bool ok = CGImageDestinationFinalize(dest);
    CFRelease(opts);
    CFRelease(q);
    CFRelease(dest);
    CGImageRelease(img);
    return ok ? 0 : -4;
}
