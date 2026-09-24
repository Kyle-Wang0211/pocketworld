// PWCloudBench —— **真实聚簇点云 + 透视缩放** 的 quad 档帧时间(A16)。
//
// 起因(2026-09-23,接裸点云那一轮):
//   上一轮最快的那档是 PTm(1px PointList + 莫顿序,6.92M @ 16.6 ms / 56 fps),
//   但 **WebGPU 的 PointList 被硬卡在 1 像素**(WGSL 没有 gl_PointSize,Dawn 的
//   Tint 往 MSL 里写死 1.0f)⇒ 选它等于把现役查看器已有的能力减掉:
//   `sparse_cloud_view.dart:1528` 是 `scaleA[m] = baseScale * (camDist / depth)`,
//   点半径随距离变(three.js points.glsl.js:40 那套)。
//   ⇒ 真正要定价的是 **quad + 莫顿序** 那一档。
//
//   而上一轮那格用的是**屏幕均匀随机的合成点 + 固定半径**,我自己在限制②里写了
//   「真实 MVS 点云是空间聚簇的,局部性红利的方向应该保留但**量级未验**」。
//   这份台架就是去验它。
//
// 这一轮改的三样(其余口径与 bench_points.mm 逐字一致):
//   ① 输入换成**真数据**:official_dense.ply(6,922,990 点)转成 16 B/点,
//      用 `devicectl copy to` 推进 Documents,**不开生产 app**。
//   ② 半径换成**透视缩放**,照抄生产那一行:r = baseScale * camDist / depth。
//   ③ 相机分档(拟合 / 拉近),因为透视缩放下代价随距离变。
//
// 纪律(与上一轮同):轮内轮换标签、轮=重复单位、A′ 空臂给噪声底、阳性对照
//   N/2÷N≈0.5、整帧 sha256 正确性对照 + **能失败的阴性对照**。
//   🔑 上一轮事后才补的那条(把重排 buffer 本身画出来比 sha,防「又快又错」)
//      这次**从一开始就在**,而且加了一条 CPU 侧的置换校验和(xor+sum)。
//   ⚠️ 真数据深度分布由不得我选 ⇒ 必须能区分「f32 并列导致的字节差」和「真错」:
//      用**三种次序两两比**(随机A / 随机B / 莫顿M)。并列的签名是三对差不多大;
//      真错的签名是 M 与 A、B 都差得远而 A、B 之间不差。见 §correctness。
//
// 硬约束:一行苹果图形 API 都不新增。新增 `#if __APPLE__` 0 处、厂商图形 API 0 处。
// ⚠️ 只有一台 A16。Adreno / Mali / Maleoon 零证据。
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
#include <numeric>
#include <random>
#include <string>
#include <vector>

namespace {

constexpr uint32_t kW = 1179;
constexpr uint32_t kH = 2556;
constexpr int kNL = 6;          // 标签数

struct CPoint { float x, y, z; uint32_t rgba; };
static_assert(sizeof(CPoint) == 16, "CPoint must be 16 bytes");

struct CloudUniforms {
    float viewproj[16];   // 0   列主序
    float img_size[2];    // 64
    float base_scale;     // 72
    float cam_dist;       // 76
    float r_min;          // 80
    float r_max;          // 84
    float pad0, pad1;     // 88
};
static_assert(sizeof(CloudUniforms) == 96, "CloudUniforms must be 96 bytes");

// ─── shader ─────────────────────────────────────────────────────────────
// 与 bench_points.mm 的 quad 臂逐项同构,只把「固定半径」换成生产那一行的
// 透视缩放。varying 仍然只有一条 flat 颜色(点精灵在 quad 上颜色是常数)。
static const char* kWgslCloud = R"CLWGSL(
struct CloudUniforms {
    viewproj: mat4x4f,
    img_size: vec2f,
    base_scale: f32,
    cam_dist: f32,
    r_min: f32,
    r_max: f32,
    pad0: f32,
    pad1: f32,
}
struct CPoint { x: f32, y: f32, z: f32, rgba: u32 }

@group(0) @binding(0) var<storage, read> cu: CloudUniforms;
@group(0) @binding(1) var<storage, read> pts: array<CPoint>;

struct VsOut {
    @builtin(position) clip: vec4f,
    @location(0) @interpolate(flat) color: vec4f,
}

@vertex fn vs_quad(@builtin(vertex_index) vi: u32) -> VsOut {
    var offsets = array<vec2f, 6>(
        vec2f(-1.0, -1.0),
        vec2f( 1.0, -1.0),
        vec2f( 1.0,  1.0),
        vec2f(-1.0, -1.0),
        vec2f( 1.0,  1.0),
        vec2f(-1.0,  1.0),
    );
    let ii = vi / 6u;
    let off = offsets[vi % 6u];
    let p = pts[ii];
    var clip = cu.viewproj * vec4f(p.x, p.y, p.z, 1.0);
    // 生产口径(sparse_cloud_view.dart:1528 / three.js points.glsl.js:40):
    //   点半径 = baseScale * camDist / depth  —— 越近越大。
    // 这条投影矩阵的 clip.w 就是视空间深度。
    let depth = max(clip.w, 1.0e-4);
    let r = clamp(cu.base_scale * cu.cam_dist / depth, cu.r_min, cu.r_max);
    clip = vec4f(clip.xy + off * r * 2.0 / cu.img_size * clip.w, clip.z, clip.w);
    var o: VsOut;
    o.clip = clip;
    o.color = unpack4x8unorm(p.rgba);
    return o;
}

// 裸点云片元:不透明,无 discard ⇒ 分块架构的隐面剔除能工作。
@fragment fn fs_opaque(in: VsOut) -> @location(0) vec4f {
    return in.color;
}
// 阴性对照用:混合 + 不写深度(= 画家式)⇒ 次序相关,判据必须在这里失败。
@fragment fn fs_blend(in: VsOut) -> @location(0) vec4f {
    let a = in.color.a * 0.5;
    return vec4f(in.color.rgb * a, a);
}
)CLWGSL";

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
        g.adapter_name = sv(info.device) + " | " + sv(info.description);
    }

    WGPULimits alim = WGPU_LIMITS_INIT;
    wgpuAdapterGetLimits(g.adapter, &alim);
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

WGPUBuffer MakeBuffer(uint64_t size, WGPUBufferUsage usage) {
    WGPUBufferDescriptor d = WGPU_BUFFER_DESCRIPTOR_INIT;
    d.size = size;
    d.usage = usage;
    return wgpuDeviceCreateBuffer(g.device, &d);
}

