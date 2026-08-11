// pw_jpeg_cvpb.c — bench 辅助:JPEG 文件 → BGRA CVPixelBuffer(纯 C,ImageIO)
// 只用于基准测试;生产路径的帧直接来自相机 CVPixelBuffer,不经过本文件。
#include <ImageIO/ImageIO.h>
#include <CoreGraphics/CoreGraphics.h>
#include <CoreVideo/CoreVideo.h>
#include <CoreFoundation/CoreFoundation.h>

void *pw_jpeg_to_bgra_cvpb(const char *path, int32_t *out_w, int32_t *out_h) {
    CFStringRef s = CFStringCreateWithCString(NULL, path, kCFStringEncodingUTF8);
    CFURLRef url = CFURLCreateWithFileSystemPath(NULL, s, kCFURLPOSIXPathStyle, false);
    CFRelease(s);
    CGImageSourceRef src = CGImageSourceCreateWithURL(url, NULL);
    CFRelease(url);
    if (!src) return NULL;
    CGImageRef img = CGImageSourceCreateImageAtIndex(src, 0, NULL);
    CFRelease(src);
    if (!img) return NULL;
    size_t w = CGImageGetWidth(img), h = CGImageGetHeight(img);

    CVPixelBufferRef pb = NULL;
    if (CVPixelBufferCreate(NULL, w, h, kCVPixelFormatType_32BGRA, NULL, &pb)
        != kCVReturnSuccess) { CGImageRelease(img); return NULL; }
    CVPixelBufferLockBaseAddress(pb, 0);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(
        CVPixelBufferGetBaseAddress(pb), w, h, 8,
        CVPixelBufferGetBytesPerRow(pb), cs,
        kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), img);
    CGContextRelease(ctx);
    CGColorSpaceRelease(cs);
    CVPixelBufferUnlockBaseAddress(pb, 0);
    CGImageRelease(img);
    if (out_w) *out_w = (int32_t)w;
    if (out_h) *out_h = (int32_t)h;
    return pb;
}

void pw_cvpb_release(void *pb) { if (pb) CVPixelBufferRelease((CVPixelBufferRef)pb); }
