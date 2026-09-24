// PWSplatABBench —— 设备侧 instancing vs 顶点展开 阴性对照台架。
//
// 起因(2026-09-23):GPU 点云调研 §2.2c 查到三条独立证据说 WebGPU 上
// `draw(6, N)` instancing 是性能反模式(gpuweb#332 potree 原话、magcius 的
// warp 占用率机理、voxelkloud 实测 656ms vs 72ms)。**但三条全是桌面
// NVIDIA / WebGL。** 移动 TBDR 上成不成立零证据。这份台架就是去量它。
//
// 口径(照 PWMatchBench 的规矩):两条臂**同一进程内交替**,同一份 splat
// 数据、同一个 buffer、同一张渲染目标,只差 pipeline(= 只差 shader 的
// 取索引方式)和 draw 参数。不是两次启动、不靠 env。
//
// 实验设计(为什么这么排,见报告):
//   - 手机最大的混杂是**热漂移/降频**。所以不能先连跑 A 再连跑 B:三个
//     标签(A / B / A′)按轮号循环轮换次序,R=9 时每个标签在首/中/末位
//     各 3 次 ⇒ 块内位置效应在标签之间完全平衡。
//   - 一次 run 里的几千帧不是「臂」的独立重复(伪重复)。每个格子跑
//     R 轮 × K 帧,轮是重复单位。
//   - **判据必须能对失效模式报警**:
//       (a) 阳性对照 —— 同一把尺子量 arm A 在 N 和 N/2 上。若尺子量不出
//           「活儿少一半」,那它也量不出臂间差异,任何零结果都不可信。
//       (b) 正确性对照 —— 两臂的帧缓冲必须逐字节相同。若不同,说明我
//           改错了 shader,性能数字无意义。
//       (c) 噪声底 —— A′ 与 A 是同一条 pipeline、同一个 draw,所以 A′/A
//           偏离 1.0 多少,就是这套 A/B 机器自己分辨不了的下限。
#import <Foundation/Foundation.h>
#include <webgpu/webgpu.h>
#include <CommonCrypto/CommonDigest.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <random>
#include <string>
#include <vector>

#include "wgsl_arms.h"

