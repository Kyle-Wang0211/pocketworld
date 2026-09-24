// PWPointsBench —— 设备侧**裸点云**帧时间台架(A16)。
//
// 起因(2026-09-23):同一台架刚量完 instancing vs 顶点展开,顺带填上了
// **高斯泼溅**配置的帧时间:1M ≈ 23–25 ms、4M ≈ 103–114 ms。但那是**上界** ——
// 它含三样裸点云根本不需要的东西:
//   ① alpha 混合(不透明点靠 z-buffer 定前后)
//   ② `discard`(①②都会关掉移动端分块架构的隐面剔除)
//   ③ 通过乱序 `order[]` 的随机访存(有了深度缓冲就不必按深度排序 ——
//      现役 Dart 画家每帧排序的唯一理由就是 Canvas 没有深度缓冲)
// 这份台架把这三样删掉,量真正要画的东西:xyz + rgb,不透明,z-buffer。
//
// 要回答:**裸点云在 1M / 4M / 6.92M(真实数据量)上单帧多少毫秒?**
// 直接决定「要不要点预算 / 预算值多少」。
//
// 口径(照隔壁 bench.mm 的规矩,那套设计上一轮验证过):
//   - 所有标签**同一进程内轮内轮换**,轮 = 重复单位。手机 A/B 的头号杀手是
//     热漂移;上一轮第一次做法就栽在「把要比的东西放成两个格子」。
//   - `P2` **空臂**:与 `P` 完全同一条 pipeline、同一个 draw,只是在轮内换个
//     位置跑。`P2/P` 偏离 1.0 多少 = 这套机器自己的噪声底。
//   - 阳性对照:同臂 N vs N/2 应 ≈0.5。量不出「活儿少一半」的尺子,
//     任何零结果都不可信(上一轮靠它当场抓到一次降频坏测量)。
//   - 正确性对照 + **阴性对照**:见 §correctness。判「排序能不能删」不靠
//     嘴说,靠**把同一批点用两种不同的 buffer 次序各画一遍,比整帧
//     sha256**;再用一条关掉深度写的臂证明这个判据**会**失败。
//
// 硬约束:**一行苹果图形 API 都不新增**。全程只调 WebGPU C API;苹果的只有
// 外壳三样 —— NSFileManager 写文件、CommonCrypto 算 sha256、NSString 拼路径。
// 新增 `#if __APPLE__` 0 处、厂商专属图形 API 0 处。
// ⚠️ 只有一台 A16。Adreno / Mali / Maleoon 零证据,报数时必须带这句。
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

#include "wgsl_arms.h"   // 高斯参照臂 = kWgslArmB(顶点展开版,上一轮的赢家)

namespace {

// iPhone 14 Pro 原生分辨率,与隔壁 bench.mm 同尺寸 ⇒ 两张表可以并排读。
constexpr uint32_t kW = 1179;
constexpr uint32_t kH = 2556;

// 真实数据量:未命名(12) 的稠密云 = 6,922,990 点 / 103,845,031 字节。
constexpr uint32_t kNReal = 6922990;

// 标签总数(见 §标签)。
constexpr int kNL = 8;

// ─── 裸点云的点记录 = xyz(3×f32) + rgba(packed u32)= 16 B ───────────
// 对照:高斯的 ProjectedSplat 是 36 B。这是**产品真要存的东西**,不是把
// 高斯记录改个 shader —— 记录大小本身就是这条路便宜的一部分。
struct PcPoint {
    float x, y, z;
    uint32_t rgba;
};
static_assert(sizeof(PcPoint) == 16, "PcPoint must be 16 bytes");

struct PointUniforms {
    float viewproj[16];   // 0   列主序(WGSL mat4x4f)
    float img_size[2];    // 64
    float radius_px;      // 72
    float pad0;           // 76
};
static_assert(sizeof(PointUniforms) == 80, "PointUniforms must be 80 bytes");

// 高斯参照臂要的 RenderUniforms(与 bench.mm 逐字同构)。
struct RenderUniforms {
    float viewmat[16];
    float focal[2];
    uint32_t img_size[2];
    uint32_t tile_bounds[2];
    float pixel_center[2];
    float camera_position[4];
    uint32_t sh_degree;
    uint32_t num_visible;
    uint32_t total_splats;
    uint32_t max_intersects;
    float background[4];
};
static_assert(sizeof(RenderUniforms) == 144, "RenderUniforms must be 144 bytes");

struct ProjectedSplat {
    float xy_x, xy_y;
    float conic_x, conic_y, conic_z;
    float r, g, b, a;
};
static_assert(sizeof(ProjectedSplat) == 36, "ProjectedSplat must be 36 bytes");

// ─── 裸点云 shader ──────────────────────────────────────────────────────
// 与高斯臂的差别就是要量的那三样:
//   fs_opaque 没有 discard、没有 alpha;pipeline 不开混合、开深度写;
//   VS 直接读 pts[vi/6],**没有 order[] 间接寻址**。
// 相同的是几何足迹:off * radius_px 给出 ±r px 的 quad,r=1.5 时与高斯表里
//   的 `r1.5` 格逐像素同面积 ⇒ 两张表可比。
static const char* kWgslPoints = R"PCWGSL(
struct PointUniforms {
    viewproj: mat4x4f,
    img_size: vec2f,
    radius_px: f32,
    pad0: f32,
}
struct PcPoint { x: f32, y: f32, z: f32, rgba: u32 }

@group(0) @binding(0) var<storage, read> pu: PointUniforms;
@group(0) @binding(1) var<storage, read> pts: array<PcPoint>;

// ⚠️ 移动端是**分块**架构:顶点着色器的全部输出都要落到主存的参数缓冲里
// 再按分块读回。所以「每点几个顶点 × 每顶点几字节 varying」是**直接的带宽
// 成本**,不是免费的。点精灵的颜色在整个 quad 上是常数 ⇒ 用 flat,且**只留
// 颜色一条 varying**(不带 uv):这是一个像样的点云渲染器本来就该写的样子,
// 不是给这一臂开小灶。
struct VsOut {
    @builtin(position) clip: vec4f,
    @location(0) @interpolate(flat) color: vec4f,
}

fn make_vertex(ii: u32, off: vec2f) -> VsOut {
    let p = pts[ii];
    // 真实产品路:每帧只换一个矩阵,点本身是静态的 xyz。没有投影 pass、
    // 没有排序 pass。⚠️ 这也意味着 P 臂把投影**算在自己账上**,而高斯参照臂
    // G 读的是别的 pass 预先投影好的 2D splat ⇒ G 的数字是偏低的(不含它的
    // 投影 pass),对比时 P 这边吃亏。
    var clip = pu.viewproj * vec4f(p.x, p.y, p.z, 1.0);
    // 恒定屏幕像素大小的点精灵:乘 clip.w 抵消透视除法。
    clip = vec4f(clip.xy + off * pu.radius_px * 2.0 / pu.img_size * clip.w,
                 clip.z, clip.w);
    var o: VsOut;
    o.clip = clip;
    o.color = unpack4x8unorm(p.rgba);
    return o;
}

// 顶点展开(不是 instancing)—— 上一轮实测在 A16 上快 7.7%–12%,且
// rerun / Potree-Next 上游都这么写。
@vertex fn vs_quad(@builtin(vertex_index) vi: u32) -> VsOut {
    var offsets = array<vec2f, 6>(
        vec2f(-1.0, -1.0),
        vec2f( 1.0, -1.0),
        vec2f( 1.0,  1.0),
        vec2f(-1.0, -1.0),
        vec2f( 1.0,  1.0),
        vec2f(-1.0,  1.0),
    );
    return make_vertex(vi / 6u, offsets[vi % 6u]);
}

// PointList 拓扑:1 顶点 / 点、1 像素 / 点。下界参照。
@vertex fn vs_point(@builtin(vertex_index) vi: u32) -> VsOut {
    return make_vertex(vi, vec2f(0.0, 0.0));
}

// 裸点云的片元:不透明,**没有 discard**,让分块架构的隐面剔除能工作。
@fragment fn fs_opaque(in: VsOut) -> @location(0) vec4f {
    return in.color;
}

// 对照臂 PB:**同一个顶点着色器、同一批数据、同样的顶点数与片元数**,
// 只把「alpha 混合 + 不写深度」加回来(= 现役 Dart 画家那种配置)。
// ⇒ P vs PB 是干净的单变量:z-buffer 这一刀值多少。
@fragment fn fs_blend(in: VsOut) -> @location(0) vec4f {
    let a = in.color.a * 0.5;
    return vec4f(in.color.rgb * a, a);
}
)PCWGSL";

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
    uint64_t max_storage_binding = 0;
    uint64_t max_buffer_size = 0;
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
    g.max_storage_binding = alim.maxStorageBufferBindingSize;
    g.max_buffer_size = alim.maxBufferSize;

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