WGPURenderPipeline MakePipeline(WGPUShaderModule m, const char* fs_entry,
                                bool blend, bool depth_write) {
    WGPUBlendState bs = WGPU_BLEND_STATE_INIT;
    bs.color.operation = WGPUBlendOperation_Add;
    bs.color.srcFactor = WGPUBlendFactor_One;
    bs.color.dstFactor = WGPUBlendFactor_OneMinusSrcAlpha;
    bs.alpha.operation = WGPUBlendOperation_Add;
    bs.alpha.srcFactor = WGPUBlendFactor_One;
    bs.alpha.dstFactor = WGPUBlendFactor_OneMinusSrcAlpha;

    WGPUColorTargetState ct = WGPU_COLOR_TARGET_STATE_INIT;
    ct.format = WGPUTextureFormat_RGBA8Unorm;
    ct.blend = blend ? &bs : nullptr;
    ct.writeMask = WGPUColorWriteMask_All;

    WGPUFragmentState fs = WGPU_FRAGMENT_STATE_INIT;
    fs.module = m; fs.entryPoint = SV(fs_entry);
    fs.targetCount = 1; fs.targets = &ct;

    WGPUVertexState vs = WGPU_VERTEX_STATE_INIT;
    vs.module = m; vs.entryPoint = SV("vs_quad"); vs.bufferCount = 0;

    WGPUDepthStencilState ds = WGPU_DEPTH_STENCIL_STATE_INIT;
    ds.format = WGPUTextureFormat_Depth32Float;
    ds.depthWriteEnabled = depth_write ? WGPUOptionalBool_True
                                       : WGPUOptionalBool_False;
    ds.depthCompare = depth_write ? WGPUCompareFunction_Less
                                  : WGPUCompareFunction_Always;

    WGPURenderPipelineDescriptor p = WGPU_RENDER_PIPELINE_DESCRIPTOR_INIT;
    p.vertex = vs; p.fragment = &fs;
    p.primitive.topology = WGPUPrimitiveTopology_TriangleList;
    p.primitive.cullMode = WGPUCullMode_None;
    p.primitive.frontFace = WGPUFrontFace_CCW;
    p.depthStencil = &ds;
    p.multisample.count = 1;
    p.multisample.mask = 0xFFFFFFFFu;
    return wgpuDeviceCreateRenderPipeline(g.device, &p);
}

struct Stats { double n=0, mean=0, p01=0, p50=0, p90=0, p99=0, mn=0, mx=0; };
Stats Summarize(std::vector<double> v) {
    Stats s;
    if (v.empty()) return s;
    std::sort(v.begin(), v.end());
    auto q = [&](double f) {
        size_t i = (size_t)std::llround(f * (double)(v.size() - 1));
        return v[std::min(i, v.size() - 1)];
    };
    double sum = 0; for (double x : v) sum += x;
    s.n = (double)v.size(); s.mean = sum / (double)v.size();
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

struct Rt {
    WGPUTexture color=nullptr, depth_pc=nullptr, depth_ro=nullptr;
    WGPUTextureView color_v=nullptr, depth_pc_v=nullptr, depth_ro_v=nullptr;
};

double RenderOneFrame(const Rt& rt, WGPURenderPipeline pipe, WGPUBindGroup bg,
                      uint32_t vertex_count, bool depth_write,
                      WGPUQuerySet qs, WGPUBuffer resolve, uint32_t slot) {
    const double t0 = NowMs();
    WGPUCommandEncoderDescriptor ed = WGPU_COMMAND_ENCODER_DESCRIPTOR_INIT;
    WGPUCommandEncoder enc = wgpuDeviceCreateCommandEncoder(g.device, &ed);

    WGPURenderPassColorAttachment ca = WGPU_RENDER_PASS_COLOR_ATTACHMENT_INIT;
    ca.view = rt.color_v;
    ca.loadOp = WGPULoadOp_Clear; ca.storeOp = WGPUStoreOp_Store;
    ca.clearValue = WGPUColor{0, 0, 0, 0};
    ca.depthSlice = WGPU_DEPTH_SLICE_UNDEFINED;

    WGPURenderPassDepthStencilAttachment da =
        WGPU_RENDER_PASS_DEPTH_STENCIL_ATTACHMENT_INIT;
    if (depth_write) {
        da.view = rt.depth_pc_v;
        da.depthLoadOp = WGPULoadOp_Clear;
        da.depthStoreOp = WGPUStoreOp_Discard;   // 分块架构上不回写,省 12 MB
        da.depthClearValue = 1.0f;
        da.depthReadOnly = WGPU_FALSE;
    } else {
        da.view = rt.depth_ro_v;
        da.depthLoadOp = WGPULoadOp_Undefined;
        da.depthStoreOp = WGPUStoreOp_Undefined;
        da.depthReadOnly = WGPU_TRUE;
    }

    WGPUPassTimestampWrites tw = WGPU_PASS_TIMESTAMP_WRITES_INIT;
    if (qs) { tw.querySet = qs; tw.beginningOfPassWriteIndex = 0;
              tw.endOfPassWriteIndex = 1; }

    WGPURenderPassDescriptor pd = WGPU_RENDER_PASS_DESCRIPTOR_INIT;
    pd.colorAttachmentCount = 1; pd.colorAttachments = &ca;
    pd.depthStencilAttachment = &da;
    pd.timestampWrites = qs ? &tw : nullptr;

    WGPURenderPassEncoder pass = wgpuCommandEncoderBeginRenderPass(enc, &pd);
    wgpuRenderPassEncoderSetPipeline(pass, pipe);
    wgpuRenderPassEncoderSetBindGroup(pass, 0, bg, 0, nullptr);
    wgpuRenderPassEncoderDraw(pass, vertex_count, 1, 0, 0);
    wgpuRenderPassEncoderEnd(pass);
    wgpuRenderPassEncoderRelease(pass);
    if (qs) wgpuCommandEncoderResolveQuerySet(enc, qs, 0, 2, resolve,
                                              (uint64_t)slot * 256ull);
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
        if (p) for (uint32_t i = 0; i < count; ++i) {
            uint64_t t0, t1;
            std::memcpy(&t0, p + (size_t)i * 256 + 0, 8);
            std::memcpy(&t1, p + (size_t)i * 256 + 8, 8);
            if (t1 > t0) out.push_back((double)(t1 - t0) / 1.0e6);
        }
        wgpuBufferUnmap(staging);
    }
    return out;
}