namespace {

// ─── 基本常量 ───────────────────────────────────────────────────────────
// iPhone 14 Pro 原生分辨率。渲染目标与真机屏幕同尺寸,免得在一个不真实的
// 分辨率上定价(匹配器战役的教训:在错的平台/错的规模上定价会翻车)。
constexpr uint32_t kW = 1179;
constexpr uint32_t kH = 2556;

// splat_render.wgsl 的 ProjectedSplat:9 个 f32,stride 36 B。
struct ProjectedSplat {
    float xy_x, xy_y;
    float conic_x, conic_y, conic_z;
    float r, g, b, a;
};
static_assert(sizeof(ProjectedSplat) == 36, "ProjectedSplat must be 36 bytes");

// splat_render.wgsl 的 RenderUniforms(storage, read)。shader 只读
// img_size,其余字段按 WGSL 布局规则占位即可。
struct RenderUniforms {
    float viewmat[16];      // 0
    float focal[2];         // 64
    uint32_t img_size[2];   // 72
    uint32_t tile_bounds[2];// 80
    float pixel_center[2];  // 88
    float camera_position[4]; // 96
    uint32_t sh_degree;     // 112
    uint32_t num_visible;   // 116
    uint32_t total_splats;  // 120
    uint32_t max_intersects;// 124
    float background[4];    // 128
};
static_assert(sizeof(RenderUniforms) == 144, "RenderUniforms must be 144 bytes");

double NowMs() {
    using namespace std::chrono;
    return duration<double, std::milli>(steady_clock::now().time_since_epoch()).count();
}

std::string Sha256Hex(const void* p, size_t n) {
    unsigned char d[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(p, (CC_LONG)n, d);
    char buf[2 * CC_SHA256_DIGEST_LENGTH + 1];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; ++i)
        std::snprintf(buf + 2 * i, 3, "%02x", d[i]);
    return std::string(buf, 2 * CC_SHA256_DIGEST_LENGTH);
}

WGPUStringView SV(const char* s) { return WGPUStringView{s, WGPU_STRLEN}; }

// ─── 同步桥:Dawn 的 future + WaitAny(instance 开了 TimedWaitAny)────
struct Gpu {
    WGPUInstance instance = nullptr;
    WGPUAdapter adapter = nullptr;
    WGPUDevice device = nullptr;
    WGPUQueue queue = nullptr;
    bool has_timestamp = false;
    std::string adapter_name;
    std::string error_log;
};

Gpu g;

void OnUncapturedError(WGPUDevice const*, WGPUErrorType type,
                       WGPUStringView msg, void*, void*) {
    g.error_log += "[wgpu error " + std::to_string((int)type) + "] " +
                   std::string(msg.data, msg.length == WGPU_STRLEN
                                             ? std::strlen(msg.data)
                                             : msg.length) + "\n";
}

void WaitFuture(WGPUFuture f) {
    WGPUFutureWaitInfo w{f, false};
    wgpuInstanceWaitAny(g.instance, 1, &w, UINT64_MAX);
}

bool InitGpu(std::string* err) {
    static const WGPUInstanceFeatureName kTimed =
        WGPUInstanceFeatureName_TimedWaitAny;
    WGPUInstanceDescriptor idesc = WGPU_INSTANCE_DESCRIPTOR_INIT;
    idesc.requiredFeatureCount = 1;
    idesc.requiredFeatures = &kTimed;
    g.instance = wgpuCreateInstance(&idesc);
    if (!g.instance) { *err = "wgpuCreateInstance failed"; return false; }

    WGPURequestAdapterOptions aopt = WGPU_REQUEST_ADAPTER_OPTIONS_INIT;
    aopt.powerPreference = WGPUPowerPreference_HighPerformance;
    aopt.backendType = WGPUBackendType_Metal;
    WGPURequestAdapterCallbackInfo aci = WGPU_REQUEST_ADAPTER_CALLBACK_INFO_INIT;
    aci.mode = WGPUCallbackMode_WaitAnyOnly;
    aci.callback = [](WGPURequestAdapterStatus st, WGPUAdapter a,
                      WGPUStringView, void*, void*) {
        if (st == WGPURequestAdapterStatus_Success) g.adapter = a;
    };
    WaitFuture(wgpuInstanceRequestAdapter(g.instance, &aopt, aci));
    if (!g.adapter) { *err = "RequestAdapter failed"; return false; }

    WGPUAdapterInfo info = WGPU_ADAPTER_INFO_INIT;
    if (wgpuAdapterGetInfo(g.adapter, &info) == WGPUStatus_Success) {
        auto sv = [](WGPUStringView v) {
            return std::string(v.data ? v.data : "",
                               v.data == nullptr ? 0
                                   : (v.length == WGPU_STRLEN
                                          ? std::strlen(v.data) : v.length));
        };
        g.adapter_name = sv(info.device) + " | " + sv(info.description) +
                         " | " + sv(info.vendor);
    }

    WGPULimits alim = WGPU_LIMITS_INIT;
    wgpuAdapterGetLimits(g.adapter, &alim);

    // 4M splat × 36 B = 144 MB > 默认 128 MiB 的 maxStorageBufferBindingSize。
    // 要显式申请 adapter 支持的上限,否则 CreateBindGroup 会校验失败。
    WGPULimits req = WGPU_LIMITS_INIT;
    req.maxStorageBufferBindingSize = alim.maxStorageBufferBindingSize;
    req.maxBufferSize = alim.maxBufferSize;

    g.has_timestamp = wgpuAdapterHasFeature(g.adapter,
                                            WGPUFeatureName_TimestampQuery);
    WGPUFeatureName feats[1] = {WGPUFeatureName_TimestampQuery};

    WGPUDeviceDescriptor ddesc = WGPU_DEVICE_DESCRIPTOR_INIT;
    ddesc.requiredLimits = &req;
    ddesc.requiredFeatureCount = g.has_timestamp ? 1 : 0;
    ddesc.requiredFeatures = g.has_timestamp ? feats : nullptr;
    ddesc.uncapturedErrorCallbackInfo.callback = OnUncapturedError;

    WGPURequestDeviceCallbackInfo dci = WGPU_REQUEST_DEVICE_CALLBACK_INFO_INIT;
    dci.mode = WGPUCallbackMode_WaitAnyOnly;
    dci.callback = [](WGPURequestDeviceStatus st, WGPUDevice d,
                      WGPUStringView, void*, void*) {
        if (st == WGPURequestDeviceStatus_Success) g.device = d;
    };
    WaitFuture(wgpuAdapterRequestDevice(g.adapter, &ddesc, dci));
    if (!g.device) { *err = "RequestDevice failed"; return false; }
    g.queue = wgpuDeviceGetQueue(g.device);
    return true;
}

WGPUShaderModule MakeModule(const char* wgsl) {
    WGPUShaderSourceWGSL src = WGPU_SHADER_SOURCE_WGSL_INIT;
    src.code = SV(wgsl);
    WGPUShaderModuleDescriptor d = WGPU_SHADER_MODULE_DESCRIPTOR_INIT;
    d.nextInChain = reinterpret_cast<WGPUChainedStruct*>(&src);
    return wgpuDeviceCreateShaderModule(g.device, &d);
}

// 与 scene_iosurface_renderer.cpp:555-585 的 splat pipeline 逐字同构:
// RGBA8Unorm + premultiplied OVER、Depth32Float 只读测试、cullMode None。
WGPURenderPipeline MakePipeline(WGPUShaderModule m) {
    WGPUBlendState blend = WGPU_BLEND_STATE_INIT;
    blend.color.operation = WGPUBlendOperation_Add;
    blend.color.srcFactor = WGPUBlendFactor_One;
    blend.color.dstFactor = WGPUBlendFactor_OneMinusSrcAlpha;
    blend.alpha.operation = WGPUBlendOperation_Add;
    blend.alpha.srcFactor = WGPUBlendFactor_One;
    blend.alpha.dstFactor = WGPUBlendFactor_OneMinusSrcAlpha;

    WGPUColorTargetState ct = WGPU_COLOR_TARGET_STATE_INIT;
    ct.format = WGPUTextureFormat_RGBA8Unorm;
    ct.blend = &blend;
    ct.writeMask = WGPUColorWriteMask_All;

    WGPUFragmentState fs = WGPU_FRAGMENT_STATE_INIT;
    fs.module = m;
    fs.entryPoint = SV("fs_main");
    fs.targetCount = 1;
    fs.targets = &ct;

    WGPUVertexState vs = WGPU_VERTEX_STATE_INIT;
    vs.module = m;
    vs.entryPoint = SV("vs_main");
    vs.bufferCount = 0;

    WGPUDepthStencilState ds = WGPU_DEPTH_STENCIL_STATE_INIT;
    ds.format = WGPUTextureFormat_Depth32Float;
    ds.depthWriteEnabled = WGPUOptionalBool_False;
    ds.depthCompare = WGPUCompareFunction_LessEqual;

    WGPURenderPipelineDescriptor p = WGPU_RENDER_PIPELINE_DESCRIPTOR_INIT;
    p.vertex = vs;
    p.fragment = &fs;
    p.primitive.topology = WGPUPrimitiveTopology_TriangleList;
    p.primitive.cullMode = WGPUCullMode_None;
    p.primitive.frontFace = WGPUFrontFace_CCW;
    p.depthStencil = &ds;
    p.multisample.count = 1;
    p.multisample.mask = 0xFFFFFFFFu;
    return wgpuDeviceCreateRenderPipeline(g.device, &p);
}

WGPUBuffer MakeBuffer(uint64_t size, WGPUBufferUsage usage) {
    WGPUBufferDescriptor d = WGPU_BUFFER_DESCRIPTOR_INIT;
    d.size = size;
    d.usage = usage;
    return wgpuDeviceCreateBuffer(g.device, &d);
}

// ─── 统计 ───────────────────────────────────────────────────────────────
struct Stats {
    double n = 0, mean = 0, p01 = 0, p50 = 0, p90 = 0, p99 = 0, mn = 0, mx = 0;
};
Stats Summarize(std::vector<double> v) {
    Stats s;
    if (v.empty()) return s;
    std::sort(v.begin(), v.end());
    auto q = [&](double f) {
        size_t i = (size_t)std::llround(f * (double)(v.size() - 1));
        return v[std::min(i, v.size() - 1)];
    };
    double sum = 0; for (double x : v) sum += x;
    s.n = (double)v.size();
    s.mean = sum / (double)v.size();
    s.p01 = q(0.01); s.p50 = q(0.50); s.p90 = q(0.90); s.p99 = q(0.99);
    s.mn = v.front(); s.mx = v.back();
    return s;
}
std::string StatsJson(const Stats& s) {
    char b[512];
    std::snprintf(b, sizeof b,
        "{\"n\":%.0f,\"mean\":%.4f,\"p01\":%.4f,\"p50\":%.4f,\"p90\":%.4f,"
        "\"p99\":%.4f,\"min\":%.4f,\"max\":%.4f}",
        s.n, s.mean, s.p01, s.p50, s.p90, s.p99, s.mn, s.mx);
    return b;
}

// ─── 帧渲染 ─────────────────────────────────────────────────────────────
struct Rt {
    WGPUTexture color = nullptr, depth = nullptr;
    WGPUTextureView color_v = nullptr, depth_v = nullptr;
};

// 一帧 = 一个 encoder、一个 render pass、一次 draw、一次 submit、一次等完成。
// 与 scene_iosurface_renderer.cpp 的生产路径同构(它也是每帧
// wgpuQueueOnSubmittedWorkDone + WaitAny 等到完成)。
// 返回 host 侧壁钟 ms;GPU ns 写进 resolve buffer 的第 slot 格。
double RenderOneFrame(const Rt& rt, WGPURenderPipeline pipe,
                      WGPUBindGroup bg, uint32_t vertex_count,
                      uint32_t instance_count,
                      WGPUQuerySet qs, WGPUBuffer resolve, uint32_t slot) {
    const double t0 = NowMs();

    WGPUCommandEncoderDescriptor ed = WGPU_COMMAND_ENCODER_DESCRIPTOR_INIT;
    WGPUCommandEncoder enc = wgpuDeviceCreateCommandEncoder(g.device, &ed);

    WGPURenderPassColorAttachment ca = WGPU_RENDER_PASS_COLOR_ATTACHMENT_INIT;
    ca.view = rt.color_v;
    ca.loadOp = WGPULoadOp_Clear;
    ca.storeOp = WGPUStoreOp_Store;
    ca.clearValue = WGPUColor{0, 0, 0, 0};
    ca.depthSlice = WGPU_DEPTH_SLICE_UNDEFINED;

    WGPURenderPassDepthStencilAttachment da =
        WGPU_RENDER_PASS_DEPTH_STENCIL_ATTACHMENT_INIT;
    da.view = rt.depth_v;
    da.depthLoadOp = WGPULoadOp_Undefined;
    da.depthStoreOp = WGPUStoreOp_Undefined;
    da.depthReadOnly = WGPU_TRUE;

    WGPUPassTimestampWrites tw = WGPU_PASS_TIMESTAMP_WRITES_INIT;
    if (qs) {
        tw.querySet = qs;
        tw.beginningOfPassWriteIndex = 0;
        tw.endOfPassWriteIndex = 1;
    }

    WGPURenderPassDescriptor pd = WGPU_RENDER_PASS_DESCRIPTOR_INIT;
    pd.colorAttachmentCount = 1;
    pd.colorAttachments = &ca;
    pd.depthStencilAttachment = &da;
    pd.timestampWrites = qs ? &tw : nullptr;

    WGPURenderPassEncoder pass = wgpuCommandEncoderBeginRenderPass(enc, &pd);
    wgpuRenderPassEncoderSetPipeline(pass, pipe);
    wgpuRenderPassEncoderSetBindGroup(pass, 0, bg, 0, nullptr);
    wgpuRenderPassEncoderDraw(pass, vertex_count, instance_count, 0, 0);
    wgpuRenderPassEncoderEnd(pass);
    wgpuRenderPassEncoderRelease(pass);

    if (qs) {
        // destinationOffset 必须 256 对齐 ⇒ 每帧占一个 256 B 格。
        wgpuCommandEncoderResolveQuerySet(enc, qs, 0, 2, resolve,
                                          (uint64_t)slot * 256ull);
    }

    WGPUCommandBufferDescriptor cbd = WGPU_COMMAND_BUFFER_DESCRIPTOR_INIT;
    WGPUCommandBuffer cb = wgpuCommandEncoderFinish(enc, &cbd);
    wgpuCommandEncoderRelease(enc);
    wgpuQueueSubmit(g.queue, 1, &cb);
    wgpuCommandBufferRelease(cb);

    WGPUQueueWorkDoneCallbackInfo wi = WGPU_QUEUE_WORK_DONE_CALLBACK_INFO_INIT;
    wi.mode = WGPUCallbackMode_WaitAnyOnly;
    wi.callback = [](WGPUQueueWorkDoneStatus, WGPUStringView, void*, void*) {};
    WaitFuture(wgpuQueueOnSubmittedWorkDone(g.queue, wi));

    return NowMs() - t0;
}

// 把 resolve buffer 拷到 staging 并 map 读回 GPU 时间戳(ns)。
std::vector<double> ReadGpuNs(WGPUBuffer resolve, WGPUBuffer staging,
                              uint32_t count) {
    std::vector<double> out;
    if (count == 0) return out;
    const uint64_t bytes = (uint64_t)count * 256ull;
    WGPUCommandEncoderDescriptor ed = WGPU_COMMAND_ENCODER_DESCRIPTOR_INIT;
    WGPUCommandEncoder enc = wgpuDeviceCreateCommandEncoder(g.device, &ed);
    wgpuCommandEncoderCopyBufferToBuffer(enc, resolve, 0, staging, 0, bytes);
    WGPUCommandBufferDescriptor cbd = WGPU_COMMAND_BUFFER_DESCRIPTOR_INIT;
    WGPUCommandBuffer cb = wgpuCommandEncoderFinish(enc, &cbd);
    wgpuCommandEncoderRelease(enc);
    wgpuQueueSubmit(g.queue, 1, &cb);
    wgpuCommandBufferRelease(cb);

    bool ok = false;
    WGPUBufferMapCallbackInfo mi = WGPU_BUFFER_MAP_CALLBACK_INFO_INIT;
    mi.mode = WGPUCallbackMode_WaitAnyOnly;
    mi.callback = [](WGPUMapAsyncStatus st, WGPUStringView, void* u, void*) {
        *static_cast<bool*>(u) = (st == WGPUMapAsyncStatus_Success);
    };
    mi.userdata1 = &ok;
    WaitFuture(wgpuBufferMapAsync(staging, WGPUMapMode_Read, 0, bytes, mi));
    if (ok) {
        const uint8_t* p = static_cast<const uint8_t*>(
            wgpuBufferGetConstMappedRange(staging, 0, bytes));
        if (p) {
            for (uint32_t i = 0; i < count; ++i) {
                uint64_t t0, t1;
                std::memcpy(&t0, p + (size_t)i * 256 + 0, 8);
                std::memcpy(&t1, p + (size_t)i * 256 + 8, 8);
                // 时间戳不可用时 Dawn 写 0;跳过这种格。
                if (t1 > t0) out.push_back((double)(t1 - t0) / 1.0e6);
            }
        }
        wgpuBufferUnmap(staging);
    }
    return out;
}

// 读回整张彩色图,算 sha256(正确性对照)。
std::string ReadbackSha(const Rt& rt, std::vector<uint8_t>* raw) {
    const uint32_t bpr = ((kW * 4u) + 255u) / 256u * 256u;
    const uint64_t bytes = (uint64_t)bpr * kH;
    WGPUBuffer stage = MakeBuffer(bytes,
        (WGPUBufferUsage)(WGPUBufferUsage_MapRead | WGPUBufferUsage_CopyDst));

    WGPUCommandEncoderDescriptor ed = WGPU_COMMAND_ENCODER_DESCRIPTOR_INIT;
    WGPUCommandEncoder enc = wgpuDeviceCreateCommandEncoder(g.device, &ed);
    WGPUTexelCopyTextureInfo src = WGPU_TEXEL_COPY_TEXTURE_INFO_INIT;
    src.texture = rt.color;
    WGPUTexelCopyBufferInfo dst = WGPU_TEXEL_COPY_BUFFER_INFO_INIT;
    dst.buffer = stage;
    dst.layout.offset = 0;
    dst.layout.bytesPerRow = bpr;
    dst.layout.rowsPerImage = kH;
    WGPUExtent3D ext{kW, kH, 1};
    wgpuCommandEncoderCopyTextureToBuffer(enc, &src, &dst, &ext);
    WGPUCommandBufferDescriptor cbd = WGPU_COMMAND_BUFFER_DESCRIPTOR_INIT;
    WGPUCommandBuffer cb = wgpuCommandEncoderFinish(enc, &cbd);
    wgpuCommandEncoderRelease(enc);
    wgpuQueueSubmit(g.queue, 1, &cb);
    wgpuCommandBufferRelease(cb);

    bool ok = false;
    WGPUBufferMapCallbackInfo mi = WGPU_BUFFER_MAP_CALLBACK_INFO_INIT;
    mi.mode = WGPUCallbackMode_WaitAnyOnly;
    mi.callback = [](WGPUMapAsyncStatus st, WGPUStringView, void* u, void*) {
        *static_cast<bool*>(u) = (st == WGPUMapAsyncStatus_Success);
    };
    mi.userdata1 = &ok;
    WaitFuture(wgpuBufferMapAsync(stage, WGPUMapMode_Read, 0, bytes, mi));
    std::string sha = "map-failed";
    if (ok) {
        const uint8_t* p = static_cast<const uint8_t*>(
            wgpuBufferGetConstMappedRange(stage, 0, bytes));
        if (p) {
            raw->assign(p, p + bytes);
            sha = Sha256Hex(p, (size_t)bytes);
        }
        wgpuBufferUnmap(stage);
    }
    wgpuBufferRelease(stage);
    return sha;
}

}  // namespace

