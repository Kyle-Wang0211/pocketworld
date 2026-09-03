# Dawn / tint MSL 代码生成调研 —— WGSL 匹配器 1.3-1.6× 差距的机制候选

日期:2026-09-04
范围:线 A(Dawn/tint 代码生成)。目标:找出 WGSL/Dawn 匹配核相对手写 Metal 核
慢 1.3-1.6× 的可归因机制,给出今天就能在主机台架量的刀。
纪律:所有结论打到源码行 / CL / SDK 头文件原文;凡是我没查到的单列在 §9。

**vendored Dawn**:`~/Developer/Aether3D-cross/aether_cpp/third_party/dawn`
revision `a117f96e09e88e76c0a9e3b553b7316cda50633d`(`README.chromium:9`)。
该树已包含 CL 333418(2026-08-18 删除 deprecated load/store),故其快照 ≥ 2026-08-18。
(注:该目录下 `git` 命令会挂住 >2min,本调研全程用文件系统读取,未用 git。)

---

## 0. 结论速览 —— 今天就能在主机台架试的前三刀

| # | 刀 | 改哪一行 | 预期 | 成本 | 可证伪性 |
|---|---|---|---|---|---|
| **1** | **删掉 tint 给 subgroup-matrix 临时变量生成的死零填充** | `src/tint/lang/msl/writer/printer/printer.cc:649-653` 加一个类型守卫 | **MMA 段 −30~40% ⇒ 总 −1.5~2.5ms**(8.7 → 6.2-7.2ms) | 重编 host Dawn + 全量闸 | 强:我已在本机用 Apple Metal 编译器把两种形态编到 AIR 逐条对拍,**去掉零填充后与手写核结构完全同构**(§1.3) |
| **2** | **证伪刀(最便宜,不用重编 Dawn)**:给手写 Metal 核加 `[[max_total_threads_per_threadgroup(512)]]` | `official_gpu_match.mm` 的 `kGemm2KernelSrc` 里 `kernel void pw_match_gemm2` 前加一行 | 不提速,**定位第二机制**:若 native 因此掉到 Dawn 水平 ⇒ 寄存器预算是第二根因 | 改一行 + 跑一次 ABBA,约 10 分钟 | 强:这是两条链在 MSL 源码层唯一的 threadgroup 属性差(§3.1) |
| **3** | **math_mode:`relaxed` → `fast`** | `src/dawn/native/metal/ShaderModuleMTL.mm:427` 一个词 | 影响非 MMA 的 ~3ms 段(scan / acos 门) | 与刀 1 同一次重编,但**必须单变量分开量** | 强:本机实测 Metal 编译器默认就是 `fast`,手写核用的正是默认(§2) |

第四刀(Dawn 独有、native 拿不到的旋钮):`descriptor.threadGroupSizeIsMultipleOfThreadExecutionWidth = YES`
—— 见 §3.2。

---

## 1. 一号嫌疑犯:tint 给每条 MMA / load 生成的**死零填充**(已定案)

### 1.1 上游源码:这个模式是怎么来的

WGSL 的 `subgroupMatrixMultiplyAccumulate` 是**返回值**语义,MSL 的
`simdgroup_multiply_accumulate` 是**出参引用**语义。tint 用一个函数作用域临时 `var` 桥接:

`src/tint/lang/msl/writer/raise/builtin_polyfill.cc:1194-1211`
```cpp
    /// Replace a subgroupMatrixMultiplyAccumulate builtin.
    void SubgroupMatrixMultiplyAccumulate(core::ir::CoreBuiltinCall* builtin) {
        b.InsertBefore(builtin, [&] {
            auto* left = builtin->Args()[0];
            auto* right = builtin->Args()[1];
            auto* acc = builtin->Args()[2];

            // Declare a local variable to receive the result.
            auto* tmp = b.Var(ty.ptr<function>(builtin->Result()->Type()));   // ← 1201 行
            ...
            b.Call<msl::ir::BuiltinCall>(ty.void_(), msl::BuiltinFn::kSimdgroupMultiplyAccumulate,
                                         b.Load(tmp->Result()), left, right, acc);
            b.LoadWithResult(builtin->DetachResult(), tmp);
        });
        builtin->Destroy();
    }
```
`SubgroupMatrixLoad`(同文件 `:1129`)与 `SubgroupMatrixMultiply`(`:1180`)是同一模式。

这个 `b.Var()` **没有 initializer**。MSL printer 对无初始值的 function/private 变量
无条件补零:

`src/tint/lang/msl/writer/printer/printer.cc:646-653`(`EmitVar`,函数体从 `:622` 起)
```cpp
        if (v->Initializer()) {
            out << " = ";
            EmitValue(out, v->Initializer());
        } else if (space == core::AddressSpace::kPrivate ||
                   space == core::AddressSpace::kFunction) {
            out << " = ";
            EmitZeroValue(out, ptr->UnwrapPtr());
        }
```
而 `EmitZeroValue` 对 `SubgroupMatrix` 类型走(同文件 `:1892-1898`):
```cpp
            [&](const core::type::SubgroupMatrix* sm) {
                out << "make_filled_simdgroup_matrix<";
                EmitType(out, sm->Type());
                out << ", " << sm->Columns() << ", " << sm->Rows() << ">(";
                EmitZeroValue(out, sm->Type());
                out << ")";
            },
```