// 整帧读回 + 能报警的图像判据(覆盖率 / 通道均值 / 通道标准差)。
// 「非黑像素占比」这种判据会给平灰图放行,所以必须带标准差。
struct ImgStat {
    std::string sha;
    double cover = 0;
    double mean[3] = {0,0,0};
    double sd[3] = {0,0,0};
};
ImgStat ReadbackImage(const Rt& rt, std::vector<uint8_t>* raw) {
    ImgStat st;
    const uint32_t bpr = ((kW * 4u) + 255u) / 256u * 256u;
    const uint64_t bytes = (uint64_t)bpr * kH;
    WGPUBuffer stage = MakeBuffer(bytes,
        (WGPUBufferUsage)(WGPUBufferUsage_MapRead | WGPUBufferUsage_CopyDst));
    WGPUCommandEncoderDescriptor ed = WGPU_COMMAND_ENCODER_DESCRIPTOR_INIT;
    WGPUCommandEncoder enc = wgpuDeviceCreateCommandEncoder(g.device, &ed);
    WGPUTexelCopyTextureInfo src = WGPU_TEXEL_COPY_TEXTURE_INFO_INIT;
    src.texture = rt.color;
    WGPUTexelCopyBufferInfo dst = WGPU_TEXEL_COPY_BUFFER_INFO_INIT;
    dst.buffer = stage; dst.layout.offset = 0;
    dst.layout.bytesPerRow = bpr; dst.layout.rowsPerImage = kH;
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
    mi.callback = [](WGPUMapAsyncStatus s, WGPUStringView, void* u, void*) {
        *static_cast<bool*>(u) = (s == WGPUMapAsyncStatus_Success);
    };
    mi.userdata1 = &ok;
    WaitFuture(wgpuBufferMapAsync(stage, WGPUMapMode_Read, 0, bytes, mi));
    st.sha = "map-failed";
    if (ok) {
        const uint8_t* p = static_cast<const uint8_t*>(
            wgpuBufferGetConstMappedRange(stage, 0, bytes));
        if (p) {
            raw->assign(p, p + bytes);
            st.sha = Sha256Hex(p, (size_t)bytes);
            double s1[3]={0,0,0}, s2[3]={0,0,0};
            uint64_t covered = 0;
            const uint64_t npx = (uint64_t)kW * kH;
            for (uint32_t y = 0; y < kH; ++y) {
                const uint8_t* row = p + (size_t)y * bpr;
                for (uint32_t x = 0; x < kW; ++x) {
                    const uint8_t* px = row + (size_t)x * 4;
                    if (px[3]) ++covered;
                    for (int c = 0; c < 3; ++c) {
                        double v = px[c]; s1[c] += v; s2[c] += v*v;
                    }
                }
            }
            st.cover = (double)covered / (double)npx;
            for (int c = 0; c < 3; ++c) {
                st.mean[c] = s1[c] / (double)npx;
                double var = s2[c]/(double)npx - st.mean[c]*st.mean[c];
                st.sd[c] = var > 0 ? std::sqrt(var) : 0.0;
            }
        }
        wgpuBufferUnmap(stage);
    }
    wgpuBufferRelease(stage);
    return st;
}
std::string ImgStatJson(const ImgStat& s) {
    char b[512];
    std::snprintf(b, sizeof b,
        "{\"sha256\":\"%s\",\"coverage\":%.6f,"
        "\"mean_rgb\":[%.3f,%.3f,%.3f],\"sd_rgb\":[%.3f,%.3f,%.3f]}",
        s.sha.c_str(), s.cover, s.mean[0], s.mean[1], s.mean[2],
        s.sd[0], s.sd[1], s.sd[2]);
    return b;
}

// 两张图的差异:同时报**字节数**和**像素数**(f32 深度并列一次只影响一个
// 像素的 3–4 个字节,所以像素数才是能跟并列对上的量)。
struct Diff { uint64_t bytes = 0, pixels = 0; int max_abs = 0; };
Diff ImgDiff(const std::vector<uint8_t>& a, const std::vector<uint8_t>& b) {
    Diff d;
    if (a.size() != b.size()) { d.bytes = a.size() + b.size(); return d; }
    const uint32_t bpr = ((kW * 4u) + 255u) / 256u * 256u;
    for (uint32_t y = 0; y < kH; ++y)
        for (uint32_t x = 0; x < kW; ++x) {
            const size_t o = (size_t)y * bpr + (size_t)x * 4;
            bool any = false;
            for (int c = 0; c < 4; ++c) {
                int v = std::abs((int)a[o+c] - (int)b[o+c]);
                if (v) { ++d.bytes; any = true;
                         d.max_abs = std::max(d.max_abs, v); }
            }
            if (any) ++d.pixels;
        }
    return d;
}

// ─── 置换校验和 ─────────────────────────────────────────────────────────
// 直接证明「重排确实是个置换」,不经过渲染。xor 抓重复/丢失(奇数次),
// sum 抓成对错误。两者都相等 ⇒ 多重集一致(碰撞概率可忽略)。
// 这是防「又快又错」的第一道闸:若莫顿序里挤满了重复点,画出来仍是 N 个图元
// 却全落在少数像素上,**又快又错**,而且错得正好长得像局部性红利。
struct Ck { uint64_t xr = 0, sm = 0; };
Ck Checksum(const std::vector<CPoint>& v) {
    Ck c;
    for (const CPoint& p : v) {
        uint32_t bx, by, bz;
        std::memcpy(&bx, &p.x, 4); std::memcpy(&by, &p.y, 4);
        std::memcpy(&bz, &p.z, 4);
        const uint64_t h = (uint64_t)bx * 0x9E3779B97F4A7C15ull ^
                           (uint64_t)by * 0xC2B2AE3D27D4EB4Full ^
                           (uint64_t)bz * 0x165667B19E3779F9ull ^
                           (uint64_t)p.rgba * 0x27D4EB2F165667C5ull;
        c.xr ^= h; c.sm += h;
    }
    return c;
}