// ─── pipeline 工厂 ─────────────────────────────────────────────────────
// blend=false + depth_write=true  ⇒ 裸点云(不透明,z-buffer 定前后)
// blend=true  + depth_write=false ⇒ 画家式(混合 + discard,无深度)
WGPURenderPipeline MakePipeline(WGPUShaderModule m, const char* vs_entry,
                                const char* fs_entry, bool blend,
                                bool depth_write, bool point_list) {
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
    fs.module = m;
    fs.entryPoint = SV(fs_entry);
    fs.targetCount = 1;
    fs.targets = &ct;

    WGPUVertexState vs = WGPU_VERTEX_STATE_INIT;
    vs.module = m;
    vs.entryPoint = SV(vs_entry);
    vs.bufferCount = 0;

    WGPUDepthStencilState ds = WGPU_DEPTH_STENCIL_STATE_INIT;
    ds.format = WGPUTextureFormat_Depth32Float;
    ds.depthWriteEnabled = depth_write ? WGPUOptionalBool_True
                                       : WGPUOptionalBool_False;
    // 裸点云:Less + 写 ⇒ 真正的 z-buffer。
    // 画家式:Always + 不写 ⇒ 完全不依赖深度缓冲内容(pass 走 readOnly)。
    ds.depthCompare = depth_write ? WGPUCompareFunction_Less
                                  : WGPUCompareFunction_Always;

    WGPURenderPipelineDescriptor p = WGPU_RENDER_PIPELINE_DESCRIPTOR_INIT;
    p.vertex = vs;
    p.fragment = &fs;
    p.primitive.topology = point_list ? WGPUPrimitiveTopology_PointList
                                      : WGPUPrimitiveTopology_TriangleList;
    p.primitive.cullMode = WGPUCullMode_None;
    p.primitive.frontFace = WGPUFrontFace_CCW;
    p.depthStencil = &ds;
    p.multisample.count = 1;
    p.multisample.mask = 0xFFFFFFFFu;
    return wgpuDeviceCreateRenderPipeline(g.device, &p);
}

// 高斯参照臂:与 bench.mm 的 arm B pipeline 逐字同构。
WGPURenderPipeline MakeGaussianPipeline(WGPUShaderModule m) {
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

// ─── 渲染目标 ───────────────────────────────────────────────────────────
// 两张深度纹理:
//   depth_pc —— 裸点云用,每帧 Clear(1.0) → Discard(分块架构上 clear 免费、
//                不回写省 12 MB 带宽,这也是产品真该用的配置)
//   depth_ro —— 画家式/高斯臂用,开局清一次 1.0 之后全程 depthReadOnly
//                (与 bench.mm 的做法逐字一致 ⇒ 高斯数可以对上)
struct Rt {
    WGPUTexture color = nullptr, depth_pc = nullptr, depth_ro = nullptr;
    WGPUTextureView color_v = nullptr, depth_pc_v = nullptr, depth_ro_v = nullptr;
};

double RenderOneFrame(const Rt& rt, WGPURenderPipeline pipe, WGPUBindGroup bg,
                      uint32_t vertex_count, uint32_t instance_count,
                      bool depth_write, WGPUQuerySet qs, WGPUBuffer resolve,
                      uint32_t slot) {
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
    if (depth_write) {
        da.view = rt.depth_pc_v;
        da.depthLoadOp = WGPULoadOp_Clear;
        da.depthStoreOp = WGPUStoreOp_Discard;
        da.depthClearValue = 1.0f;
        da.depthReadOnly = WGPU_FALSE;
    } else {
        da.view = rt.depth_ro_v;
        da.depthLoadOp = WGPULoadOp_Undefined;
        da.depthStoreOp = WGPUStoreOp_Undefined;
        da.depthReadOnly = WGPU_TRUE;
    }

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
                if (t1 > t0) out.push_back((double)(t1 - t0) / 1.0e6);
            }
        }
        wgpuBufferUnmap(staging);
    }
    return out;
}