这与我们 09-03 实际 dump 到的 MSL 完全一致(见
`pocketworld_research_benchmarks/experiments/wgsl_matcher_parity_speed_2026-09-03/results/2026-09-03-mixed-mma-result.md`):
```
simdgroup_half8x8  v_46 = make_filled_simdgroup_matrix<half,8,8>(0.0h);
simdgroup_load(v_46, ...);
simdgroup_float8x8 v_49 = make_filled_simdgroup_matrix<float,8,8>(0.0f);
simdgroup_multiply_accumulate(v_49, v_25[v_44], v_48, v_43); v_43 = v_49;
```
手写核是 `simdgroup_multiply_accumulate(c, aFrag[k], bF, c);`
(`aether_cpp/official_pipeline/src/official_gpu_match.mm:1064-1070`,零填充只在 k-循环**外**做一次)。

### 1.2 tint 不会自己消掉它 —— MSL 管线里没有任何 DCE

`src/tint/lang/msl/writer/raise/raise.cc:78-298` 的 pass 清单里**没有** `DeadCodeElimination`。
`grep -rn "DeadCodeElimination(" src/tint/lang/` 只有一个调用点:
`src/tint/lang/spirv/reader/lower/lower.cc:45`(SPIR-V 读入侧)。
而且该 pass 自己的文档(`src/tint/lang/core/ir/transform/dead_code_elimination.h:55-59`)写着
它只删 "Unused functions / Unused `private`, `__in` and `__out` module scoped variables",
**从不删函数变量的死写**。

⇒ 死零填充**保证**进入 MSL 文本。唯一可能救它的是 Apple 的 Metal 编译器。

### 1.3 本机决定性对拍:Apple 的编译器**不会**消掉它(新证据)

我在本机(Xcode `MacOSX26.2.sdk`,`Apple metal version 32023.864`)写了两份最小 MSL,
只差 tint 的临时变量模式,编到 AIR(LLVM IR)对拍。

内层 MMA 循环体的 AIR 调用点:

| 形态 | 循环体内 air 调用 |
|---|---|
| **手写形态** | `simdgroup_matrix_8x8_load` + `simdgroup_matrix_8x8_multiply_accumulate` = **2 条** |
| **tint 形态** | `init_filled.v64f16` + `load` + `init_filled.v64f32` + `multiply_accumulate` = **4 条** |
| **tint 形态去掉零填充** | `load` + `multiply_accumulate` = **2 条**,与手写形态**逐条同构** |

tint 形态的 AIR 原文(`%21`、`%23` 是零填充结果):
```llvm
  %21 = tail call fast <64 x half>  @air.simdgroup_matrix_8x8_init_filled.v64f16.f16(half 0xH0000) #6
  %22 = tail call fast <64 x half>  @air.simdgroup_matrix_8x8_load.v64f16.p3f16(...)               #7
  %23 = tail call fast <64 x float> @air.simdgroup_matrix_8x8_init_filled.v64f32.f32(float 0.0)    #6
  ...
  %27 = tail call fast <64 x float> @air.simdgroup_matrix_8x8_multiply_accumulate...(%26, %22, %19) #6
```
`grep -n "%21|%23"` 在整个 IR 里**只命中它们自己的定义行** —— 即 **use 数为 0,是纯死代码,
优化后仍在**。

不被 DCE 的机制也拿到了:
```llvm
attributes #6 = { convergent nounwind willreturn }      ; init_filled / mma
attributes #7 = { convergent nounwind readonly willreturn }  ; load
```
`#6` **没有 `readnone`/`readonly`** ⇒ LLVM 必须假设 `init_filled` 有副作用,即使返回值无人使用
也不能删。这就是死写活到 AIR 的根因。

复现命令(全部离线,20 秒):
```bash
S=/tmp/mma; mkdir -p $S     # 三份 .metal 见本文附录 A
xcrun metal -std=metal3.2 -S -emit-llvm -o $S/native.ll   $S/native.metal
xcrun metal -std=metal3.2 -S -emit-llvm -o $S/tintlike.ll $S/tintlike.metal
xcrun metal -std=metal3.2 -S -emit-llvm -o $S/patched.ll  $S/patched.metal
diff <(sed -n '/^define/,/^}/p' $S/native.ll) <(sed -n '/^define/,/^}/p' $S/patched.ll)
# 差异只有 SSA 编号顺序与一条 !tbaa 元数据;指令序列与 op 数完全相同
```

### 1.4 收益量级估算

内层循环 op 数 4 → 2。MMA 段占 60-70% × 8.7ms ≈ 5.2-6.1ms。
`init_filled` 每条写 8×8 元素 / 32 lane = f16 1 个 32-bit 寄存器、f32 2 个;
加上两次额外的 convergent intrinsic 发射。若把这两条的成本记为 MMA 自身的 25-40%,
**预期 −1.5~2.5ms,落到 6.2-7.2ms** —— 正好跨过与 native(5.2-6.6ms)的差距带。
这是估算,不是实测;台架会给真数。

### 1.5 具体改法(vendored Dawn 三行补丁)