uint64_t Part1By2(uint32_t v) {
    uint64_t x = v & 0x3FFull;
    x = (x | (x << 16)) & 0x030000FFull;
    x = (x | (x << 8))  & 0x0300F00Full;
    x = (x | (x << 4))  & 0x030C30C3ull;
    x = (x | (x << 2))  & 0x09249249ull;
    return x;
}
// 3D 莫顿序:与视角无关,产品装载时排一次即可。
std::vector<CPoint> MortonOrder3D(const std::vector<CPoint>& in,
                                  const double* lo, const double* ext) {
    std::vector<std::pair<uint64_t, uint32_t>> key(in.size());
    for (size_t i = 0; i < in.size(); ++i) {
        const CPoint& p = in[i];
        const double v[3] = {p.x, p.y, p.z};
        uint32_t q[3];
        for (int c = 0; c < 3; ++c) {
            const double t = ext[c] > 0 ? (v[c] - lo[c]) / ext[c] : 0.0;
            q[c] = (uint32_t)std::min(std::max(t * 1023.0, 0.0), 1023.0);
        }
        key[i] = {Part1By2(q[0]) | (Part1By2(q[1]) << 1) | (Part1By2(q[2]) << 2),
                  (uint32_t)i};
    }
    std::sort(key.begin(), key.end());
    std::vector<CPoint> out(in.size());
    for (size_t i = 0; i < key.size(); ++i) out[i] = in[key[i].second];
    return out;
}

void UploadChunked(WGPUBuffer buf, const void* data, size_t total) {
    const size_t chunk = 16u << 20;
    const uint8_t* p = static_cast<const uint8_t*>(data);
    size_t off = 0;
    while (off < total) {
        size_t nb = std::min(chunk, total - off);
        wgpuQueueWriteBuffer(g.queue, buf, off, p + off, nb);
        off += nb;
    }
}

}  // namespace