// 整帧读回。除了 sha256,还量**通道均值/标准差与覆盖率** —— 上一次教训:
// 「非黑像素占比」这种判据会给平灰图放行(feedback_verify_with_a_metric_
// that_can_fail),所以必须量得出「画面塌成一个颜色」这种失效。
struct ImgStat {
    std::string sha;
    double cover = 0;            // alpha>0 的像素占比
    double mean[3] = {0, 0, 0};
    double sd[3] = {0, 0, 0};
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
            double s1[3] = {0, 0, 0}, s2[3] = {0, 0, 0};
            uint64_t covered = 0;
            const uint64_t npx = (uint64_t)kW * kH;
            for (uint32_t y = 0; y < kH; ++y) {
                const uint8_t* row = p + (size_t)y * bpr;
                for (uint32_t x = 0; x < kW; ++x) {
                    const uint8_t* px = row + (size_t)x * 4;
                    if (px[3]) ++covered;
                    for (int c = 0; c < 3; ++c) {
                        double v = px[c];
                        s1[c] += v; s2[c] += v * v;
                    }
                }
            }
            st.cover = (double)covered / (double)npx;
            for (int c = 0; c < 3; ++c) {
                st.mean[c] = s1[c] / (double)npx;
                double var = s2[c] / (double)npx - st.mean[c] * st.mean[c];
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

// ─── 点生成 ─────────────────────────────────────────────────────────────
// 屏幕分布与高斯臂一致(NDC 上均匀)⇒ 片元数可比;深度按**洗过的秩**分配,
// 且分在 **NDC z**(= 真正写进 Depth32Float 的那个量)上均匀 ⇒
//   ① z-buffer 有真活儿干(隐面剔除是这条路省时间的机制本身)
//   ② **逐点深度互不相同,而且间距 (0.9/N) 远大于 f32 的 ulp**
//      (N=1e6 时 9e-7 vs 6e-8,15 倍余量)⇒「换 buffer 次序画,结果必须
//      逐字节相同」这个判据在数值上是硬的。
//      🔴 第一版把深度均匀分在**视深度 d** 上,远端相邻深度的 ndc 差 1.2e-8
//      小于 f32 ulp 6e-8 ⇒ 真的撞出了 1 个并列像素(3 字节)。改分在 ndc z 上。
//   ③ 深度与下标**无关**(不是前后排序的)⇒ 不偷早期 z 的便宜,也不制造
//      最坏情形。生产里点云来自 MVS 融合,本来就不是深度序。
//   ④ 改分在 ndc z 上**不动任何性能量**:屏幕位置、像素足迹、每像素片元数、
//      深度相对下标的随机性全都不变,只有深度的数值变了。
const float kAspect = (float)kW / (float)kH;
const float kTanHalf = 0.57735027f;   // tan(30°),fov_y = 60°
const float kZNear = 0.1f, kZFar = 10.0f;
const float kZLo = 0.05f, kZHi = 0.95f;   // NDC z 取值区间(避开两个裁剪面)

void FillViewProj(float* vp) {
    std::memset(vp, 0, sizeof(float) * 16);
    vp[0]  = 1.0f / (kAspect * kTanHalf);      // col0.x
    vp[5]  = 1.0f / kTanHalf;                  // col1.y
    vp[10] = kZFar / (kZFar - kZNear);         // col2.z
    vp[11] = 1.0f;                             // col2.w
    vp[14] = -kZNear * kZFar / (kZFar - kZNear); // col3.z
}

void GeneratePoints(std::vector<PcPoint>* out, uint32_t n, uint32_t seed) {
    out->resize(n);
    std::mt19937 rng(seed);
    std::vector<uint32_t> rank(n);
    std::iota(rank.begin(), rank.end(), 0u);
    std::shuffle(rank.begin(), rank.end(), rng);
    std::uniform_real_distribution<float> un(-1.f, 1.f);
    std::uniform_int_distribution<int> uc(40, 255);
    for (uint32_t i = 0; i < n; ++i) {
        const float ndc_x = un(rng), ndc_y = un(rng);
        // ndc_z 均匀 ⇒ 反解视深度 d = zf*zn / (zf - z*(zf-zn))。
        const float ndc_z = kZLo +
            ((float)rank[i] + 0.5f) / (float)n * (kZHi - kZLo);
        const float d = kZFar * kZNear / (kZFar - ndc_z * (kZFar - kZNear));
        PcPoint p;
        p.x = ndc_x * kAspect * kTanHalf * d;
        p.y = ndc_y * kTanHalf * d;
        p.z = d;
        // 随机颜色:画面若塌成一个颜色(例如深度全错、只剩最后一个点),
        // 通道标准差会掉下来 ⇒ 判据抓得住。
        p.rgba = (uint32_t)uc(rng) | ((uint32_t)uc(rng) << 8) |
                 ((uint32_t)uc(rng) << 16) | (255u << 24);
        (*out)[i] = p;
    }
}

// ─── 空间局部性重排(两条)─────────────────────────────────────────────
// 为什么要测这个:半径从 0.5 px 扫到 4.0 px(片元数 ×64)只涨 30%,顶点数
// ×6 只涨 16%,图元数 ×2 只涨 16% ⇒ 每点的成本**三个杠杆都解释不了**。
// 剩下一个没试过的机制:移动端是分块渲染,每个分块在片元阶段要去参数缓冲里
// 取属于自己的图元。我的合成点在屏幕上是**均匀随机**的 ⇒ 同一个分块里的
// 图元在缓冲里彼此相隔极远,每次取都是一次缓存缺失。真实点云(MVS 融合出来
// 的)本来就是空间有序的 ⇒ 这可能是我把成本测高了。
//   ScreenTileOrder = 按屏幕分块排 —— **上界**(这一跑的相机是固定的,
//                     产品做不到逐帧这么排),用来判机制成不成立。
//   MortonOrder3D   = 按 3D 莫顿码排 —— **产品真能做的那个**(与视角无关,
//                     装载时排一次)。
// ⇒ 若上界也没效应,这条机制就死了,重排不值得做;若上界有效应而莫顿没有,
//    说明世界序到屏幕序的映射太松,得另想办法。
std::vector<PcPoint> ScreenTileOrder(const std::vector<PcPoint>& in,
                                     const float* vp) {
    const uint32_t kTile = 32;
    const uint32_t tx = (kW + kTile - 1) / kTile;
    std::vector<std::pair<uint64_t, uint32_t>> key(in.size());
    for (size_t i = 0; i < in.size(); ++i) {
        const PcPoint& p = in[i];
        const float ndc_x = (vp[0] * p.x) / p.z;
        const float ndc_y = (vp[5] * p.y) / p.z;
        uint32_t px = (uint32_t)std::min(std::max((ndc_x * 0.5f + 0.5f) *
                                                  (float)kW, 0.f), (float)kW - 1);
        uint32_t py = (uint32_t)std::min(std::max((0.5f - ndc_y * 0.5f) *
                                                  (float)kH, 0.f), (float)kH - 1);
        key[i] = {(uint64_t)(py / kTile) * tx + (px / kTile), (uint32_t)i};
    }
    std::sort(key.begin(), key.end());
    std::vector<PcPoint> out(in.size());
    for (size_t i = 0; i < key.size(); ++i) out[i] = in[key[i].second];
    return out;
}

uint64_t Part1By2(uint32_t v) {           // 10 bit -> 每位间插 2 个 0
    uint64_t x = v & 0x3FFull;
    x = (x | (x << 16)) & 0x030000FFull;
    x = (x | (x << 8))  & 0x0300F00Full;
    x = (x | (x << 4))  & 0x030C30C3ull;
    x = (x | (x << 2))  & 0x09249249ull;
    return x;
}
std::vector<PcPoint> MortonOrder3D(const std::vector<PcPoint>& in) {
    float lo[3] = {1e30f, 1e30f, 1e30f}, hi[3] = {-1e30f, -1e30f, -1e30f};
    for (const PcPoint& p : in) {
        const float v[3] = {p.x, p.y, p.z};
        for (int c = 0; c < 3; ++c) {
            lo[c] = std::min(lo[c], v[c]); hi[c] = std::max(hi[c], v[c]);
        }
    }
    std::vector<std::pair<uint64_t, uint32_t>> key(in.size());
    for (size_t i = 0; i < in.size(); ++i) {
        const PcPoint& p = in[i];
        const float v[3] = {p.x, p.y, p.z};
        uint32_t q[3];
        for (int c = 0; c < 3; ++c) {
            const float t = (hi[c] > lo[c]) ? (v[c] - lo[c]) / (hi[c] - lo[c]) : 0.f;
            q[c] = (uint32_t)std::min(std::max(t * 1023.f, 0.f), 1023.f);
        }
        key[i] = {Part1By2(q[0]) | (Part1By2(q[1]) << 1) | (Part1By2(q[2]) << 2),
                  (uint32_t)i};
    }
    std::sort(key.begin(), key.end());
    std::vector<PcPoint> out(in.size());
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
// out_dir: 结果 JSON 落盘目录
// K: 每块帧数  R: 轮数  warmup: 每标签预热帧数
// cell_sel: -1 = 全跑;0/1/2 = 只跑该格(热预算是硬约束,推荐一格一次冷启动)
// radius_tenths: quad 半径,单位 0.1 px(15 = 1.5 px,与高斯表同足迹)
extern "C" const char* pwpoints_run(const char* out_dir, int K, int R,
                                    int warmup, int cell_sel,
                                    int radius_tenths, const char* tag) {
    static std::string result;
    result.clear();
    std::string err;
    if (!InitGpu(&err)) { result = "init failed: " + err; return result.c_str(); }

    const float radius_px = (float)std::max(radius_tenths, 1) / 10.0f;

    // ─── 格子 ───────────────────────────────────────────────────────────
    // label bit: 0=P 1=P2 2=PT 3=PB 4=G 5=PSs(屏幕序) 6=PSm(3D 莫顿序)
    //            7=PTm(PointList + 莫顿序 = 两条最便宜的叠在一起)
    struct Cell { const char* name; uint32_t n; uint32_t mask; };
    const Cell all_cells[] = {
        {"N1M",        1000000, 0xFFu},
        {"N4M",        4000000, 0xFFu},
        // 真实数据量:未命名(12) 稠密云 6,922,990 点。
        // 这一格**关掉 PB 和 G**:PB 的趋势在 1M/4M 两格已经量清楚,G 要
        // 7M×36 B = 249 MB 的 splat buffer 且本来就不是产品要画的东西 ⇒ 把
        // 热预算让给两条空间局部性臂(那才是可能翻盘的量)。
        {"N6.92M_real", kNReal, 0xE7u},
    };
    std::vector<Cell> cells;
    for (int i = 0; i < 3; ++i)
        if (cell_sel < 0 || cell_sel == i) cells.push_back(all_cells[i]);
    if (cells.empty()) { result = "no cell selected"; return result.c_str(); }

    uint32_t nmax = 0, mask_any = 0;
    for (const Cell& c : cells) { nmax = std::max(nmax, c.n); mask_any |= c.mask; }
    const bool need_gauss = (mask_any & 0x10u) != 0;
    const uint32_t n_gauss_max = std::min(nmax, 4000000u);

    // ─── 渲染目标 ───────────────────────────────────────────────────────
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
    rt.depth_pc = wgpuDeviceCreateTexture(g.device, &td);
    rt.depth_ro = wgpuDeviceCreateTexture(g.device, &td);
    WGPUTextureViewDescriptor vd = WGPU_TEXTURE_VIEW_DESCRIPTOR_INIT;
    rt.color_v = wgpuTextureCreateView(rt.color, &vd);
    rt.depth_pc_v = wgpuTextureCreateView(rt.depth_pc, &vd);
    rt.depth_ro_v = wgpuTextureCreateView(rt.depth_ro, &vd);

    // depth_ro 开局清一次 1.0,之后所有用它的 pass 都 depthReadOnly。
    {
        WGPUCommandEncoderDescriptor ed = WGPU_COMMAND_ENCODER_DESCRIPTOR_INIT;
        WGPUCommandEncoder enc = wgpuDeviceCreateCommandEncoder(g.device, &ed);
        WGPURenderPassDepthStencilAttachment da =
            WGPU_RENDER_PASS_DEPTH_STENCIL_ATTACHMENT_INIT;
        da.view = rt.depth_ro_v;
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

    // ─── pipelines ──────────────────────────────────────────────────────
    WGPUShaderModule mP = MakeModule(kWgslPoints);
    WGPURenderPipeline pipeP  = MakePipeline(mP, "vs_quad",  "fs_opaque",
                                             false, true,  false);
    WGPURenderPipeline pipePT = MakePipeline(mP, "vs_point", "fs_opaque",
                                             false, true,  true);
    WGPURenderPipeline pipePB = MakePipeline(mP, "vs_quad",  "fs_blend",
                                             true,  false, false);
    if (!pipeP) {
        result = "point pipeline failed\n" + g.error_log;
        return result.c_str();
    }
    // PointList 在某些后端要 shader 写 point_size;若这条挂了,只丢这个标签,
    // 不让整跑作废。
    uint32_t mask_drop = 0;
    if (!pipePT) mask_drop |= 0x04u;
    if (!pipePB) mask_drop |= 0x08u;

    WGPUShaderModule mG = nullptr;
    WGPURenderPipeline pipeG = nullptr;
    if (need_gauss) {
        mG = MakeModule(kWgslArmB);
        pipeG = MakeGaussianPipeline(mG);
        if (!pipeG) mask_drop |= 0x10u;
    }

    // ─── buffers ────────────────────────────────────────────────────────
    WGPUBuffer buf_pu = MakeBuffer(sizeof(PointUniforms),
        (WGPUBufferUsage)(WGPUBufferUsage_Storage | WGPUBufferUsage_CopyDst));
    WGPUBuffer buf_pts = MakeBuffer((uint64_t)nmax * sizeof(PcPoint),
        (WGPUBufferUsage)(WGPUBufferUsage_Storage | WGPUBufferUsage_CopyDst));
    // 正确性对照用:同一批点的**另一种 buffer 次序**。只在 1M 规模用。
    const uint32_t kNCorrect = 1000000;
    WGPUBuffer buf_pts_perm = MakeBuffer((uint64_t)kNCorrect * sizeof(PcPoint),
        (WGPUBufferUsage)(WGPUBufferUsage_Storage | WGPUBufferUsage_CopyDst));
    // 空间局部性两条臂:同一批点、同一条 pipeline,只有 buffer 里的次序不同。
    // 三个常驻 buffer,切换只换 bind group、不做任何拷贝(与 bench.mm 处理
    // 「乱序 vs 顺序 order[]」时同一条规矩:别把要比的东西放成两个格子)。
    WGPUBuffer buf_pts_scr = MakeBuffer((uint64_t)nmax * sizeof(PcPoint),
        (WGPUBufferUsage)(WGPUBufferUsage_Storage | WGPUBufferUsage_CopyDst));
    WGPUBuffer buf_pts_mor = MakeBuffer((uint64_t)nmax * sizeof(PcPoint),
        (WGPUBufferUsage)(WGPUBufferUsage_Storage | WGPUBufferUsage_CopyDst));

    PointUniforms pu{};
    FillViewProj(pu.viewproj);
    pu.img_size[0] = (float)kW; pu.img_size[1] = (float)kH;
    pu.radius_px = radius_px;
    wgpuQueueWriteBuffer(g.queue, buf_pu, 0, &pu, sizeof pu);

    WGPUBindGroupEntry pbe[2];
    for (int i = 0; i < 2; ++i) pbe[i] = WGPU_BIND_GROUP_ENTRY_INIT;
    pbe[0].binding = 0; pbe[0].buffer = buf_pu;
    pbe[0].size = sizeof(PointUniforms);
    pbe[1].binding = 1; pbe[1].buffer = buf_pts;
    pbe[1].size = (uint64_t)nmax * sizeof(PcPoint);
    WGPUBindGroupDescriptor pbgd = WGPU_BIND_GROUP_DESCRIPTOR_INIT;
    pbgd.layout = wgpuRenderPipelineGetBindGroupLayout(pipeP, 0);
    pbgd.entryCount = 2;
    pbgd.entries = pbe;
    WGPUBindGroup bgP = wgpuDeviceCreateBindGroup(g.device, &pbgd);
    WGPUBindGroup bgPT = nullptr, bgPB = nullptr;
    if (pipePT) {
        pbgd.layout = wgpuRenderPipelineGetBindGroupLayout(pipePT, 0);
        bgPT = wgpuDeviceCreateBindGroup(g.device, &pbgd);
    }
    if (pipePB) {
        pbgd.layout = wgpuRenderPipelineGetBindGroupLayout(pipePB, 0);
        bgPB = wgpuDeviceCreateBindGroup(g.device, &pbgd);
    }
    pbe[1].buffer = buf_pts_scr;
    pbe[1].size = (uint64_t)nmax * sizeof(PcPoint);
    pbgd.layout = wgpuRenderPipelineGetBindGroupLayout(pipeP, 0);
    WGPUBindGroup bgP_scr = wgpuDeviceCreateBindGroup(g.device, &pbgd);
    pbe[1].buffer = buf_pts_mor;
    WGPUBindGroup bgP_mor = wgpuDeviceCreateBindGroup(g.device, &pbgd);
    WGPUBindGroup bgPT_mor = nullptr;
    if (pipePT) {
        pbgd.layout = wgpuRenderPipelineGetBindGroupLayout(pipePT, 0);
        bgPT_mor = wgpuDeviceCreateBindGroup(g.device, &pbgd);
    }
    pbe[1].buffer = buf_pts_perm;
    pbe[1].size = (uint64_t)kNCorrect * sizeof(PcPoint);
    pbgd.layout = wgpuRenderPipelineGetBindGroupLayout(pipeP, 0);
    WGPUBindGroup bgP_perm = wgpuDeviceCreateBindGroup(g.device, &pbgd);
    WGPUBindGroup bgPT_perm = nullptr;
    if (pipePT) {
        pbgd.layout = wgpuRenderPipelineGetBindGroupLayout(pipePT, 0);
        bgPT_perm = wgpuDeviceCreateBindGroup(g.device, &pbgd);
    }
    WGPUBindGroup bgPB_perm = nullptr;
    if (pipePB) {
        pbgd.layout = wgpuRenderPipelineGetBindGroupLayout(pipePB, 0);
        bgPB_perm = wgpuDeviceCreateBindGroup(g.device, &pbgd);
    }

    // 高斯参照臂的 buffers
    WGPUBuffer buf_gu = nullptr, buf_sp = nullptr, buf_ord = nullptr;
    WGPUBindGroup bgG = nullptr;
    if (pipeG) {
        buf_gu = MakeBuffer(sizeof(RenderUniforms),
            (WGPUBufferUsage)(WGPUBufferUsage_Storage | WGPUBufferUsage_CopyDst));
        buf_sp = MakeBuffer((uint64_t)n_gauss_max * sizeof(ProjectedSplat),
            (WGPUBufferUsage)(WGPUBufferUsage_Storage | WGPUBufferUsage_CopyDst));
        buf_ord = MakeBuffer((uint64_t)n_gauss_max * 4ull,
            (WGPUBufferUsage)(WGPUBufferUsage_Storage | WGPUBufferUsage_CopyDst));
        RenderUniforms gu{};
        gu.img_size[0] = kW; gu.img_size[1] = kH;
        gu.total_splats = n_gauss_max; gu.num_visible = n_gauss_max;
        wgpuQueueWriteBuffer(g.queue, buf_gu, 0, &gu, sizeof gu);
        WGPUBindGroupEntry gbe[3];
        for (int i = 0; i < 3; ++i) gbe[i] = WGPU_BIND_GROUP_ENTRY_INIT;
        gbe[0].binding = 0; gbe[0].buffer = buf_gu;
        gbe[0].size = sizeof(RenderUniforms);
        gbe[1].binding = 1; gbe[1].buffer = buf_sp;
        gbe[1].size = (uint64_t)n_gauss_max * sizeof(ProjectedSplat);
        gbe[2].binding = 2; gbe[2].buffer = buf_ord;
        gbe[2].size = (uint64_t)n_gauss_max * 4ull;
        WGPUBindGroupDescriptor gbgd = WGPU_BIND_GROUP_DESCRIPTOR_INIT;
        gbgd.layout = wgpuRenderPipelineGetBindGroupLayout(pipeG, 0);
        gbgd.entryCount = 3;
        gbgd.entries = gbe;
        bgG = wgpuDeviceCreateBindGroup(g.device, &gbgd);
        if (!bgG) mask_drop |= 0x10u;
    }
    if (!bgP) { result = "bind group failed\n" + g.error_log; return result.c_str(); }

    // ─── 时间戳 ─────────────────────────────────────────────────────────
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
    char nb[128];
    std::string j = "{\n";
    j += "  \"bench\": \"pw_points\",\n";
    j += "  \"date\": \"2026-09-23\",\n";
    j += "  \"tag\": \"" + std::string(tag ? tag : "") + "\",\n";
    j += "  \"adapter\": \"" + g.adapter_name + "\",\n";
    j += "  \"width\": " + std::to_string(kW) +
         ", \"height\": " + std::to_string(kH) + ",\n";
    j += "  \"timestamp_query\": " +
         std::string(g.has_timestamp ? "true" : "false") + ",\n";
    j += "  \"max_storage_binding_bytes\": " +
         std::to_string(g.max_storage_binding) + ",\n";
    j += "  \"max_buffer_bytes\": " + std::to_string(g.max_buffer_size) + ",\n";
    std::snprintf(nb, sizeof nb, "%.2f", radius_px);
    j += "  \"quad_radius_px\": " + std::string(nb) + ",\n";
    j += "  \"point_record_bytes\": 16, \"splat_record_bytes\": 36,\n";
    j += "  \"points_wgsl_sha256\": \"" +
         Sha256Hex(kWgslPoints, std::strlen(kWgslPoints)) + "\",\n";
    j += "  \"gauss_wgsl_sha256\": \"" + std::string(kShaB) + "\",\n";
    j += "  \"K\": " + std::to_string(K) + ", \"R\": " + std::to_string(R) +
         ", \"warmup\": " + std::to_string(warmup) +
         ", \"cell_sel\": " + std::to_string(cell_sel) + ",\n";
    j += "  \"dropped_labels_mask\": " + std::to_string(mask_drop) + ",\n";
    j += "  \"cells\": [\n";

    // ─── 标签 ───────────────────────────────────────────────────────────
    //  0 P  = 裸点云:不透明 + z-buffer 写 + 无 discard + 无 order[]  ← 产品路
    //  1 P2 = 与 P 完全相同的 pipeline/draw,只换轮内位置          ← 噪声底
    //  2 PT = PointList 拓扑(1 顶点 / 1 像素 每点)                ← 下界
    //  3 PB = 同数据、同 VS、同顶点数同片元数,但混合 + 不写深度   ← 画家式(单变量)
    //  4 G  = 高斯泼溅(36 B 记录 + 乱序 order[] + 混合 + discard)  ← 参照
    //  5 PSs= 与 P 完全同一条 pipeline,只是点在 buffer 里按**屏幕分块**排
    //         ← 空间局部性的**上界**(相机固定才排得出来)
    //  6 PSm= 同上,按 **3D 莫顿码**排 ← 产品装载时真能做的那个(与视角无关)
    //  7 PTm= PointList + 莫顿序 ← 两条便宜手段叠加,**产品能做到的最快档**
    static const char* kLabelName[kNL] = {"P", "P2", "PT", "PB", "G",
                                     "PSs", "PSm", "PTm"};
    auto label_ok = [&](int L, uint32_t mask) {
        return ((mask >> L) & 1u) && !((mask_drop >> L) & 1u);
    };
    auto run_block = [&](int L, uint32_t n, std::vector<double>* wall,
                         std::vector<double>* gpu) {
        WGPURenderPipeline pipe = nullptr;
        WGPUBindGroup bg = nullptr;
        uint32_t vc = 0, ic = 1;
        bool dw = false;
        switch (L) {
            case 0: case 1: pipe = pipeP;  bg = bgP;  vc = 6u * n; dw = true; break;
            case 2:         pipe = pipePT; bg = bgPT; vc = n;      dw = true; break;
            case 3:         pipe = pipePB; bg = bgPB; vc = 6u * n; dw = false; break;
            case 4:         pipe = pipeG;  bg = bgG;  vc = 6u * n; dw = false; break;
            // 与 P 同一条 pipeline、同一个 draw,**只有 buffer 里点的次序不同**。
            case 5:         pipe = pipeP;  bg = bgP_scr; vc = 6u * n; dw = true; break;
            case 6:         pipe = pipeP;  bg = bgP_mor; vc = 6u * n; dw = true; break;
            case 7:         pipe = pipePT; bg = bgPT_mor; vc = n;     dw = true; break;
        }
        for (int f = 0; f < K; ++f)
            wall->push_back(RenderOneFrame(rt, pipe, bg, vc, ic, dw, qs,
                                           resolve, (uint32_t)f));
        if (qs) {
            auto v = ReadGpuNs(resolve, qstage, (uint32_t)K);
            gpu->insert(gpu->end(), v.begin(), v.end());
        }
    };

    bool first_cell = true;
    std::vector<PcPoint> pts;
    for (const Cell& c : cells) {
        const double t_cell0 = NowMs();
        GeneratePoints(&pts, c.n, 20260923u);
        UploadChunked(buf_pts, pts.data(), (size_t)c.n * sizeof(PcPoint));
        if (label_ok(5, c.mask)) {
            std::vector<PcPoint> s2 = ScreenTileOrder(pts, pu.viewproj);
            UploadChunked(buf_pts_scr, s2.data(), (size_t)c.n * sizeof(PcPoint));
        }
        if (label_ok(6, c.mask) || label_ok(7, c.mask)) {
            std::vector<PcPoint> s3 = MortonOrder3D(pts);
            UploadChunked(buf_pts_mor, s3.data(), (size_t)c.n * sizeof(PcPoint));
        }

        if (label_ok(4, c.mask)) {
            // 高斯参照:与 bench.mm 的 `r1.5` 格逐项同构(屏幕均匀随机、
            // conic 常数、order 是乱序置换 ⇒ 对 splats[] 随机读)。
            std::mt19937 rg(20260923u);
            const float conic = 9.0f / (radius_px * radius_px);
            std::vector<ProjectedSplat> sp(c.n);
            std::uniform_real_distribution<float> ux(0.f, (float)kW);
            std::uniform_real_distribution<float> uy(0.f, (float)kH);
            for (uint32_t i = 0; i < c.n; ++i)
                sp[i] = {ux(rg), uy(rg), conic, 0.f, conic,
                         0.6f, 0.55f, 0.5f, 0.5f};
            std::vector<uint32_t> ord(c.n);
            std::iota(ord.begin(), ord.end(), 0u);
            std::shuffle(ord.begin(), ord.end(), rg);
            UploadChunked(buf_sp, sp.data(), (size_t)c.n * sizeof(ProjectedSplat));
            UploadChunked(buf_ord, ord.data(), (size_t)c.n * 4);
        }

        // 预热(不计数)
        for (int L = 0; L < kNL; ++L) {
            if (!label_ok(L, c.mask)) continue;
            std::vector<double> dummy_w, dummy_g;
            for (int f = 0; f < warmup; ++f) {
                WGPURenderPipeline pipe = nullptr; WGPUBindGroup bg = nullptr;
                uint32_t vc = 0; bool dw = false;
                switch (L) {
                    case 0: case 1: pipe=pipeP;  bg=bgP;  vc=6u*c.n; dw=true; break;
                    case 2:         pipe=pipePT; bg=bgPT; vc=c.n;    dw=true; break;
                    case 3:         pipe=pipePB; bg=bgPB; vc=6u*c.n; dw=false; break;
                    case 4:         pipe=pipeG;  bg=bgG;  vc=6u*c.n; dw=false; break;
                    case 5:         pipe=pipeP;  bg=bgP_scr; vc=6u*c.n; dw=true; break;
                    case 6:         pipe=pipeP;  bg=bgP_mor; vc=6u*c.n; dw=true; break;
                    case 7:         pipe=pipePT; bg=bgPT_mor; vc=c.n;   dw=true; break;
                }
                RenderOneFrame(rt, pipe, bg, vc, 1u, dw, nullptr, nullptr, 0);
            }
        }

        // 轮内轮换:标签次序按轮号循环旋转 ⇒ 位置效应(热漂移、缓存预热)
        // 在标签之间平衡。轮 = 重复单位,不是帧。
        std::vector<int> labels;
        for (int L = 0; L < kNL; ++L) if (label_ok(L, c.mask)) labels.push_back(L);
        const int nl = (int)labels.size();
        std::vector<double> w[kNL], gv[kNL], round_w[kNL], round_g[kNL];
        for (int r = 0; r < R; ++r) {
            std::vector<double> rw[kNL], rg2[kNL];
            for (int pos = 0; pos < nl; ++pos) {
                const int L = labels[(pos + r) % nl];
                run_block(L, c.n, &rw[L], &rg2[L]);
            }
            for (int L : labels) {
                round_w[L].push_back(Summarize(rw[L]).p50);
                round_g[L].push_back(Summarize(rg2[L]).p50);
                w[L].insert(w[L].end(), rw[L].begin(), rw[L].end());
                gv[L].insert(gv[L].end(), rg2[L].begin(), rg2[L].end());
            }
        }

        // 空 pass 底噪:同一条 pipeline、同一个 render pass,只画 **1 个点**。
        // 量到的基本全是「这一帧固定要付的钱」—— 全屏 clear、分块回写 12 MB
        // 彩色、时间戳自身。**「要不要点预算」直接取决于它**:若固定成本就
        // 已经吃掉大半个帧,减点数买不回帧率。
        std::vector<double> wEmpty, gEmpty;
        {
            for (int f = 0; f < K; ++f)
                wEmpty.push_back(RenderOneFrame(rt, pipeP, bgP, 6u, 1u, true,
                                                qs, resolve, (uint32_t)f));
            if (qs) {
                auto v = ReadGpuNs(resolve, qstage, (uint32_t)K);
                gEmpty.insert(gEmpty.end(), v.begin(), v.end());
            }
        }

        // 阳性对照:同一把尺子量 P 在 N/2 上。≈0.5 才算尺子没坏。
        // ⚠️ N/2 要重新上传点(点数变了),所以放在所有轮之后、只做一次。
        std::vector<PcPoint> half;
        GeneratePoints(&half, c.n / 2, 20260923u);
        UploadChunked(buf_pts, half.data(), (size_t)(c.n / 2) * sizeof(PcPoint));
        std::vector<double> wHalf, gHalf;
        run_block(0, c.n / 2, &wHalf, &gHalf);

        auto series = [&](const std::vector<double>& v) {
            char rb[64];
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
        j += "      \"labels\": [";
        for (size_t i = 0; i < labels.size(); ++i)
            j += std::string(i ? "," : "") + "\"" + kLabelName[labels[i]] + "\"";
        j += "],\n";
        for (int L : labels) {
            j += std::string("      \"") + kLabelName[L] + "_wall_ms\": " +
                 StatsJson(Summarize(w[L])) + ",\n";
            j += std::string("      \"") + kLabelName[L] + "_gpu_ms\": " +
                 StatsJson(Summarize(gv[L])) + ",\n";
        }
        for (int L : labels) {
            j += std::string("      \"round_gpu_p50_") + kLabelName[L] +
                 "\": " + series(round_g[L]) + ",\n";
            j += std::string("      \"round_wall_p50_") + kLabelName[L] +
                 "\": " + series(round_w[L]) + ",\n";
        }
        j += "      \"positive_control_P_halfN_gpu_ms\": " +
             StatsJson(Summarize(gHalf)) + ",\n";
        j += "      \"positive_control_P_halfN_wall_ms\": " +
             StatsJson(Summarize(wHalf)) + ",\n";
        j += "      \"empty_pass_gpu_ms\": " + StatsJson(Summarize(gEmpty)) + ",\n";
        j += "      \"empty_pass_wall_ms\": " + StatsJson(Summarize(wEmpty)) + ",\n";
        std::snprintf(nb, sizeof nb, "%.1f", NowMs() - t_cell0);
        j += "      \"cell_elapsed_ms\": " + std::string(nb) + "\n";
        j += "    }";
    }
    j += "\n  ],\n";

    // ─── 正确性 + 阴性对照 ──────────────────────────────────────────────
    // 要证的命题:**有了深度缓冲就不必排序** —— 也就是「同一批点,换一种
    // buffer 次序画,结果必须逐字节相同」。
    //   ✅ 正向:P(次序1) vs P(次序2) ⇒ 必须 identical
    //   ✅ 阴性:PB(次序1) vs PB(次序2) ⇒ 必须**不同**(混合是次序相关的)
    //      —— 没有这条,上面那个 identical 可能只是因为判据根本不会失败。
    // 深度按洗过的秩分配 ⇒ 逐点互不相同 ⇒ 不存在并列深度这种含糊。
    {
        std::vector<PcPoint> a;
        GeneratePoints(&a, kNCorrect, 20260923u);
        std::vector<PcPoint> b = a;
        std::mt19937 rp(777u);
        std::shuffle(b.begin(), b.end(), rp);
        UploadChunked(buf_pts, a.data(), (size_t)kNCorrect * sizeof(PcPoint));
        UploadChunked(buf_pts_perm, b.data(), (size_t)kNCorrect * sizeof(PcPoint));

        std::vector<uint8_t> r1, r2;
        RenderOneFrame(rt, pipeP, bgP, 6u * kNCorrect, 1u, true,
                       nullptr, nullptr, 0);
        ImgStat s1 = ReadbackImage(rt, &r1);
        RenderOneFrame(rt, pipeP, bgP_perm, 6u * kNCorrect, 1u, true,
                       nullptr, nullptr, 0);
        ImgStat s2 = ReadbackImage(rt, &r2);
        uint64_t diff = 0; int maxabs = 0;
        if (r1.size() == r2.size())
            for (size_t i = 0; i < r1.size(); ++i) {
                int d = std::abs((int)r1[i] - (int)r2[i]);
                if (d) { ++diff; maxabs = std::max(maxabs, d); }
            }

        // 解析期望覆盖率:每点 (2r)² px,面积 W·H。
        const double px_per_pt = (double)(2.0 * radius_px) * (2.0 * radius_px);
        const double expect_cover =
            1.0 - std::exp(-px_per_pt * (double)kNCorrect /
                           ((double)kW * (double)kH));

        j += "  \"correctness_order_independence\": {\n";
        j += "    \"n\": " + std::to_string(kNCorrect) + ",\n";
        j += "    \"order1\": " + ImgStatJson(s1) + ",\n";
        j += "    \"order2\": " + ImgStatJson(s2) + ",\n";
        j += "    \"identical\": " + std::string(diff == 0 ? "true" : "false") +
             ", \"differing_bytes\": " + std::to_string(diff) +
             ", \"max_abs_diff\": " + std::to_string(maxabs) + ",\n";
        std::snprintf(nb, sizeof nb, "%.6f", expect_cover);
        j += "    \"expected_coverage\": " + std::string(nb) + "\n";
        j += "  },\n";

        // 🔴 **直接验那两个真正参与计时的 buffer**。上面那条只证明了「任意
        // 置换不改变输出」,但 buf_pts_scr / buf_pts_mor 的内容是我自己写的
        // 两个重排函数生成的 —— 万一它们不是置换(比如索引重复),buffer 里
        // 就会挤满重复点,画出来仍是 N 个图元却全落在少数像素上:**又快又
        // 错**,而且错得正好长得像「局部性带来 7 倍」。所以必须把这两个
        // buffer 本身画出来比 sha256。
        {
            std::vector<PcPoint> sa = ScreenTileOrder(a, pu.viewproj);
            std::vector<PcPoint> sm = MortonOrder3D(a);
            UploadChunked(buf_pts_scr, sa.data(), (size_t)kNCorrect * sizeof(PcPoint));
            UploadChunked(buf_pts_mor, sm.data(), (size_t)kNCorrect * sizeof(PcPoint));
            std::vector<uint8_t> tmp;
            RenderOneFrame(rt, pipeP, bgP_scr, 6u * kNCorrect, 1u, true,
                           nullptr, nullptr, 0);
            ImgStat q_scr = ReadbackImage(rt, &tmp);
            RenderOneFrame(rt, pipeP, bgP_mor, 6u * kNCorrect, 1u, true,
                           nullptr, nullptr, 0);
            ImgStat q_mor = ReadbackImage(rt, &tmp);
            std::string pt_mor_sha = "n/a";
            double pt_mor_cov = 0;
            if (pipePT && bgPT_mor) {
                RenderOneFrame(rt, pipePT, bgPT_mor, kNCorrect, 1u, true,
                               nullptr, nullptr, 0);
                ImgStat t_mor = ReadbackImage(rt, &tmp);
                pt_mor_sha = t_mor.sha; pt_mor_cov = t_mor.cover;
            }
            j += "  \"correctness_reordered_buffers\": {\n";
            j += "    \"note\": \"the actual buffers used by PSs/PSm/PTm, rendered "
                 "and hashed; must equal the reference order byte for byte\",\n";
            j += "    \"quad_reference\": " + ImgStatJson(s1) + ",\n";
            j += "    \"quad_screen_order\": " + ImgStatJson(q_scr) + ",\n";
            j += "    \"quad_morton_order\": " + ImgStatJson(q_mor) + ",\n";
            j += "    \"quad_scr_matches\": " +
                 std::string(q_scr.sha == s1.sha ? "true" : "false") + ",\n";
            j += "    \"quad_mor_matches\": " +
                 std::string(q_mor.sha == s1.sha ? "true" : "false") + ",\n";
            j += "    \"pointlist_morton_sha256\": \"" + pt_mor_sha + "\",\n";
            std::snprintf(nb, sizeof nb, "%.6f", pt_mor_cov);
            j += "    \"pointlist_morton_coverage\": " + std::string(nb) + "\n";
            j += "  },\n";
            // 计时臂的 buffer 已被这一段改写成 kNCorrect 规模,但 correctness
            // 是整跑的最后一步,后面不再计时,安全。
        }

        // PointList 通路的正确性对照。**必须单独做**:PTm(PointList + 莫顿序)
        // 比 PT(PointList + 随机序)快 7 倍,这么大的效应第一反应就该怀疑
        // 「是不是根本没画」。同一条 PointList pipeline、同一批点、只换 buffer
        // 次序 ⇒ 输出必须逐字节相同,覆盖率也必须一样。
        if (pipePT && bgPT && bgPT_perm) {
            std::vector<uint8_t> t1, t2;
            RenderOneFrame(rt, pipePT, bgPT, kNCorrect, 1u, true,
                           nullptr, nullptr, 0);
            ImgStat u1 = ReadbackImage(rt, &t1);
            RenderOneFrame(rt, pipePT, bgPT_perm, kNCorrect, 1u, true,
                           nullptr, nullptr, 0);
            ImgStat u2 = ReadbackImage(rt, &t2);
            uint64_t d3 = 0; int m3 = 0;
            if (t1.size() == t2.size())
                for (size_t i = 0; i < t1.size(); ++i) {
                    int d = std::abs((int)t1[i] - (int)t2[i]);
                    if (d) { ++d3; m3 = std::max(m3, d); }
                }
            // 1 px 点的解析期望覆盖率:1 - (1 - 1/(W*H))^N
            const double exp_cov = 1.0 - std::exp(-(double)kNCorrect /
                                                  ((double)kW * (double)kH));
            j += "  \"correctness_pointlist_order\": {\n";
            j += "    \"order1\": " + ImgStatJson(u1) + ",\n";
            j += "    \"order2\": " + ImgStatJson(u2) + ",\n";
            j += "    \"identical\": " + std::string(d3 == 0 ? "true" : "false") +
                 ", \"differing_bytes\": " + std::to_string(d3) +
                 ", \"max_abs_diff\": " + std::to_string(m3) + ",\n";
            std::snprintf(nb, sizeof nb, "%.6f", exp_cov);
            j += "    \"expected_coverage\": " + std::string(nb) + "\n";
            j += "  },\n";
        }

        // 阴性对照:同样两种次序,但走画家式(混合 + 不写深度)。
        if (pipePB && bgPB && bgPB_perm) {
            std::vector<uint8_t> n1, n2;
            RenderOneFrame(rt, pipePB, bgPB, 6u * kNCorrect, 1u, false,
                           nullptr, nullptr, 0);
            ImgStat q1 = ReadbackImage(rt, &n1);
            RenderOneFrame(rt, pipePB, bgPB_perm, 6u * kNCorrect, 1u, false,
                           nullptr, nullptr, 0);
            ImgStat q2 = ReadbackImage(rt, &n2);
            uint64_t d2 = 0; int m2 = 0;
            if (n1.size() == n2.size())
                for (size_t i = 0; i < n1.size(); ++i) {
                    int d = std::abs((int)n1[i] - (int)n2[i]);
                    if (d) { ++d2; m2 = std::max(m2, d); }
                }
            j += "  \"negative_control_blended_order\": {\n";
            j += "    \"note\": \"blend+no-depth must be order dependent; "
                 "identical here would mean the ruler cannot fail\",\n";
            j += "    \"order1\": " + ImgStatJson(q1) + ",\n";
            j += "    \"order2\": " + ImgStatJson(q2) + ",\n";
            j += "    \"identical\": " + std::string(d2 == 0 ? "true" : "false") +
                 ", \"differing_bytes\": " + std::to_string(d2) +
                 ", \"max_abs_diff\": " + std::to_string(m2) + "\n";
            j += "  },\n";
        }
    }

    j += "  \"wgpu_errors\": \"" + g.error_log.substr(0, 2000) + "\"\n";
    j += "}\n";

    NSString* dir = [NSString stringWithUTF8String:out_dir];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                             withIntermediateDirectories:YES
                                              attributes:nil
                                                   error:nil];
    NSString* path = [dir stringByAppendingPathComponent:@"points.json"];
    [[NSString stringWithUTF8String:j.c_str()]
        writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    result = std::string([path UTF8String]);
    return result.c_str();
}