`src/tint/lang/msl/writer/printer/printer.cc:649-653`:
```cpp
        } else if (space == core::AddressSpace::kPrivate ||
                   space == core::AddressSpace::kFunction) {
+           // [PW] subgroup-matrix 临时变量的零填充在 Apple 编译器里不可 DCE
+           // (air intrinsic 无 readnone 属性),而 tint 的三个 polyfill
+           // (builtin_polyfill.cc:1129/1180/1201) 生成的临时变量都是"先整体写后读"。
+           if (ptr->UnwrapPtr()->Is<core::type::SubgroupMatrix>()) {
+               out << ";";
+               return;
+           }
            out << " = ";
            EmitZeroValue(out, ptr->UnwrapPtr());
        }
```

**语义风险与为什么对我们安全**:这会让**用户自己写的**、无初值的裸
`var m : subgroup_matrix_result<f32,8,8>;` 变成未初始化(违反 WGSL 语义)。
我逐行核过我们的生产 WGSL(`pw-head-0827/vendor/official_sfm/src/pwofficial_gpu_match_dawn.cc:388-420`
与 `:569-600`):
- `var acc = Res(0.0);` —— **有初值**,走 `v->Initializer()` 分支,不受影响;
- `var aFrag : array<Left, 16>;` —— 类型是 **Array**,`EmitZeroValue` 走 Array 分支(`{}`),
  守卫不命中,行为不变(且它在热循环外);
- 没有任何裸的 subgroup-matrix 无初值变量。

⇒ 我们这条链上,守卫**只**命中 tint 自己造的三个 polyfill 临时变量。
仍必须用 696 对逐字节全量闸 + 19 案例 parity 兜底(它们对这类改动是敏感的)。

**风险更低的替代改法**(如果不想碰通用路径):在
`builtin_polyfill.cc` 里给三个 `b.Var(...)` 起一个固定前缀名
(`ir.SetName(tmp->Result(), "tint_sgmat_tmp")`),printer 只对该前缀 + SubgroupMatrix 类型跳过零填充。
多 6 行,语义面缩到最小。

### 1.6 上游是否已知这个模式?—— **没查到任何 issue / CL / toggle**

- Gerrit 全量检索 `q=subgroup matrix`(50 条,2025-05 ~ 2026-09-03)与
  `q=file:"src/tint/lang/msl/writer/raise/builtin_polyfill.cc"`(50 条):
  **没有一条**是关于消除这个临时变量 / 零填充 / SSA 拷贝的。
- 唯一与"Apple 上跑得慢"直接相关的是
  **CL 260594 "DNS: Make subgroup matrix faster on Apple"(James Price,上传 2025-09-04,
  2026-08-19 **ABANDONED**,无废弃理由)**,提交信息原文:
  > - Set subgroup size to 32.
  > - Add overloads of subgroupMatrixLoad/Store that take a pointer-to-scalar, so that
  >   shaders can hoist index calculations out of loops.

  ⇒ 上游确实认为 Apple 上有性能问题,但他们瞄的是**索引计算无法外提**,不是零填充。
  这条路后来被 CL 320355 / 332815 / 330777 的 load/store 重做取代(我们这棵树已是新签名)。
- 零填充是**上游有意为之**:CL 271414 "[msl] Fixup subgroup matrix initialization."
  (MERGED 2025-11-05,`Fixed: 457816671`)原文:
  > An empty construct call is converted to a make filled simdgroup matrix with the
  > appropriate 0 value **to make sure the memory is initialized**.

  (该 CL 针对的是 WGSL 类型构造器;polyfill 临时变量的零填充来自 printer 的
  `EmitVar` 无条件补零,与该 CL 是两处,但意图同源。)
- crbug 正文(`457816671`、`443794633`、`550350271`)需要登录才能读,WebFetch 只拿到
  sign-in 页 ⇒ 未核到原文,只有 CL 提交信息里的转引。**标为不确定,见 §9。**

⇒ **没有 pass、没有 toggle、没有上游修复计划。这条只能自己在 fork 里改。**

---

## 2. math_mode:Dawn 是 `relaxed`,手写核是 `fast`(本机实测定案)

### 2.1 Dawn 强制 relaxed

`src/dawn/native/metal/ShaderModuleMTL.mm:419-437`
```cpp
            // Metal supports math_mode as both compiler option and as a pragma. ...
            // Note: this math_mode takes precedence over global flags provide to the compiler
            // (including the deprecated fastMathEnabled compiler option).
            std::string math_mode_heading;
            if (@available(macOS 15.0, iOS 18.0, *)) {
                math_mode_heading = "\n#pragma METAL fp math_mode(";
                math_mode_heading += r.useStrictMath ? "safe" : "relaxed";   // ← 427
                math_mode_heading += +")\n";
            }
```
`useStrictMath` 来自 `ShaderModuleBase::GetStrictMath().value_or(false)`(`:486`),
我们没设 ⇒ 恒为 `relaxed`。**Metal 只有三档,`fast` 是最高档,Dawn 永远拿不到。**
在 macOS 15 / iOS 18 以下才退回 `compileOptions.fastMathEnabled = !strictMath`(`:523`)。

### 2.2 手写核拿的是编译器默认

`aether_cpp/official_pipeline/src/official_gpu_match.mm:1247-1250`
```objc
    gV2Lib = [gV2Dev
        newLibraryWithSource:[NSString stringWithUTF8String:kGemm2KernelSrc]
                     options:nil  // same defaults as v1 (fast-math on)
                       error:&e];
```

### 2.3 默认到底是哪一档 —— 本机实测(不是推测)