// ─── 入口 ───────────────────────────────────────────────────────────────
// out_dir: 结果 JSON 落盘目录
// K: 每块帧数   R: 轮数   warmup: 每臂预热帧数
extern "C" const char* pwsplat_ab_run(const char* out_dir, int K, int R,
                                      int warmup) {
    static std::string result;
    result.clear();
    std::string err;
    if (!InitGpu(&err)) { result = "init failed: " + err; return result.c_str(); }

    // ─── 格子:N × 半径。小半径 (~1.5 px) 是点云那一档、也是 warp 占用率
    // 论点最该咬人的顶点受限区;大半径 (~4 px) 是高斯那一档,片元受限。
    // shuffle=false ⇒ order[i]=i。生产里 order 是深度排序的置换,所以
    // splats[order[ii]] 是对整个 buffer 的随机读;点云路(§8 第 2 步「删
    // 排序」)之后就是顺序读。同 N 同半径下 shuffled vs sequential 的差,
    // 就是那个 indirection 本身值多少 —— 用来给 instancing 的 6~9% 定位:
    // 它到底是大头还是零头。
    struct Cell { const char* name; uint32_t n; float conic; bool shuffle; };
    const uint32_t kNMax = 4000000;
    // r = 3 / sqrt(conic) ⇒ conic = (3/r)^2
    const float kConicSmall = 4.0f;    // r = 1.5 px
    const float kConicLarge = 0.5625f; // r = 4.0 px
    const Cell cells[] = {
        {"N1M_r1.5",   1000000, kConicSmall, true},
        {"N4M_r1.5",   kNMax,   kConicSmall, true},
    };
    // ⚠️ 热预算是硬约束,格子数 × K × R 不能随便加。实测边界(A16):
    //   5 标签 × R=10 × K=50(≈2500 帧/格)跑 4M ⇒ **机器彻底降频**,五个
    //   标签全漂 +81~100%(109→210 ms),阳性对照 N/2÷N = 0.923(应 ≈0.5)
    //   ⇒ 那一格按规矩整格作废。
    //   冷机 + 5 标签 × R=5 × K=25(≈625 帧/格)⇒ 阳性对照回到 0.513,漂移
    //   −3%~+6%,可用。
    // ⇒ 跑 4M 用 `-PWK 25 -PWR 5`,只跑 1M 才敢上 `-PWK 50 -PWR 10`。
    // ⚠️ R=5 时符号检验 p 下限就是 0.0625(2/2^5),p<0.05 结构上不可达 ⇒
    //    小 R 的判据要换成「全胜 + 全距不跨 1.0 + 远高于噪声底」。

    // ─── 资源 ───────────────────────────────────────────────────────────
    WGPUTextureDescriptor td = WGPU_TEXTURE_DESCRIPTOR_INIT;
    td.dimension = WGPUTextureDimension_2D;
    td.size = WGPUExtent3D{kW, kH, 1};
    td.format = WGPUTextureFormat_RGBA8Unorm;
    td.mipLevelCount = 1;
    td.sampleCount = 1;
    td.usage = (WGPUTextureUsage)(WGPUTextureUsage_RenderAttachment |
                                  WGPUTextureUsage_CopySrc);
    Rt rt;
    rt.color = wgpuDeviceCreateTexture(g.device, &td);
    td.format = WGPUTextureFormat_Depth32Float;
    td.usage = WGPUTextureUsage_RenderAttachment;
    rt.depth = wgpuDeviceCreateTexture(g.device, &td);
    WGPUTextureViewDescriptor vd = WGPU_TEXTURE_VIEW_DESCRIPTOR_INIT;
    rt.color_v = wgpuTextureCreateView(rt.color, &vd);
    rt.depth_v = wgpuTextureCreateView(rt.depth, &vd);

    // 深度只读测试要求纹理里有内容:先清一次成 1.0,之后所有 pass 都只读。
    {
        WGPUCommandEncoderDescriptor ed = WGPU_COMMAND_ENCODER_DESCRIPTOR_INIT;
        WGPUCommandEncoder enc = wgpuDeviceCreateCommandEncoder(g.device, &ed);
        WGPURenderPassDepthStencilAttachment da =
            WGPU_RENDER_PASS_DEPTH_STENCIL_ATTACHMENT_INIT;
        da.view = rt.depth_v;
        da.depthLoadOp = WGPULoadOp_Clear;
        da.depthStoreOp = WGPUStoreOp_Store;
        da.depthClearValue = 1.0f;
        da.depthReadOnly = WGPU_FALSE;
        WGPURenderPassDescriptor pd = WGPU_RENDER_PASS_DESCRIPTOR_INIT;
        pd.colorAttachmentCount = 0;
        pd.depthStencilAttachment = &da;
        WGPURenderPassEncoder p = wgpuCommandEncoderBeginRenderPass(enc, &pd);
        wgpuRenderPassEncoderEnd(p);
        wgpuRenderPassEncoderRelease(p);
        WGPUCommandBufferDescriptor cbd = WGPU_COMMAND_BUFFER_DESCRIPTOR_INIT;
        WGPUCommandBuffer cb = wgpuCommandEncoderFinish(enc, &cbd);
        wgpuCommandEncoderRelease(enc);
        wgpuQueueSubmit(g.queue, 1, &cb);
        wgpuCommandBufferRelease(cb);
    }

    WGPUShaderModule mA = MakeModule(kWgslArmA);
    WGPUShaderModule mB = MakeModule(kWgslArmB);
    WGPURenderPipeline pA = MakePipeline(mA);
    WGPURenderPipeline pB = MakePipeline(mB);
    if (!pA || !pB) {
        result = "pipeline creation failed\n" + g.error_log;
        return result.c_str();
    }

    WGPUBuffer buf_u = MakeBuffer(sizeof(RenderUniforms),
        (WGPUBufferUsage)(WGPUBufferUsage_Storage | WGPUBufferUsage_CopyDst));
    WGPUBuffer buf_s = MakeBuffer((uint64_t)kNMax * sizeof(ProjectedSplat),
        (WGPUBufferUsage)(WGPUBufferUsage_Storage | WGPUBufferUsage_CopyDst));
    WGPUBuffer buf_o = MakeBuffer((uint64_t)kNMax * 4ull,
        (WGPUBufferUsage)(WGPUBufferUsage_Storage | WGPUBufferUsage_CopyDst));
    // 第二个 order buffer = 恒等置换。run3 把「乱序 vs 顺序」放成两个**格子**,
    // 结果顺序格跑在最后、开局就比乱序格末轮高 15%,与累积热漂移同号同量级,
    // 分不开 ⇒ 作废。现在它变成**轮换标签**,与 A/B 一起交替,热漂移在标签
    // 之间平衡。两个 buffer 常驻,切换只换 bind group,不做任何拷贝。
    WGPUBuffer buf_o_seq = MakeBuffer((uint64_t)kNMax * 4ull,
        (WGPUBufferUsage)(WGPUBufferUsage_Storage | WGPUBufferUsage_CopyDst));

    RenderUniforms u{};
    u.img_size[0] = kW; u.img_size[1] = kH;
    u.total_splats = kNMax; u.num_visible = kNMax;
    wgpuQueueWriteBuffer(g.queue, buf_u, 0, &u, sizeof u);

    WGPUBindGroupEntry be[3];
    for (int i = 0; i < 3; ++i) be[i] = WGPU_BIND_GROUP_ENTRY_INIT;
    be[0].binding = 0; be[0].buffer = buf_u; be[0].size = sizeof(RenderUniforms);
    be[1].binding = 1; be[1].buffer = buf_s;
    be[1].size = (uint64_t)kNMax * sizeof(ProjectedSplat);
    be[2].binding = 2; be[2].buffer = buf_o; be[2].size = (uint64_t)kNMax * 4ull;
    WGPUBindGroupDescriptor bgd = WGPU_BIND_GROUP_DESCRIPTOR_INIT;
    bgd.layout = wgpuRenderPipelineGetBindGroupLayout(pA, 0);
    bgd.entryCount = 3;
    bgd.entries = be;
    WGPUBindGroup bgA = wgpuDeviceCreateBindGroup(g.device, &bgd);
    bgd.layout = wgpuRenderPipelineGetBindGroupLayout(pB, 0);
    WGPUBindGroup bgB = wgpuDeviceCreateBindGroup(g.device, &bgd);
    be[2].buffer = buf_o_seq;
    bgd.layout = wgpuRenderPipelineGetBindGroupLayout(pA, 0);
    WGPUBindGroup bgA_seq = wgpuDeviceCreateBindGroup(g.device, &bgd);
    bgd.layout = wgpuRenderPipelineGetBindGroupLayout(pB, 0);
    WGPUBindGroup bgB_seq = wgpuDeviceCreateBindGroup(g.device, &bgd);
    if (!bgA || !bgB || !bgA_seq || !bgB_seq) {
        result = "bind group failed\n" + g.error_log;
        return result.c_str();
    }

    // 时间戳查询集 + resolve/staging。resolve 每帧一个 256 B 格。
    WGPUQuerySet qs = nullptr;
    WGPUBuffer resolve = nullptr, qstage = nullptr;
    const uint32_t kSlots = (uint32_t)std::max(K, 1) + 8u;
    if (g.has_timestamp) {
        WGPUQuerySetDescriptor qd = WGPU_QUERY_SET_DESCRIPTOR_INIT;
        qd.type = WGPUQueryType_Timestamp;
        qd.count = 2;
        qs = wgpuDeviceCreateQuerySet(g.device, &qd);
        resolve = MakeBuffer((uint64_t)kSlots * 256ull,
            (WGPUBufferUsage)(WGPUBufferUsage_QueryResolve |
                              WGPUBufferUsage_CopySrc));
        qstage = MakeBuffer((uint64_t)kSlots * 256ull,
            (WGPUBufferUsage)(WGPUBufferUsage_MapRead |
                              WGPUBufferUsage_CopyDst));
    }

    // ─── JSON 头 ────────────────────────────────────────────────────────
    std::string j = "{\n";
    j += "  \"bench\": \"pw_splat_ab\",\n";
    j += "  \"date\": \"2026-09-23\",\n";
    j += "  \"adapter\": \"" + g.adapter_name + "\",\n";
    j += "  \"width\": " + std::to_string(kW) +
         ", \"height\": " + std::to_string(kH) + ",\n";
    j += "  \"timestamp_query\": " + std::string(g.has_timestamp ? "true" : "false") + ",\n";
    j += "  \"armA_wgsl_sha256\": \"" + std::string(kShaA) + "\",\n";
    j += "  \"armB_wgsl_sha256\": \"" + std::string(kShaB) + "\",\n";
    j += "  \"K\": " + std::to_string(K) + ", \"R\": " + std::to_string(R) +
         ", \"warmup\": " + std::to_string(warmup) + ",\n";
    j += "  \"cells\": [\n";

    std::mt19937 rng(20260923u);

    // 一块 = K 帧同一臂。arm: 0 = A(instanced), 1 = B(expanded)。
    // 2×2 析因 + 噪声底,五个标签:
    //   0 = A_shuf (instancing, 乱序 order)   ← 生产现状
    //   1 = B_shuf (顶点展开,  乱序 order)   ← 本次改动
    //   2 = A'_shuf(instancing, 乱序 order)   ← 噪声底:与 0 完全相同
    //   3 = A_seq  (instancing, 顺序 order)   ← 删排序之后的访存模式
    //   4 = B_seq  (顶点展开,  顺序 order)
    // 由此:0vs1 = draw 拓扑;0vs3 / 1vs4 = 排序 indirection;0vs2 = 噪声底。
    // 五个标签在轮内循环轮换 ⇒ 热漂移在**所有**对比上平衡,不只 A/B。
    static const char* kLabelName[5] =
        {"A_shuf", "B_shuf", "A2_shuf", "A_seq", "B_seq"};
    auto run_block = [&](int label, uint32_t n, std::vector<double>* wall,
                         std::vector<double>* gpu) {
        const bool expanded = (label == 1 || label == 4);
        const bool seq      = (label == 3 || label == 4);
        WGPURenderPipeline pipe = expanded ? pB : pA;
        WGPUBindGroup bg = expanded ? (seq ? bgB_seq : bgB)
                                    : (seq ? bgA_seq : bgA);
        const uint32_t vc = expanded ? 6u * n : 6u;
        const uint32_t ic = expanded ? 1u : n;
        for (int f = 0; f < K; ++f)
            wall->push_back(RenderOneFrame(rt, pipe, bg, vc, ic, qs, resolve,
                                           (uint32_t)f));
        if (qs) {
            auto v = ReadGpuNs(resolve, qstage, (uint32_t)K);
            gpu->insert(gpu->end(), v.begin(), v.end());
        }
    };

    bool first_cell = true;
    std::string correctness_json;

    for (const Cell& c : cells) {
        // ── 同一份数据:位置均匀铺满屏幕,conic 由格子定,order 是 [0,n)
        // 的一个乱序(生产里 order 是深度排序的置换 ⇒ 对 splats[] 是散
        // 访问,这里照做,否则会把访存模式测成顺序的)。
        {
            // 每格重置种子:同 N 的格子因此拿到**逐点完全相同**的位置。
            // 没有这一句,N4M_r1.5 与 N4M_r1.5_seq 会是同分布的两批不同点,
            // 「顺序 vs 乱序」就不是干净的单变量(4M 样本下抽样噪声约
            // 0.05%,可忽略,但没必要留这个口子)。
            rng.seed(20260923u);
            std::vector<ProjectedSplat> sp(c.n);
            std::uniform_real_distribution<float> ux(0.f, (float)kW);
            std::uniform_real_distribution<float> uy(0.f, (float)kH);
            for (uint32_t i = 0; i < c.n; ++i) {
                sp[i] = {ux(rng), uy(rng), c.conic, 0.f, c.conic,
                         0.6f, 0.55f, 0.5f, 0.5f};
            }
            std::vector<uint32_t> ord(c.n);
            for (uint32_t i = 0; i < c.n; ++i) ord[i] = i;
            // buf_o_seq 先拿恒等置换,再把同一块内存洗乱写进 buf_o。
            {
                const uint8_t* q = reinterpret_cast<const uint8_t*>(ord.data());
                size_t tot = ord.size() * 4, o = 0;
                while (o < tot) {
                    size_t nb = std::min((size_t)(16u << 20), tot - o);
                    wgpuQueueWriteBuffer(g.queue, buf_o_seq, o, q + o, nb);
                    o += nb;
                }
            }
            std::shuffle(ord.begin(), ord.end(), rng);
            // WriteBuffer 一次最多 ~unbounded,但分块写更稳。
            const size_t chunk = 16u << 20;  // 16 MB
            const uint8_t* p = reinterpret_cast<const uint8_t*>(sp.data());
            size_t total = sp.size() * sizeof(ProjectedSplat), off = 0;
            while (off < total) {
                size_t nb = std::min(chunk, total - off);
                wgpuQueueWriteBuffer(g.queue, buf_s, off, p + off, nb);
                off += nb;
            }
            p = reinterpret_cast<const uint8_t*>(ord.data());
            total = ord.size() * 4; off = 0;
            while (off < total) {
                size_t nb = std::min(chunk, total - off);
                wgpuQueueWriteBuffer(g.queue, buf_o, off, p + off, nb);
                off += nb;
            }
        }

        // ── 预热(不计数):让两条 pipeline 都编译完、缓存都热起来。
        {
            for (int lbl = 0; lbl < 5; ++lbl) {
                const bool ex = (lbl == 1 || lbl == 4);
                const bool sq = (lbl == 3 || lbl == 4);
                WGPURenderPipeline pipe = ex ? pB : pA;
                WGPUBindGroup bg = ex ? (sq ? bgB_seq : bgB)
                                      : (sq ? bgA_seq : bgA);
                const uint32_t vc = ex ? 6u * c.n : 6u;
                const uint32_t ic = ex ? 1u : c.n;
                for (int f = 0; f < warmup; ++f)
                    RenderOneFrame(rt, pipe, bg, vc, ic, nullptr, nullptr, 0);
            }
        }

        // ── 交替分块:三个标签(A / B / A′)按轮号循环轮换次序,
        //    R = 9 时每个标签在首/中/末位各 3 次 ⇒ 块内位置效应(热漂移、
        //    缓存预热)在标签之间完全平衡。
        std::vector<double> w[5], gv[5];
        std::vector<double> round_p50[5];   // 每轮中位数,轮 = 重复单位
        std::vector<double> round_gpu_p50[5];
        for (int r = 0; r < R; ++r) {
            std::vector<double> rw[5], rg[5];
            // 循环轮换三块的次序:R = 9 时每个标签在首/中/末位各 3 次,
            // 块内位置效应(热漂移、缓存预热)在标签之间完全平衡。
            for (int pos = 0; pos < 5; ++pos) {
                const int label = (pos + r) % 5;
                run_block(label, c.n, &rw[label], &rg[label]);
            }
            for (int L = 0; L < 5; ++L) {
                round_p50[L].push_back(Summarize(rw[L]).p50);
                round_gpu_p50[L].push_back(Summarize(rg[L]).p50);
                w[L].insert(w[L].end(), rw[L].begin(), rw[L].end());
                gv[L].insert(gv[L].end(), rg[L].begin(), rg[L].end());
            }
        }
        std::vector<double>&wA=w[0], &wB=w[1], &wA2=w[2];
        std::vector<double>&gA=gv[0], &gB=gv[1], &gA2=gv[2];

        // ── 阳性对照:同一把尺子量 arm A 在 N/2 上。必须明显更快,
        //    否则这把尺子量不出任何东西,零结果不可信。
        std::vector<double> wHalf, gHalf;
        run_block(0, c.n / 2, &wHalf, &gHalf);

        char rb[256];
        auto series = [&](const std::vector<double>& v) {
            std::string o = "[";
            for (size_t i = 0; i < v.size(); ++i) {
                std::snprintf(rb, sizeof rb, "%s%.4f", i ? "," : "", v[i]);
                o += rb;
            }
            return o + "]";
        };

        if (!first_cell) j += ",\n";
        first_cell = false;
        j += "    {\n";
        j += "      \"cell\": \"" + std::string(c.name) + "\",\n";
        j += "      \"n\": " + std::to_string(c.n) + ",\n";
        char cb2[64]; std::snprintf(cb2, sizeof cb2, "%.4f", 3.0 / std::sqrt((double)c.conic));
        j += "      \"quad_radius_px\": " + std::string(cb2) + ",\n";

        for (int L = 0; L < 5; ++L) {
            j += std::string("      \"") + kLabelName[L] + "_wall_ms\": " +
                 StatsJson(Summarize(w[L])) + ",\n";
            j += std::string("      \"") + kLabelName[L] + "_gpu_ms\": " +
                 StatsJson(Summarize(gv[L])) + ",\n";
        }
        // 兼容旧判读脚本的别名
        j += "      \"A_instanced_gpu_ms\": " + StatsJson(Summarize(gA)) + ",\n";
        j += "      \"B_expanded_gpu_ms\": " + StatsJson(Summarize(gB)) + ",\n";
        j += "      \"A2_instanced_gpu_ms\": " + StatsJson(Summarize(gA2)) + ",\n";
        j += "      \"A_instanced_wall_ms\": " + StatsJson(Summarize(wA)) + ",\n";
        j += "      \"B_expanded_wall_ms\": " + StatsJson(Summarize(wB)) + ",\n";
        j += "      \"positive_control_A_halfN_wall_ms\": " +
             StatsJson(Summarize(wHalf)) + ",\n";
        j += "      \"positive_control_A_halfN_gpu_ms\": " +
             StatsJson(Summarize(gHalf)) + ",\n";
        for (int L = 0; L < 5; ++L) {
            j += std::string("      \"round_gpu_p50_") + kLabelName[L] + "\": " +
                 series(round_gpu_p50[L]) + ",\n";
            j += std::string("      \"round_wall_p50_") + kLabelName[L] + "\": " +
                 series(round_p50[L]) + ",\n";
        }
        j += "      \"round_gpu_p50_A\": "  + series(round_gpu_p50[0]) + ",\n";
        j += "      \"round_gpu_p50_B\": "  + series(round_gpu_p50[1]) + ",\n";
        j += "      \"round_gpu_p50_A2\": " + series(round_gpu_p50[2]) + ",\n";
        j += "      \"round_wall_p50_A\": " + series(round_p50[0]) + ",\n";
        j += "      \"round_wall_p50_B\": " + series(round_p50[1]) + "\n";
        j += "    }";
    }
    j += "\n  ],\n";

    // ─── 正确性对照:两臂帧缓冲必须逐字节相同 ──────────────────────────
    {
        const uint32_t n = 1000000;
        std::vector<uint8_t> ra, rbb;
        RenderOneFrame(rt, pA, bgA, 6u, n, nullptr, nullptr, 0);
        std::string sa = ReadbackSha(rt, &ra);
        RenderOneFrame(rt, pB, bgB, 6u * n, 1u, nullptr, nullptr, 0);
        std::string sb = ReadbackSha(rt, &rbb);
        uint64_t diff_px = 0; int max_abs = 0;
        if (ra.size() == rbb.size()) {
            for (size_t i = 0; i < ra.size(); ++i) {
                int d = std::abs((int)ra[i] - (int)rbb[i]);
                if (d) { ++diff_px; max_abs = std::max(max_abs, d); }
            }
        }
        j += "  \"correctness\": {\"n\": " + std::to_string(n) +
             ", \"A_sha256\": \"" + sa + "\", \"B_sha256\": \"" + sb +
             "\", \"identical\": " + (sa == sb ? "true" : "false") +
             ", \"differing_bytes\": " + std::to_string(diff_px) +
             ", \"max_abs_diff\": " + std::to_string(max_abs) + "},\n";
    }

    j += "  \"wgpu_errors\": \"" + g.error_log.substr(0, 2000) + "\"\n";
    j += "}\n";

    NSString* dir = [NSString stringWithUTF8String:out_dir];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                             withIntermediateDirectories:YES
                                              attributes:nil
                                                   error:nil];
    NSString* path = [dir stringByAppendingPathComponent:@"splat_ab.json"];
    [[NSString stringWithUTF8String:j.c_str()]
        writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    result = std::string([path UTF8String]);
    return result.c_str();
}