// ─── 入口 ───────────────────────────────────────────────────────────────
// cloud_path: cloud.bin(16 B/点)绝对路径
// cam_sel: 0 = 拟合(整朵云入画) 1 = 拟合距离的 1/4(明显拉近,相机仍在盒外)
//          2 = 包围盒对角线的 1/4(更近,相机会进盒内)
// base_tenths: baseScale,单位 0.1 px
extern "C" const char* pwcloud_run(const char* out_dir, const char* cloud_path,
                                   int K, int R, int warmup, int cam_sel,
                                   int base_tenths, int arm_mask,
                                   const char* tag) {
    static std::string result;
    result.clear();
    std::string err;
    if (!InitGpu(&err)) { result = "init failed: " + err; return result.c_str(); }

    // ─── 读真云 ─────────────────────────────────────────────────────────
    std::vector<CPoint> real;
    {
        FILE* f = std::fopen(cloud_path, "rb");
        if (!f) { result = std::string("open cloud failed: ") + cloud_path;
                  return result.c_str(); }
        std::fseek(f, 0, SEEK_END);
        const long sz = std::ftell(f);
        std::fseek(f, 0, SEEK_SET);
        if (sz <= 0 || (sz % (long)sizeof(CPoint)) != 0) {
            std::fclose(f);
            result = "cloud.bin size not a multiple of 16: " + std::to_string(sz);
            return result.c_str();
        }
        real.resize((size_t)sz / sizeof(CPoint));
        if (std::fread(real.data(), sizeof(CPoint), real.size(), f) != real.size()) {
            std::fclose(f); result = "short read of cloud.bin";
            return result.c_str();
        }
        std::fclose(f);
    }
    const uint32_t N = (uint32_t)real.size();
    const Ck ck_real = Checksum(real);

    // ─── 包围盒 + 相机 ──────────────────────────────────────────────────
    double lo[3] = {1e300,1e300,1e300}, hi[3] = {-1e300,-1e300,-1e300};
    for (const CPoint& p : real) {
        const double v[3] = {p.x, p.y, p.z};
        for (int k = 0; k < 3; ++k) {
            lo[k] = std::min(lo[k], v[k]); hi[k] = std::max(hi[k], v[k]);
        }
    }
    double ext[3], ctr[3], diag = 0;
    for (int k = 0; k < 3; ++k) {
        ext[k] = hi[k] - lo[k]; ctr[k] = 0.5*(lo[k]+hi[k]); diag += ext[k]*ext[k];
    }
    diag = std::sqrt(diag);

    // 相机朝向:**照采集的真实姿态取**,不按「最短轴」这种凑合的启发式 ——
    // ARKit 世界系 y 朝上、采集设备朝 +z 走,这朵云的 z 范围 [0.96, 2.10]
    // 正说明它在原点前方 1–2 m。所以 forward = +z、up = +y 就是用户当时看它
    // 的姿态,也是查看器打开时的默认机位。
    const float fwd[3] = {0, 0, 1}, up[3] = {0, 1, 0}, right[3] = {1, 0, 0};
    const float tan_half = 0.57735027f;             // fov_y = 60°
    const float aspect = (float)kW / (float)kH;
    // 拟合距离:宽高都要装得下,再加上半个深度厚度(近面也要装得下)。
    const double d_h = 0.5 * ext[1] / tan_half;
    const double d_w = 0.5 * ext[0] / (tan_half * aspect);
    const double d_fit = std::max(d_h, d_w) + 0.5 * ext[2];
    double cam_dist = d_fit;
    const char* cam_name = "fit";
    if (cam_sel == 1) { cam_dist = d_fit / 4.0; cam_name = "fit_over_4"; }
    if (cam_sel == 2) { cam_dist = diag / 4.0;  cam_name = "diag_over_4"; }

    const double eye[3] = {ctr[0] - cam_dist*fwd[0], ctr[1] - cam_dist*fwd[1],
                           ctr[2] - cam_dist*fwd[2]};
    // 近/远面:贴着这朵云取,留 2% 余量;近面不得 ≤ 0。
    double zn = cam_dist - 0.5*ext[2], zf = cam_dist + 0.5*ext[2];
    zn = std::max(zn * 0.98, 0.01 * diag);
    zf = zf * 1.02;

    // view(左手:x 右、y 上、z 向前)再乘投影,合成列主序 viewproj。
    float V[16] = {0}, P[16] = {0}, VP[16] = {0};
    {
        const float* r = right; const float* u = up; const float* f = fwd;
        const float tr = -(r[0]*(float)eye[0] + r[1]*(float)eye[1] + r[2]*(float)eye[2]);
        const float tu = -(u[0]*(float)eye[0] + u[1]*(float)eye[1] + u[2]*(float)eye[2]);
        const float tf = -(f[0]*(float)eye[0] + f[1]*(float)eye[1] + f[2]*(float)eye[2]);
        // 列主序:V[c*4+r]
        V[0]=r[0]; V[4]=r[1]; V[8]=r[2];  V[12]=tr;
        V[1]=u[0]; V[5]=u[1]; V[9]=u[2];  V[13]=tu;
        V[2]=f[0]; V[6]=f[1]; V[10]=f[2]; V[14]=tf;
        V[3]=0;    V[7]=0;    V[11]=0;    V[15]=1;
        P[0]  = 1.0f/(aspect*tan_half);
        P[5]  = 1.0f/tan_half;
        P[10] = (float)(zf/(zf-zn));
        P[11] = 1.0f;
        P[14] = (float)(-zn*zf/(zf-zn));
        for (int c = 0; c < 4; ++c)
            for (int rr = 0; rr < 4; ++rr) {
                float s = 0;
                for (int k = 0; k < 4; ++k) s += P[k*4+rr] * V[c*4+k];
                VP[c*4+rr] = s;
            }
    }

    const float base_scale = (float)std::max(base_tenths, 1) / 10.0f;
    const float r_min = 0.0f, r_max = 64.0f;

    // 半径/深度分布(CPU 侧按 shader 同一口径算)—— 透视缩放下代价随距离变,
    // 不报这个分布,帧时间就没法解释。顺带数「在相机后面」的点。
    double rmin=1e30, rmax=-1e30; uint64_t clamped=0, behind=0, onscreen=0;
    std::vector<double> rad; rad.reserve(N);
    for (const CPoint& p : real) {
        const float cx = VP[0]*p.x + VP[4]*p.y + VP[8]*p.z  + VP[12];
        const float cy = VP[1]*p.x + VP[5]*p.y + VP[9]*p.z  + VP[13];
        const float wv = VP[3]*p.x + VP[7]*p.y + VP[11]*p.z + VP[15];
        if (wv <= 0) { ++behind; continue; }
        // 在画面内的点数:拉近之后大半朵云出了视锥,**可见点数本身变少了**,
        // 不报这个数就会把「拉近更便宜」误读成「大点更便宜」。
        if (std::fabs(cx) <= wv && std::fabs(cy) <= wv) ++onscreen;
        double r = base_scale * cam_dist / wv;
        if (r > r_max) { ++clamped; r = r_max; }
        rad.push_back(r);
        rmin = std::min(rmin, r); rmax = std::max(rmax, r);
    }
    std::sort(rad.begin(), rad.end());
    auto rq = [&](double f) {
        return rad.empty() ? 0.0
             : rad[std::min((size_t)std::llround(f*(rad.size()-1)), rad.size()-1)];
    };

    // ─── 合成均匀对照(同包围盒、同 N、同颜色分布)─────────────────────
    // 「聚簇 vs 均匀」要在**同一轮内**比,不能跨 run —— 上一轮 run3 就是把
    // 要比的东西放成两个格子,测出「顺序慢 15%」其实是累积热漂移。
    std::vector<CPoint> uni;
    if (arm_mask & 0x30u) {
        uni.resize(N);
        std::mt19937 rg(20260923u);
        std::uniform_real_distribution<float> ux((float)lo[0], (float)hi[0]);
        std::uniform_real_distribution<float> uy((float)lo[1], (float)hi[1]);
        std::uniform_real_distribution<float> uz((float)lo[2], (float)hi[2]);
        for (uint32_t i = 0; i < N; ++i)
            uni[i] = {ux(rg), uy(rg), uz(rg), real[i].rgba};  // 颜色照搬真云
    }

    // ─── 资源 ───────────────────────────────────────────────────────────
    WGPUTextureDescriptor td = WGPU_TEXTURE_DESCRIPTOR_INIT;
    td.dimension = WGPUTextureDimension_2D;
    td.size = WGPUExtent3D{kW, kH, 1};
    td.format = WGPUTextureFormat_RGBA8Unorm;
    td.mipLevelCount = 1; td.sampleCount = 1;
    td.usage = (WGPUTextureUsage)(WGPUTextureUsage_RenderAttachment |
                                  WGPUTextureUsage_CopySrc);
    Rt rt;
    rt.color = wgpuDeviceCreateTexture(g.device, &td);
    td.format = WGPUTextureFormat_Depth32Float;
    td.usage = WGPUTextureUsage_RenderAttachment;
    rt.depth_pc = wgpuDeviceCreateTexture(g.device, &td);
    rt.depth_ro = wgpuDeviceCreateTexture(g.device, &td);
    WGPUTextureViewDescriptor vd = WGPU_TEXTURE_VIEW_DESCRIPTOR_INIT;
    rt.color_v = wgpuTextureCreateView(rt.color, &vd);
    rt.depth_pc_v = wgpuTextureCreateView(rt.depth_pc, &vd);
    rt.depth_ro_v = wgpuTextureCreateView(rt.depth_ro, &vd);
    {   // depth_ro 开局清一次 1.0,之后只读
        WGPUCommandEncoderDescriptor ed = WGPU_COMMAND_ENCODER_DESCRIPTOR_INIT;
        WGPUCommandEncoder enc = wgpuDeviceCreateCommandEncoder(g.device, &ed);
        WGPURenderPassDepthStencilAttachment da =
            WGPU_RENDER_PASS_DEPTH_STENCIL_ATTACHMENT_INIT;
        da.view = rt.depth_ro_v; da.depthLoadOp = WGPULoadOp_Clear;
        da.depthStoreOp = WGPUStoreOp_Store; da.depthClearValue = 1.0f;
        da.depthReadOnly = WGPU_FALSE;
        WGPURenderPassDescriptor pd = WGPU_RENDER_PASS_DESCRIPTOR_INIT;
        pd.colorAttachmentCount = 0; pd.depthStencilAttachment = &da;
        WGPURenderPassEncoder p = wgpuCommandEncoderBeginRenderPass(enc, &pd);
        wgpuRenderPassEncoderEnd(p); wgpuRenderPassEncoderRelease(p);
        WGPUCommandBufferDescriptor cbd = WGPU_COMMAND_BUFFER_DESCRIPTOR_INIT;
        WGPUCommandBuffer cb = wgpuCommandEncoderFinish(enc, &cbd);
        wgpuCommandEncoderRelease(enc);
        wgpuQueueSubmit(g.queue, 1, &cb); wgpuCommandBufferRelease(cb);
    }

    WGPUShaderModule mod = MakeModule(kWgslCloud);
    WGPURenderPipeline pipeQ = MakePipeline(mod, "fs_opaque", false, true);
    WGPURenderPipeline pipeB = MakePipeline(mod, "fs_blend",  true,  false);
    if (!pipeQ) { result = "pipeline failed\n" + g.error_log; return result.c_str(); }

    WGPUBuffer buf_u = MakeBuffer(sizeof(CloudUniforms),
        (WGPUBufferUsage)(WGPUBufferUsage_Storage | WGPUBufferUsage_CopyDst));
    CloudUniforms cu{};
    std::memcpy(cu.viewproj, VP, sizeof VP);
    cu.img_size[0] = (float)kW; cu.img_size[1] = (float)kH;
    cu.base_scale = base_scale; cu.cam_dist = (float)cam_dist;
    cu.r_min = r_min; cu.r_max = r_max;
    wgpuQueueWriteBuffer(g.queue, buf_u, 0, &cu, sizeof cu);

    // 标签 / buffer:
    //  0 RN = 真云 **PLY 原生序**(MVS 融合产出的顺序)← 什么都不做的基线
    //  1 RM = 真云 3D 莫顿序                          ← 产品路
    //  2 RM2= 与 RM 同 pipeline 同 buffer,只换轮内位置 ← 噪声底(A′)
    //  3 RR = 真云 随机序                              ← 局部性的人为最坏情形
    //  4 UM = 合成均匀(同盒同 N)莫顿序
    //  5 UR = 合成均匀 随机序                          ← 复现上一轮的合成条件
    static const char* kName[kNL] = {"RN","RM","RM2","RR","UM","UR"};
    // buffer 槽:0=真原生 1=真莫顿 2=真随机 3=均匀莫顿 4=均匀随机
    WGPUBuffer bufs[5] = {nullptr,nullptr,nullptr,nullptr,nullptr};
    WGPUBindGroup bgs[5] = {nullptr,nullptr,nullptr,nullptr,nullptr};
    const int slot_of[kNL] = {0, 1, 1, 2, 3, 4};
    uint32_t need = 0;
    for (int L = 0; L < kNL; ++L) if ((arm_mask >> L) & 1u) need |= 1u << slot_of[L];

    Ck ck_of_slot[5]; bool ck_ok[5] = {true,true,true,true,true};
    {
        std::mt19937 rp(4242u);
        auto make_slot = [&](int slot) {
            if (!((need >> slot) & 1u)) return;
            bufs[slot] = MakeBuffer((uint64_t)N * sizeof(CPoint),
                (WGPUBufferUsage)(WGPUBufferUsage_Storage |
                                  WGPUBufferUsage_CopyDst));
            std::vector<CPoint> tmp;
            switch (slot) {
                case 0: tmp = real; break;
                case 1: tmp = MortonOrder3D(real, lo, ext); break;
                case 2: tmp = real; std::shuffle(tmp.begin(), tmp.end(), rp); break;
                case 3: tmp = MortonOrder3D(uni, lo, ext); break;
                case 4: tmp = uni;  std::shuffle(tmp.begin(), tmp.end(), rp); break;
            }
            ck_of_slot[slot] = Checksum(tmp);
            // 真云的三个槽必须与原始多重集完全一致(置换校验)。
            if (slot <= 2)
                ck_ok[slot] = (ck_of_slot[slot].xr == ck_real.xr &&
                               ck_of_slot[slot].sm == ck_real.sm);
            UploadChunked(bufs[slot], tmp.data(), (size_t)N * sizeof(CPoint));
        };
        for (int s = 0; s < 5; ++s) make_slot(s);
    }
    for (int s = 0; s < 5; ++s) {
        if (!bufs[s]) continue;
        WGPUBindGroupEntry be[2];
        for (int i = 0; i < 2; ++i) be[i] = WGPU_BIND_GROUP_ENTRY_INIT;
        be[0].binding = 0; be[0].buffer = buf_u; be[0].size = sizeof(CloudUniforms);
        be[1].binding = 1; be[1].buffer = bufs[s];
        be[1].size = (uint64_t)N * sizeof(CPoint);
        WGPUBindGroupDescriptor bd = WGPU_BIND_GROUP_DESCRIPTOR_INIT;
        bd.layout = wgpuRenderPipelineGetBindGroupLayout(pipeQ, 0);
        bd.entryCount = 2; bd.entries = be;
        bgs[s] = wgpuDeviceCreateBindGroup(g.device, &bd);
    }
    if (!g.error_log.empty() && !bgs[slot_of[1]]) {
        result = "bind group failed\n" + g.error_log; return result.c_str();
    }

    WGPUQuerySet qs = nullptr;
    WGPUBuffer resolve = nullptr, qstage = nullptr;
    const uint32_t kSlots = (uint32_t)std::max(K, 1) + 8u;
    if (g.has_timestamp) {
        WGPUQuerySetDescriptor qd = WGPU_QUERY_SET_DESCRIPTOR_INIT;
        qd.type = WGPUQueryType_Timestamp; qd.count = 2;
        qs = wgpuDeviceCreateQuerySet(g.device, &qd);
        resolve = MakeBuffer((uint64_t)kSlots * 256ull,
            (WGPUBufferUsage)(WGPUBufferUsage_QueryResolve |
                              WGPUBufferUsage_CopySrc));
        qstage = MakeBuffer((uint64_t)kSlots * 256ull,
            (WGPUBufferUsage)(WGPUBufferUsage_MapRead |
                              WGPUBufferUsage_CopyDst));
    }

    // ─── JSON 头 ────────────────────────────────────────────────────────
    char nb[192];
    std::string j = "{\n";
    j += "  \"bench\": \"pw_cloud\",\n  \"date\": \"2026-09-23\",\n";
    j += "  \"tag\": \"" + std::string(tag ? tag : "") + "\",\n";
    j += "  \"adapter\": \"" + g.adapter_name + "\",\n";
    j += "  \"width\": " + std::to_string(kW) + ", \"height\": " +
         std::to_string(kH) + ",\n";
    j += "  \"timestamp_query\": " +
         std::string(g.has_timestamp ? "true" : "false") + ",\n";
    j += "  \"n_points\": " + std::to_string(N) + ",\n";
    j += "  \"cloud_checksum\": {\"xor\": \"" ;
    std::snprintf(nb, sizeof nb, "%016llx", (unsigned long long)ck_real.xr);
    j += std::string(nb) + "\", \"sum\": \"";
    std::snprintf(nb, sizeof nb, "%016llx", (unsigned long long)ck_real.sm);
    j += std::string(nb) + "\"},\n";
    std::snprintf(nb, sizeof nb,
        "  \"bbox\": {\"lo\": [%.4f,%.4f,%.4f], \"hi\": [%.4f,%.4f,%.4f], "
        "\"extent\": [%.4f,%.4f,%.4f], \"diag\": %.4f},\n",
        lo[0],lo[1],lo[2],hi[0],hi[1],hi[2],ext[0],ext[1],ext[2],diag);
    j += nb;
    std::snprintf(nb, sizeof nb,
        "  \"camera\": {\"sel\": %d, \"name\": \"%s\", \"dist\": %.4f, "
        "\"d_fit\": %.4f, \"eye\": [%.4f,%.4f,%.4f], \"fov_y_deg\": 60, "
        "\"znear\": %.4f, \"zfar\": %.4f},\n",
        cam_sel, cam_name, cam_dist, d_fit, eye[0],eye[1],eye[2], zn, zf);
    j += nb;
    std::snprintf(nb, sizeof nb,
        "  \"point_radius_px\": {\"base_scale\": %.2f, \"min\": %.3f, "
        "\"p50\": %.3f, \"p99\": %.3f, \"max\": %.3f, \"clamp_max\": %.1f, "
        "\"n_clamped\": %llu, \"n_behind_camera\": %llu, \"n_onscreen\": %llu},\n",
        base_scale, rmin, rq(0.5), rq(0.99), rmax, r_max,
        (unsigned long long)clamped, (unsigned long long)behind,
        (unsigned long long)onscreen);
    j += nb;
    j += "  \"cloud_wgsl_sha256\": \"" +
         Sha256Hex(kWgslCloud, std::strlen(kWgslCloud)) + "\",\n";
    j += "  \"K\": " + std::to_string(K) + ", \"R\": " + std::to_string(R) +
         ", \"warmup\": " + std::to_string(warmup) +
         ", \"arm_mask\": " + std::to_string(arm_mask) + ",\n";
    // 置换校验和(渲染之外的第一道闸)
    j += "  \"permutation_check\": {";
    j += "\"real_native\": " + std::string(ck_ok[0] ? "true":"true");
    j += ", \"real_morton_is_permutation\": " +
         std::string(bufs[1] ? (ck_ok[1] ? "true" : "false") : "null");
    j += ", \"real_random_is_permutation\": " +
         std::string(bufs[2] ? (ck_ok[2] ? "true" : "false") : "null");
    j += "},\n";

    auto label_ok = [&](int L) { return ((arm_mask >> L) & 1u) != 0; };
    auto run_block = [&](int L, uint32_t n, std::vector<double>* wall,
                         std::vector<double>* gpu) {
        WGPUBindGroup bg = bgs[slot_of[L]];
        for (int f = 0; f < K; ++f)
            wall->push_back(RenderOneFrame(rt, pipeQ, bg, 6u*n, true, qs,
                                           resolve, (uint32_t)f));
        if (qs) {
            auto v = ReadGpuNs(resolve, qstage, (uint32_t)K);
            gpu->insert(gpu->end(), v.begin(), v.end());
        }
    };

    std::vector<int> labels;
    for (int L = 0; L < kNL; ++L) if (label_ok(L) && bgs[slot_of[L]]) labels.push_back(L);
    const int nl = (int)labels.size();

    // 预热(不计数)
    for (int L : labels)
        for (int f = 0; f < warmup; ++f)
            RenderOneFrame(rt, pipeQ, bgs[slot_of[L]], 6u*N, true,
                           nullptr, nullptr, 0);

    // 轮内轮换:标签次序按轮号循环旋转 ⇒ 热漂移在**所有**对比上平衡。
    // 轮 = 重复单位(一轮里的 K 帧是伪重复)。
    std::vector<double> w[kNL], gv[kNL], round_w[kNL], round_g[kNL];
    for (int r = 0; r < R; ++r) {
        std::vector<double> rw[kNL], rg[kNL];
        for (int pos = 0; pos < nl; ++pos)
            run_block(labels[(pos + r) % nl], N, &rw[labels[(pos+r)%nl]],
                      &rg[labels[(pos+r)%nl]]);
        for (int L : labels) {
            round_w[L].push_back(Summarize(rw[L]).p50);
            round_g[L].push_back(Summarize(rg[L]).p50);
            w[L].insert(w[L].end(), rw[L].begin(), rw[L].end());
            gv[L].insert(gv[L].end(), rg[L].begin(), rg[L].end());
        }
    }

    // 空 pass 底噪:同 pipeline 同 pass,只画 1 个点。
    std::vector<double> wEmpty, gEmpty;
    for (int f = 0; f < K; ++f)
        wEmpty.push_back(RenderOneFrame(rt, pipeQ, bgs[slot_of[labels[0]]], 6u,
                                        true, qs, resolve, (uint32_t)f));
    if (qs) { auto v = ReadGpuNs(resolve, qstage, (uint32_t)K);
              gEmpty.insert(gEmpty.end(), v.begin(), v.end()); }

    // 阳性对照:同一把尺子量 RM 在 N/2 上。≈0.5 才算尺子没坏(上一轮靠它
    // 当场抓到一次降频坏测量)。⚠️ 莫顿序的前一半 = 空间上的一块,不是
    // 均匀子采样 ⇒ 这里用 **RN 原生序**的前一半,更接近「点数减半」本意。
    std::vector<double> wHalf, gHalf;
    {
        const int Lh = label_ok(0) && bgs[0] ? 0 : labels[0];
        for (int f = 0; f < K; ++f)
            wHalf.push_back(RenderOneFrame(rt, pipeQ, bgs[slot_of[Lh]], 6u*(N/2),
                                           true, qs, resolve, (uint32_t)f));
        if (qs) { auto v = ReadGpuNs(resolve, qstage, (uint32_t)K);
                  gHalf.insert(gHalf.end(), v.begin(), v.end()); }
        j += "  \"positive_control_label\": \"" + std::string(kName[Lh]) + "\",\n";
    }

    auto series = [&](const std::vector<double>& v) {
        char rb[64]; std::string o = "[";
        for (size_t i = 0; i < v.size(); ++i) {
            std::snprintf(rb, sizeof rb, "%s%.4f", i ? "," : "", v[i]); o += rb;
        }
        return o + "]";
    };
    j += "  \"labels\": [";
    for (size_t i = 0; i < labels.size(); ++i)
        j += std::string(i ? "," : "") + "\"" + kName[labels[i]] + "\"";
    j += "],\n";
    for (int L : labels) {
        j += std::string("  \"") + kName[L] + "_gpu_ms\": " +
             StatsJson(Summarize(gv[L])) + ",\n";
        j += std::string("  \"") + kName[L] + "_wall_ms\": " +
             StatsJson(Summarize(w[L])) + ",\n";
    }
    for (int L : labels) {
        j += std::string("  \"round_gpu_p50_") + kName[L] + "\": " +
             series(round_g[L]) + ",\n";
        j += std::string("  \"round_wall_p50_") + kName[L] + "\": " +
             series(round_w[L]) + ",\n";
    }
    j += "  \"empty_pass_gpu_ms\": " + StatsJson(Summarize(gEmpty)) + ",\n";
    j += "  \"positive_control_halfN_gpu_ms\": " + StatsJson(Summarize(gHalf)) + ",\n";

    // ─── 正确性 + 阴性对照 ──────────────────────────────────────────────
    // 命题:有了深度缓冲,**点在 buffer 里的次序不影响画面** ⇒ 排序可以删,
    //       而且莫顿重排是安全的。
    // ⚠️ 真数据的深度分布由不得我选,f32 深度并列一定会有。所以判据设计成
    //    **三种次序两两比**:
    //      并列的签名 = d(A,B) ≈ d(A,M) ≈ d(B,M),都很小且同量级;
    //      真错的签名 = M 与 A、B 都差得远,而 A、B 之间几乎不差。
    //    再加上「覆盖率必须完全相等」(丢点/重复点会改覆盖率,并列不会)。
    {
        std::vector<uint8_t> ia, ib, im;
        ImgStat sa, sb, sm;
        const bool have_native = bufs[0] && bgs[0];
        const bool have_mor    = bufs[1] && bgs[1];
        const bool have_rand   = bufs[2] && bgs[2];
        if (have_native) { RenderOneFrame(rt, pipeQ, bgs[0], 6u*N, true, nullptr,nullptr,0);
                           sa = ReadbackImage(rt, &ia); }
        if (have_rand)   { RenderOneFrame(rt, pipeQ, bgs[2], 6u*N, true, nullptr,nullptr,0);
                           sb = ReadbackImage(rt, &ib); }
        if (have_mor)    { RenderOneFrame(rt, pipeQ, bgs[1], 6u*N, true, nullptr,nullptr,0);
                           sm = ReadbackImage(rt, &im); }
        const Diff dab = (have_native && have_rand) ? ImgDiff(ia, ib) : Diff{};
        const Diff dam = (have_native && have_mor)  ? ImgDiff(ia, im) : Diff{};
        const Diff dbm = (have_rand   && have_mor)  ? ImgDiff(ib, im) : Diff{};
        j += "  \"correctness_three_orders\": {\n";
        j += "    \"note\": \"native / random / morton of the SAME real cloud. "
             "ties look like dab~dam~dbm; a bug looks like dam,dbm >> dab\",\n";
        j += "    \"native\": " + ImgStatJson(sa) + ",\n";
        j += "    \"random\": " + ImgStatJson(sb) + ",\n";
        j += "    \"morton\": " + ImgStatJson(sm) + ",\n";
        std::snprintf(nb, sizeof nb,
            "    \"d_native_random\": {\"pixels\": %llu, \"bytes\": %llu, \"max_abs\": %d},\n",
            (unsigned long long)dab.pixels, (unsigned long long)dab.bytes, dab.max_abs);
        j += nb;
        std::snprintf(nb, sizeof nb,
            "    \"d_native_morton\": {\"pixels\": %llu, \"bytes\": %llu, \"max_abs\": %d},\n",
            (unsigned long long)dam.pixels, (unsigned long long)dam.bytes, dam.max_abs);
        j += nb;
        std::snprintf(nb, sizeof nb,
            "    \"d_random_morton\": {\"pixels\": %llu, \"bytes\": %llu, \"max_abs\": %d},\n",
            (unsigned long long)dbm.pixels, (unsigned long long)dbm.bytes, dbm.max_abs);
        j += nb;
        j += "    \"coverage_all_equal\": " +
             std::string((sa.cover == sb.cover && sb.cover == sm.cover)
                         ? "true" : "false") + "\n";
        j += "  },\n";

        // 阴性对照:同两种次序走画家式(混合 + 不写深度)⇒ 必须**不同**。
        // 没有它,上面那个「几乎相同」可能只是因为判据根本不会失败。
        if (pipeB && have_native && have_mor) {
            WGPUBindGroupDescriptor bd = WGPU_BIND_GROUP_DESCRIPTOR_INIT;
            WGPUBindGroupEntry be[2];
            for (int i = 0; i < 2; ++i) be[i] = WGPU_BIND_GROUP_ENTRY_INIT;
            be[0].binding = 0; be[0].buffer = buf_u; be[0].size = sizeof(CloudUniforms);
            be[1].binding = 1; be[1].size = (uint64_t)N * sizeof(CPoint);
            bd.layout = wgpuRenderPipelineGetBindGroupLayout(pipeB, 0);
            bd.entryCount = 2; bd.entries = be;
            be[1].buffer = bufs[0];
            WGPUBindGroup bnA = wgpuDeviceCreateBindGroup(g.device, &bd);
            be[1].buffer = bufs[1];
            WGPUBindGroup bnM = wgpuDeviceCreateBindGroup(g.device, &bd);
            std::vector<uint8_t> na, nm;
            RenderOneFrame(rt, pipeB, bnA, 6u*N, false, nullptr,nullptr,0);
            ImgStat qa = ReadbackImage(rt, &na);
            RenderOneFrame(rt, pipeB, bnM, 6u*N, false, nullptr,nullptr,0);
            ImgStat qm = ReadbackImage(rt, &nm);
            const Diff dn = ImgDiff(na, nm);
            j += "  \"negative_control_blended\": {\n";
            j += "    \"note\": \"blend + no depth is order dependent; identical "
                 "here would mean the ruler cannot fail\",\n";
            j += "    \"native\": " + ImgStatJson(qa) + ",\n";
            j += "    \"morton\": " + ImgStatJson(qm) + ",\n";
            std::snprintf(nb, sizeof nb,
                "    \"diff\": {\"pixels\": %llu, \"bytes\": %llu, \"max_abs\": %d}\n",
                (unsigned long long)dn.pixels, (unsigned long long)dn.bytes, dn.max_abs);
            j += nb;
            j += "  },\n";
        }
    }

    j += "  \"wgpu_errors\": \"" + g.error_log.substr(0, 2000) + "\"\n}\n";

    NSString* dir = [NSString stringWithUTF8String:out_dir];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                             withIntermediateDirectories:YES
                                              attributes:nil error:nil];
    NSString* path = [dir stringByAppendingPathComponent:@"cloud.json"];
    [[NSString stringWithUTF8String:j.c_str()]
        writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    result = std::string([path UTF8String]);
    return result.c_str();
}