SDK 头文件原文(`MacOSX26.2.sdk/.../Metal.framework/Headers/MTLLibrary.h:254-272, 306-314`):
```
@constant MTLMathModeSafe     Disables unsafe floating-point optimizations
@constant MTLMathModeRelaxed  Allows aggressive, unsafe floating-point optimizations but preserves infs and nans
@constant MTLMathModeFast     Allows aggressive, unsafe floating-point optimizations
...
@property fastMathEnabled ... fastMathEnabled defaults to YES.
@property mathMode  Sets the floating-point arithmetic optimizations. Default depends on the language standard version.
```
"Default depends on the language standard version" 没说是哪档,所以我实测了四个 std:
```
-std=metal3.0 / 3.1 / 3.2 / 4.0,不给任何 math 标志:
  %6 = fdiv fast float ...            ← 与 -fmetal-math-mode=fast 逐字节相同
-fmetal-math-mode=relaxed:
  %6 = fdiv reassoc nsz arcp contract afn float ...   ← 少了 nnan ninf
-fmetal-math-mode=safe:
  %6 = fdiv float ... ; fmuladd 保留
加 `#pragma METAL fp math_mode(relaxed)`:降级到 relaxed(证明 pragma 生效)
```
⇒ **所有 Metal 语言版本的默认都是 `fast`。Dawn 把它降到 `relaxed`,差的是 `nnan ninf`。**

### 2.4 对我们的适用性

我们的 MMA 是整数精确路径(u8→f16 精确、和 ≤262144 在 f32 尾数内),浮点语义档位
**不会**改变 MMA 结果,也几乎不会改变 MMA 吞吐。真正可能吃到的是"其余约 3ms"里的
scan(逐列 max/second-max 比较)与 `gatef` 的 `acos`/比较 —— `nnan`/`ninf` 允许编译器把
比较收成无 NaN 保护的 min/max 选择。

**改法**:`ShaderModuleMTL.mm:427` 把 `"relaxed"` 改成 `"fast"`(建议用 env 开关做单变量)。
**风险**:`acos`/除法在 `fast` 下可能与 `relaxed` 出不同的最后一位 ⇒ 门可能红。
门红本身就是有用信息(说明比较链吃到了),但这刀必须**和刀 1 分开量**。
预期量级:小于刀 1,乐观 −0.3~0.8ms,也可能是 0。

---

## 3. Metal 后端的管线创建选项(逐行核过)

### 3.1 `[[max_total_threads_per_threadgroup]]` —— tint 加了,手写核没加(**方向相反的差异**)

`src/tint/lang/msl/writer/printer/printer.cc:335-341`
```cpp
                    // Tell the MSL compiler how large the threadgroup is going to be.
                    // Without this, the MSL compiler will decide on a maximum threadgroup size
                    // based on its own heuristics. This can result in a pipeline that cannot
                    // support the workgroup size that was specified in the WGSL shader.
                    // See crbug.com/443794633
                    auto total_threads = wg_size[0] * wg_size[1] * wg_size[2];
                    out << "[[max_total_threads_per_threadgroup(" << total_threads << ")]]\n";
```
⇒ **Dawn 生成的 MSL 上有 `[[max_total_threads_per_threadgroup(512)]]`;
我们手写的 `pw_match_gemm2` 上没有**(`grep max_total_threads_per_threadgroup official_gpu_match.mm` = 0 命中)。

这个属性直接影响后端的**每线程寄存器预算**:声明 512 让编译器按 512 线程/threadgroup
分配寄存器;不声明则编译器按自己的启发式挑一个 max(手写路径正是靠
`official_gpu_match.mm:1289` 的 `pso.maxTotalThreadsPerThreadgroup < 512` 事后检查兜底,
说明编译器挑的值确实可能不是 512)。两条链在这里拿的是**不同的寄存器预算**,
对 MMA 这种寄存器密集核是一等嫌疑。

**这是刀 2(证伪刀,最便宜)**:在手写 `kGemm2KernelSrc` 的
`kernel void pw_match_gemm2` 前加 `[[max_total_threads_per_threadgroup(512)]]`,
不动 Dawn,跑一次 ABBA。
- native 变慢到 Dawn 附近 ⇒ **第二机制找到**,而且方向是"Dawn 因为这个属性被限死了寄存器";
  对策是在 Dawn 侧把它去掉或调大(printer.cc:341),并在 TU 里补
  `pso.maxTotalThreadsPerThreadgroup >= 512` 的检查(Dawn 自己没查,见下)。
- native 不变 ⇒ **排除**,省下一次 Dawn 重编。

上游相关:**CL 259074 "[metal] Set the maximum number of threads per threadgroup"
(ABANDONED 2025-11-18,James Price 废弃,无理由)**,原文:
> A Metal compute pipeline may have a lower maximum workgroup size than the device's maximum
> workgroup size when Metal is allowed to determine the maximum workgroup size automatically.
> Exceeding this causes a pipeline to silently fail to execute if backend validation is not enabled.
> Since we know the exact workgroup size that was specific in the shader, we can tell Metal that
> we want to use this as the maximum instead.

⇒ 上游先试了 API 侧(descriptor 属性),废弃了,最后走的是 MSL 源码属性。

### 3.2 Dawn 的 `MTLComputePipelineDescriptor` 只设了两个字段

`src/dawn/native/metal/ComputePipelineMTL.mm:70-80`
```objc
    NSRef<MTLComputePipelineDescriptor> descriptorRef =
        AcquireNSRef([MTLComputePipelineDescriptor new]);
    MTLComputePipelineDescriptor* descriptor = descriptorRef.Get();
    descriptor.computeFunction = computeData.function.Get();
    descriptor.label = label.Get();
    ...
    mMtlComputePipelineState.Acquire([mtlDevice
        newComputePipelineStateWithDescriptor:descriptor
                                      options:MTLPipelineOptionNone
                                   reflection:nil
                                        error:&error]);
```
`grep -rn "threadGroupSizeIsMultipleOfThreadExecutionWidth|maxTotalThreadsPerThreadgroup" src/dawn/native/metal/`
在整个 Metal 后端里**只有 `MultiDrawEncoder.mm` 的 `threadExecutionWidth` 三处**,
和管线创建无关。

⇒ **Dawn 从不设 `threadGroupSizeIsMultipleOfThreadExecutionWidth`,也不设
descriptor 的 `maxTotalThreadsPerThreadgroup`。**

SDK 头文件原文(`MTLComputePipeline.h:45-55`):
```
@property threadGroupSizeIsMultipleOfThreadExecutionWidth
@abstract An optimization flag, set if the thread group size will always be a multiple of thread execution width
@property maxTotalThreadsPerThreadgroup
@abstract Optional property. Set the maxTotalThreadsPerThreadgroup. If it is not set, returns zero.
```

**刀 4(Dawn 独有,native 拿不到)**:在 `ComputePipelineMTL.mm:74` 后加
```objc
    descriptor.threadGroupSizeIsMultipleOfThreadExecutionWidth = YES;
```
前提成立:我们 `@workgroup_size(512)` = 16 × 32,Apple GPU 的 `threadExecutionWidth` 恒为 32。
手写路径走的是 `newComputePipelineStateWithFunction:`(`official_gpu_match.mm:1283`),
**拿不到这个旋钮** ⇒ 这是唯一一把可能让 Dawn 反超 native 的刀。
风险:若某个 pipeline 的 workgroup size 不是 32 的倍数,行为未定义 ⇒ 要么按
`GetWorkgroupSize()` 条件设置,要么只在我们的 TU 用私有 device 上开。
预期量级:未知,业界普遍认为是个位数百分比。

### 3.3 `MTLCompileOptions` 全部字段

`src/dawn/native/metal/ShaderModuleMTL.mm:497-524`,Dawn 只设三个:
- `preserveInvariance = true` —— 仅当 shader 有 `@invariant`(我们没有,不设);
- `enableLogging + languageVersion = MTLLanguageVersion3_2` —— 仅当 `enable_shader_print` toggle 开;
- `fastMathEnabled = !strictMath` —— 仅在 macOS < 15 / iOS < 18;新系统上被 §2 的 pragma 覆盖。

⇒ **除 math_mode 外,Dawn 的编译选项没有比产线更保守的地方。**
`languageVersion` 不设 = 用系统最新,和手写核一致。

### 3.4 还有一个架构性差异:threadgroup 内存是**动态参数**而不是静态数组

`src/tint/lang/msl/writer/raise/module_scope_vars.cc:235-239`
```cpp
                    case core::AddressSpace::kWorkgroup: {
                        // Workgroup variables are received as a function parameter (to workaround
                        // an MSL compiler bug with threadgroup matrices), and we aggregate all
                        // workgroup variables into a structure to avoid hitting MSL's limit for
                        // threadgroup memory arguments.
```
配合 `printer.cc:425-431` 生成 ` [[threadgroup(0)]]` 参数,Dawn 每次 dispatch 用
`ComputePipelineMTL.mm:105` 的 `[encoder setThreadgroupMemoryLength:rounded atIndex:i]` 填大小。

我们手写核是 `threadgroup float Bsh[...]` 静态声明(编译期已知 24KiB)。
⇒ **编译器在编译 Dawn 的核时不知道 threadgroup 内存有多大**,而占用率/寄存器预算的
启发式通常要用到这个数。这是第三个可归因差异,而且**上游自己标注为 workaround**
(注释里说是绕 "an MSL compiler bug with threadgroup matrices",没给 bug 号)。

**测法(便宜、单变量、不用改 Dawn)**:把手写核的 `Bsh`/`accSh` 改成
`threadgroup half* Bsh [[threadgroup(0)]]` 参数 + `setThreadgroupMemoryLength`,
跑 ABBA。native 变慢 ⇒ 机制成立。
**修法很贵**(要改 ModuleScopeVars 让它在尺寸已知时生成静态数组,还要绕开上游
说的那个 MSL 编译器 bug),所以先证伪再决定。列为刀 5。

---

## 4. Dawn toggle 全表(与计算着色器性能相关的)

全表 164 条(`src/dawn/native/Toggles.cpp`)。逐条筛完,与本核相关的只有下面这些;
其余是 D3D/Vulkan/GL 专属、纹理拷贝 blit、查询、缓存等,与我们无关。

| toggle | 源码行 | 官方描述原文 | 对我们 | 风险 |
|---|---|---|---|---|
| `disable_robustness` | `:172` | "Disable robust buffer access" | **已用**,−28% | 越界即 UB;我们靠 zero-padding 不变量兜底 |
| `disable_workgroup_init` | `:223` | "Disables the workgroup memory zero-initialization for compute shaders." | **已用** | 依赖"写后读"不变量;**注意它只管 workgroup 地址空间,管不到 §1 的函数变量零填充** |
| `enable_integer_range_analysis_in_robustness` | `:730` | "Compute the range of the index with Integer Range Analysis in the robustness transform and skip doing index clamping when the out of bound access cannot happen." | 只在 robustness 开着时有意义。**如果哪天要把 robustness 开回来**,这是把边界检查干掉的合法路径(安全性不降) | 低;但对当前配置是 no-op |
| `metal_use_argument_buffers` | `:738` | "Enables the use of Argument Buffers on Metal." | **默认 false**(`PhysicalDeviceMTL.mm:415`,注释 `TODO(crbug.com/363031535): Enable by default when possible`)。我们和手写核一样走逐个 `setBuffer` ⇒ **不是差距来源**,也不建议开(多一层间接) | 中 |
| `disable_polyfills_on_integer_div_and_mod` | `:617` | "Disable the Tint polyfills on integer division and modulo." | 我们的 staging 循环里有 `e / 128u`、`e % 128u`。tint 对**每一条**整数 div/mod 都无条件套除零保护 helper(`binary_polyfill.cc:70-74` 没有常量除数短路,`IntDivMod` 生成 `tint_div_u32(lhs, rhs)` + `select(rhs==0,1,rhs)`)。除数是字面量 128,Metal 编译器内联后大概率折掉 ⇒ **预期 no-op**,但是零风险、顺手可试的小刀 | 低:除零变 UB,我们的除数是编译期常量 128,不可能为 0 |
| `scalarize_max_min_clamp` | `:621` | "Scalarize max, min, and clamp builtins." | 我们的 `min()` 是标量 ⇒ no-op | — |
| `metal_polyfill_clamp_float` | `:627` | "Polyfill clamp function for floating point (metal)." | 我们不用 `clamp` ⇒ no-op | — |
| `saturate_as_min_max_f16` | `:624` | "Polyfill saturate as min and max for f16." | 不用 `saturate` ⇒ no-op | — |
| `metal_disable_module_constant_f16` | `:643` | "Disable module constant hoisting for values that contain f16 types." | 混合核有 f16 常量。默认 off = 允许 hoist(对我们有利),**不要开** | — |
| `metal_replace_workgroup_bool_with_u32` | `:772` | "Replace workgroup bool with u32 for MSL due to CTS failures on Mac AMD and Intel" | 我们 workgroup 里没有 bool ⇒ no-op | — |
| `skip_validation` | `:117` | "Skip expensive validation of Dawn commands." | **CPU 侧** dispatch 开销,不进 GPU 时间。但我们 GPU p50 与 wall 差 ~0.5ms,这里可能吃到一点 | 低(只影响错误诊断) |
| `disable_symbol_renaming` | `:235` | "Disables the WGSL symbol renaming so that names are preserved." | 只影响可读性 | 无 |
| `dump_shaders` | `:—` | 我们已在用(**设备级** toggle,挂 instance 无效) | 编译期 | 无 |

**Metal 后端专属(`metal_*`)一共 18 条**,除上表已列出的 4 条外,其余 14 条全是
纹理/深度模板/时间戳/采样器/顶点的 workaround
(`metal_disable_sampler_compare`、`metal_use_shared_mode_for_counter_sample_buffer`、
`metal_enable_vertex_pulling`、`metal_render_r8_rg8_unorm_small_mip_to_temp_texture`、
`metal_use_mock_blit_encoder_for_write_timestamp`、`metal_disable_timestamp_period_estimation`、
`metal_use_combined_depth_stencil_format_for_stencil8`、
`metal_use_both_depth_and_stencil_attachments_for_combined_depth_stencil_formats`、
`metal_keep_multisubresource_depth_stencil_textures_initialized`、
`metal_polyfill_unpack_2x16_snorm`、`metal_polyfill_unpack_2x16_unorm`、`metal_polyfill_tanh_f16`、
`metal_fill_empty_occlusion_queries_with_zero`、`metal_serialize_timestamp_generation_and_resolution`),
**没有一条**对我们这个纯计算核有性能影响。

⇒ **toggle 这条线基本挖干净了。**唯一没试过的小刀是
`disable_polyfills_on_integer_div_and_mod`(预期 <0.2ms)。

---

## 5. WGSL / tint 能不能表达"编译器提示"?—— **几乎不能**

`src/tint/lang/msl/writer/common/options.h` 里 MSL writer 的**全部**选项:
`entry_point_name`、`remapped_entry_point_name`、`strip_all_names`、`disable_robustness`、
`disable_integer_range_analysis`、`disable_workgroup_init`、`emit_vertex_point_size`、
`disable_polyfill_integer_div_mod`、`use_argument_buffers`、`workarounds{8 个 polyfill 开关}`、
`extensions{disable_demote_to_helper}`、`fixed_sample_mask`、`pixel_local_attachments`、
`array_length_from_constants`、`vertex_pulling_config`、`immediate_binding_point`、
`group_to_argument_buffer_info`、`depth_range_offsets`、`bindings`、`substitute_overrides_config`。

⇒ **没有 unroll 提示、没有 no-bounds-check 之外的优化开关、没有 MSL 编译选项透传、
没有任何 pragma / attribute 注入点。** WGSL 语言本身也没有 unroll 属性
(`@must_use` 只有语义作用,`@diagnostic` 只控诊断)。

唯一沾边的两个:
1. **`override` 常量替换**(`SubstituteOverrides`,`raise.cc:81`)—— override 在管线创建时被
   代换成字面常量,循环边界因此变成编译期常量、可展开。
   **我们已经不需要**:生产 WGSL 的循环边界本来就是字面量
   (`for (var k = 0u; k < 16u; ...)`、`nt < 4u`,见
   `pwofficial_gpu_match_dawn.cc:414/412`),Metal 编译器该展开的信息已经齐了。
2. **手工在 WGSL 里展开** —— 已判死,不再提。

**结论**:线 A 的杠杆只有两种形态 —— 改 vendored Dawn 源码,或开 toggle。没有第三条。

---

## 6. 上游同类基准:**没有找到 WGSL/Dawn vs 原生 Metal 的 subgroup-matrix 对照数据**

我查了:
- Dawn 自带的 perf 测试目录 `src/dawn/tests/perf_tests/`:
  `BufferUploadPerf / ConcurrentExecutionTest / DrawCallPerf / LoadStoreOpPerfTest /
  MatrixVectorMultiplyPerf / ShaderRobustnessPerf / SubresourceTrackingPerf /
  UniformBufferUpdatePerf / VulkanZeroInitializeWorkgroupMemoryPerf / WorkgroupAtomicPerf`
  —— **没有 subgroup-matrix perf 测试**。subgroup matrix 只出现在
  `src/dawn/tests/end2end/SubgroupMatrixTests.cpp`(正确性)。
- Dawn 的 feature 文档 `docs/dawn/features/subgroup_matrix.md`:是设计文档,**没有任何性能数字**。
- ONNX Runtime PR microsoft/onnxruntime#23729(WebGPU EP 的 Metal subgroup-matrix MatMulNBits):
  Phi-3.5-mini 1K prefill 从 `avg (us): 1.45507e+07`(68.79 tok/s)降到 `5.42498e+06`
  (184.52 tok/s),**约 3×** —— 但基线是**同为 WebGPU 的非 subgroup-matrix 实现**,
  **不是原生 Metal/MPS**。报告者 Sushanth Rajasankar。
- Chrome 团队的 subgroups 公开数字(developer.chrome.com/blog/new-in-webgpu-134 等)
  也全是 "WebGPU 新旧对比",没有 vs 原生。
- nuss-and-bolts 的 WebGPU matmul 系列(M2 Pro,>1 TFLOP/s,理论峰值 ~6 TFLOP/s):
  **明确说明没有做原生对照**。

⇒ **"1.3-1.6× 在业界属于什么水平"这个问题,公开资料回答不了。**
我们自己这条 696 对逐字节 + ABBA 的台架,很可能就是目前最严格的 WGSL-vs-原生-Metal
subgroup-matrix 对照数据。这本身是一个可对外的结论,但不能拿别人的数字给它定位。

---

## 7. 上游 CL 清单(subgroup matrix 相关,2025-05 ~ 2026-09-03,Gerrit 全量)

只列与性能/Metal 直接相关的:

| CL | 标题 | 状态 | 对我们的意义 |
|---|---|---|---|
| [260594](https://dawn-review.googlesource.com/c/dawn/+/260594) | DNS: Make subgroup matrix faster on Apple | **ABANDONED** 2026-08-19 | 上游承认 Apple 上慢;方向是 subgroup size=32 + pointer-to-scalar load/store 外提索引。**已废弃,无理由** |
| [259074](https://dawn-review.googlesource.com/c/dawn/+/259074) | [metal] Set the maximum number of threads per threadgroup | **ABANDONED** 2025-11-18 | API 侧设 descriptor 属性;废弃后改走 MSL 源码属性(printer.cc:341)。见 §3.1 |
| [271414](https://dawn-review.googlesource.com/c/dawn/+/271414) | [msl] Fixup subgroup matrix initialization. | MERGED 2025-11-05 | 零填充的意图来源(`Fixed: 457816671`) |
| [337135](https://dawn-review.googlesource.com/c/dawn/+/337135) | [metal] Add Dawn toggle and Tint option for TensorsOps | MERGED 2026-08-27,**当天被 Brandon Jones revert**(`I1b0147f9...`) | Metal 4 tensor ops 路径(F16 32×32×32)。**我们的树里没有**(`grep Tensor Toggles.cpp` = 0)。这是上游正在铺的第二条 MMA 路径,值得季度性回看 |
| [338755](https://dawn-review.googlesource.com/c/dawn/+/338755) | [msl] Validate subgroup matrix configurations for tensors | MERGED 2026-09-02 | 同上,tensor 路径在推进 |
| [330777](https://dawn-review.googlesource.com/c/dawn/+/330777) | [wgsl][ir] Relaxed subgroupMatrixLoad/Store array requirements | MERGED 2026-08-12 | 我们的树已含 |
| [333418](https://dawn-review.googlesource.com/c/dawn/+/333418) | [msl] Remove support for deprecated load/store builtins | MERGED 2026-08-18 | 用来定我们树的下界日期 |

**没有任何一条**是消除 §1 死零填充的。

---

## 8. 推荐执行顺序(主机台架:parity 19 案例 + 696 对逐字节全量闸 + 镜像 ABBA)

严格单变量,一次一刀,每刀跑完整门。

1. **刀 2(证伪,最便宜,不重编 Dawn)** —— 手写核加 `[[max_total_threads_per_threadgroup(512)]]`。
   ~10 分钟。结果决定后面要不要动 printer.cc:341。
   *注意:改了手写核 = 改了 native 参照臂,量完必须改回来,否则后续所有对照都失去基线。*
2. **刀 1(主刀)** —— printer.cc 死零填充守卫,重编 host Dawn,全量闸 + ABBA。
   这是预期收益最大的一刀。
3. **刀 3** —— `math_mode(fast)`,与刀 1 分开量。
4. **刀 4** —— `threadGroupSizeIsMultipleOfThreadExecutionWidth = YES`。
5. **刀 5(仅当刀 1-4 之后仍有 >15% 缺口)** —— 在 native 臂把 threadgroup 内存改成动态参数,
   证伪 §3.4。证实了再考虑改 ModuleScopeVars。
6. 小刀:`disable_polyfills_on_integer_div_and_mod`(预期 <0.2ms,顺手)。

**上机纪律提醒**(来自 09-01 的账):每一刀都要留每张毫秒对照;验过就提交打 tag。
刀 1 若上机,`build_xcframework.sh` 的 `PWOFFICIAL_DAWN_SHA256` 钉子要同步更新并记 PROVENANCE。

---

## 9. 未查到 / 不确定(明确列出,不糊)

1. **crbug 正文没读到**:`457816671`(subgroup matrix 初始化)、`443794633`
   (max_total_threads_per_threadgroup)、`550350271`(TensorOps)。
   issues.chromium.org 是需要登录的 SPA,WebFetch 只拿到 sign-in 页。
   我引用的全部是 Gerrit 提交信息里的转引,**不是 bug 原文**。
2. **`init_filled` 在 Apple GPU ISA 上到底几个周期**:AIR 层证明了它活到后端输入,
   但 metallib → GPU ISA 这一段不可见(Apple 不开放 ISA 反汇编)。
   **理论上后端仍可能删掉它** —— 这就是为什么刀 1 必须上台架量,不能只信 AIR。
3. **`fast` vs `relaxed` 对我们 scan 段的实际影响**:只知道差 `nnan ninf`,
   没做过指令级对拍。
4. **module_scope_vars.cc:236 说的 "MSL compiler bug with threadgroup matrices"**:
   注释里没给 bug 号,Gerrit 检索也没找到对应 CL。这个 workaround 的具体触发条件不明。
5. **我们的 vendored Dawn 精确 upstream 日期**:`README.chromium` 只给了 revision
   `a117f96e...`;`dawn.googlesource.com/dawn/+/a117f96e...?format=JSON` 返回 404
   (可能是 Chromium 侧镜像 revision),目录 `git` 命令挂死。
   我用"含 CL 333418、不含 TensorOps toggle(337135)"把它夹在 **2026-08-18 ~ 2026-08-27** 之间。
6. **业界 WGSL-vs-原生-Metal subgroup-matrix 对照**:确认不存在公开数据(§6)。
   不是"我没找到",是查完 Dawn perf tests / Dawn 文档 / ORT / Chrome 博客 / 社区 matmul 文章后
   的**否定结论**。

---

## 附录 A:§1.3 的三份最小 MSL(逐字可复现)

`native.metal`(手写形态):
```metal
#include <metal_stdlib>
#include <metal_simdgroup_matrix>
using namespace metal;
kernel void k(device float* out, device const half* A, threadgroup half* Bsh,
              uint lid [[thread_index_in_threadgroup]]) {
  simdgroup_matrix<half,8,8> aFrag[16];
  for (uint k=0;k<16;k++) simdgroup_load(aFrag[k], A, 128, ulong2(0,0), false);
  simdgroup_matrix<float,8,8> c = make_filled_simdgroup_matrix<float,8,8>(0.0f);
  for (uint k=0;k<16;k++) {
    simdgroup_matrix<half,8,8> bF;
    simdgroup_load(bF, Bsh, 128, ulong2(0,0), true);
    simdgroup_multiply_accumulate(c, aFrag[k], bF, c);
  }
  simdgroup_store(c, out, 32, ulong2(0,0), false);
}
```
`tintlike.metal`:同上,但三处临时变量改成
`simdgroup_matrix<half,8,8> v_46 = make_filled_simdgroup_matrix<half,8,8>(0.0h);` /
`simdgroup_matrix<float,8,8> v_49 = make_filled_simdgroup_matrix<float,8,8>(0.0f);`,
且 mma 写成 `simdgroup_multiply_accumulate(v_49, aFrag[k], v_46, c); c = v_49;`
(完全照 09-03 dump 的形状)。
`patched.metal`:把 `tintlike.metal` 里三处 ` = make_filled_simdgroup_matrix<...>(0)` 删掉。

`math_mode` 实测用例:
```metal
#include <metal_stdlib>
using namespace metal;
kernel void k(device float* o, device const float* a) { o[0] = a[0]/a[1] + a[2]*a[3]; }
```
```bash
for M in "" -fmetal-math-mode=safe -fmetal-math-mode=relaxed -fmetal-math-mode=fast; do
  xcrun metal -std=metal3.2 $M -S -emit-llvm -o - mm.metal | grep -E 'fdiv|fmul|fadd|fmuladd'
done
```
