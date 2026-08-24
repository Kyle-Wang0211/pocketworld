# 核查回执:对执行 agent 2026-08-19 报告的五路按源核查

五路独立核查(ORT 证据链+源码 / ORB-SLAM3 钉死 commit 逐行 / vendored COLMAP+全部调用点 /
DSP-SIFT 特征链 / 执行门文档合同审),结论:**报告核心全部属实**。分项判决与遗留问题如下。

## 1. #32145 定罪 —— CONFIRMED(证据链罕见地干净)

- h1 是真干预实验:仅禁 ConvActivationFusion 即 0 非有限值(CPU parity 2.97e-6),
  control 复现恰 572 NaN 且坏哈希 306dbb… 在 h1/h2/h4/h7 四处独立复现。
- h7 逐元素掩码 FP=0/FN=0,阈值 44.3614=log(FLT_MAX)/2 公式推导非回填,
  边界锋利(44.0→586,44.3614→572,44.42→571);h6 的对称阈值假设被诚实证伪留档。
- 源码闭合:fused 路径发射**裸 WGSL 内建 tanh()**(fuse_utils.cc:76-77);
  独立 Tanh 算子用稳定式 tanh_v=exp(-2|a|) 且注释自引 gpuweb#4458
  (unary_elementwise_ops.h:130-136);GRU/LSTM 各自 clamp 了内建 tanh——全库唯 fuse_utils 漏。
- "修共享 codegen"主张成立:GetActivationSnippet 生成点唯一,恰 6 个消费者
  (conv2d_mm/grouped_conv/conv3d_naive/matmul/matmul_packed/intel matmul),
  修 fuse_utils.cc:77 一行全覆盖;只修 Conv2dMM 会漏 grouped/conv3d。
- 档位自洽:ConvActivationFusion 注册于 Level2(graph_transformer_utils.cc:402),
  EP 白名单含 WebGPU;BASIC 不跑它 → 走稳定 tanh_v → 干净。
- **两个真实限度**:①掩码建立在 h3 未融合运行的代理张量上(CPU/GPU 双掩码同零误差已缓解);
  ②未做"改一行后 NaN 消失"的补丁验证(受不改源码纪律约束)——**上游 PR 必须自带该验证**。

## 2. ORB-SLAM3 门位置/公式 —— 执行 agent 对,我的任务书错(2/3)

钉死 commit 4452a3c 逐行(sha1 双校验):视差角是三角化前的方法选择器
(0.9998 非惯性/0.9996 惯性,纯单目低视差直接丢);极点检查是匹配预门
d²<100·mvScaleFactors[octave](=10·√sf,非 10px·scale),仅纯单目分支生效;
只有重投影 χ² 是真后置门(单目 5.991·σ²,双目 7.8·σ²)。
**HANDOFF ②组已回改**(勘误块+HOLD 状态),原"三道后置门必装"作废。

## 3. COLMAP 平方 Sampson 口径 —— CONFIRMED(规范警告,非现行 bug)

- COLMAP API 层传 px(默认 4.0),内部自己平方(ransac.h:232、two_view_geometry.cc:1058)。
- 我们**确有两个直接吃平方值的入口**:GPU guided kernel maxResidual
  (official_aether_sfm_c.cc:3571,F 模式 4px⇒16.0)与 upright max_squared_sampson_error
  (mandatory_gravity_tvg_v1.cc:106-109)。传 4.0=门收紧到 2px。
- **现行 5 处 TVG 调用点+guided kernel 单位全部正确**,警告针对的是 GTO 装机时的新代码。
- w99 46/100.8px(对称极线距离)⇒Sampson 无固定换算(symEpi≥2×Sampson 且比值无上界),
  分位数不可迁移;要用须同批数据按目标度量重算。

## 4. DSP-SIFT 无 octave —— CONFIRMED,GTO HOLD 有理

FeatureKeypoint 无离散 octave(types.h:52-100);三条提取路径 clamp 后即弃 octave;
落库仅连续 scale(official_aether_sfm_c.cc:8913);TVG 入口只收 2D 点
(mandatory_gravity_tvg_v1.cc:56-64)。逐 octave 门=无米之炊,映射=自创=违禁。
**唯一可装口径=COLMAP known-pose TVG(px 阈值,零 octave 依赖)。**

## 5. 执行门文档(EXECUTION_GATE)—— 骨架合格,4 个真洞 + 6 个瑕疵须补

核心项全过:母版快照与 /workspace 不在可写域;35 项 WIP worktree 隔离;
④闸门=雾<1%+肉眼终审;禁自创公式执行得比 HANDOFF 更严;签字点提前到写入前;
装机≠生效含卸载重装+build_stamp;MD5 绑定同设备。

**真洞(签字前必须补)**:
1. ②组可写域裸列 `sfm_live_recon.dart`(:210),与"live 稀疏一行不碰"冲突
   ——若为遥测,注明"仅限新增遥测字段,匹配/注册/背压逻辑零改动"并单签,否则删。
2. **回退验收整体缺失**:④无"旗开→关旗重采集逐字节回到今日"实测项;
   决定 6 的 processing/recoverable failure 态无故障注入验收;
   ②原子 promotion 事务(:215-217)无中断回滚定义(应=自动回前一 SHA 对)。
3. **GTO HOLD 无解除条件**,签字模板只有"保持 HOLD"一个出口——补:
   HOLD 解除=用户对口径拍板(COLMAP known-pose / 不装 / 签铁律例外)。
4. **依赖图自相矛盾**:第 31 行②环境恢复后可开工 vs 第 127 行②HOLD vs 第 35 行③等②
   accepted ⇒ ③④被无限期阻塞。须二选一写死(建议见下"待用户拍板"第③条)。

**瑕疵**:①②③的旗默认关未成文;"单变量装机"零次出现;ar_capture_page.dart 无
"快门/采集交互零改动"用途限制;my_work_detail_page.dart 新增未给出处;
验收硬编码 132(应写 registered==captured);④失败语义与 HANDOFF 相反(已合规挂签,
用户拍板后须回改落败一方并互引 SHA)。

## 待用户拍板(三件,只有用户能签)

1. **GTO 口径**:唯一能装的是 COLMAP known-pose TVG(px 阈值)。签它(含阈值取默认
   4.0px 还是按重算的 Sampson 分位数),或判②组不装、稀疏管线维持现状。
2. **④失败语义**:旗开但 dense 没做好时——A. 回退交付 sparse(=今日行为,永不空手;
   HANDOFF 原案)vs B. 停在"处理中/可恢复失败"态,绝不把 sparse 报成成功交付
   (执行门提案,理由:铁律 2 语义)。
3. **HOLD 期间③是否解耦先行**:③吃的是 sfm_live_recon 快照,机制上不硬依赖 GTO
   ——建议签"③依赖降为①accepted+现生产匹配器,GTO HOLD 不阻塞③",否则全链停等。

## 环境勘误

- 磁盘 8.5GiB 可用属实(APFS 容器级),但**文件并未被驱逐**(ls -lO 无 dataless 旗,
  全程零读取挂起);aether_cpp 的 git 命令挂起是另一回事(原因未定罪,执行门把
  "Git 元数据恢复+status/diff 只读通过"列为前置是对的)。
- 本机没有 /usr/bin/timeout:`timeout N cmd` 会 exit 127 静默失败——脚本一律改用
  `perl -e 'alarm N; exec @ARGV' -- cmd` 包裹。

---

# 第二轮核查回执(2026-08-19 深夜:执行 agent 六线进度报告)

五路独立核查(含独立重跑与第三次重建),总判决:**报告属实且偏保守,没有"没验说成验了"。**

## ① dense 候选 —— 全部 CONFIRMED(独立重证成功)
154 文件=核查方自算内容哈希对账(非对名字),并用冻结输入**第三次完整重建 7 秒复现
efac60d8… 全部逐位一致**=构建确定性成立;ABI 用 nm/otool 直验(7 导出/0 Ort 泄漏/minos16.3);
三处故障注入重打全部 exit 86 无残渣;契约测试重跑 10/10。两个阻断标签都是
**故意 fail-closed,不是新缺陷**:ACTIVATION_LAYOUT=产品激活目录布局(ACTIVE_GENERATION
单开关)未设计,与神经网络激活/内存布局无关,**不威胁已实测 parity**。
两个补课项:a/b 构建哈希清单与 exit-86 日志在 /private/tmp 会蒸发,**补入 progecttwo/_artifacts**。

## ② GTO —— 执行 agent 阻断正当;主会话"传 16.0"一句被源码 REFUTED(已回改任务书)
已签 calibrated-E 口径下两个被点名入口都在归一化域(正确量级 ≈(4/焦距)²≈1e-6),
手塞 16.0=放宽两百万倍=关门失效。**修正规范已写入 HANDOFF ②组"单位规范"块**:
唯一契约数字=4.0px,归一化/平方交给转换链,16.0 只作 F/H 像素分支回归断言。
Git dataless 阻断亦属实且**定罪**:Aether3D-cross/.git 是指针,真身在
~/Documents/Aether3D/.git/worktrees/Aether3D-cross/,其 HEAD/index 等控制文件被
**iCloud 疏散成 dataless**(Documents 在 iCloud 同步区+磁盘只剩 ~8.5GiB 触发驱逐),
读取即阻塞。恢复=用户联网物化(brctl download 该目录),根治=把仓库迁出 iCloud 同步区。

## ③ 位姿 —— "全零占位"PARTIAL:占位属实,但"拿不到位姿"不成立
零位姿是 Dart 快照的故意合成(零四元数保 _gravityAlign no-op);真实位姿在
Dart _fedMeta(逐帧 ARKit)与 native live_recon(ARKit+窗口 BA)两处都有,缺的只是
一个导出 getter(纯工程)。流式 MD5=官方的已证口径=**位姿固定为终态**(schedule_sim.py
读 in_P16k/sparse),没证位姿演化情形 ⇒ 产生真拍板项"成品位姿口径 A/B"
(已写入 HANDOFF 执行顺序节,推荐 B+一次性 B-vs-A 对拍)。

## ④ 交付 selector —— CONFIRMED(核查方独立重跑 26/26 绿),三条边界须明示
TDD 红绿链真实(TOCTOU 红=rename 后按路径重开读到新文件,修法=绑定句柄;非有限值红=
NaN dense 曾被选中,修法=逐点有限性扫描);断言全是实质内容。边界:
(1)"永不空手"有条件——sparse 自身损坏时返回类型化 null(刻意测试钉死),待用户确认
(建议确认:硬塞坏文件比空手更违反交付无损);(2)文件系统原子 sink(.partial+rename)
是接口契约**未落地实现**,旗当前接在真空里;(3)dense 交付中途失败 rollback+抛错,
模块内不自动重选 sparse(调用方职责)。另:"独立审查 P0/P1/P2 零"**无落盘证据**,视为口头声明。

## ⑥ tanh 补丁 —— 本体全部核实通过(公式与 tanh_v 逐 token 同、六消费者注入点安全、
naga f32/f16 标量/向量独立重验全过、clang-format 干净),距可提 PR 差七件
关键三件:①**补丁后重建轮子跑 h1 冻结复现(572 NaN→0+parity)——必带件,本机现成
macOS WebGPU ninja 树增量重编约 15-30 分钟全离线**(方案在核查产物 E4,含还原步骤);
②OpTester 风格运行时数值测试(现有纯字符串测试对上游太弱);③测试风格对齐目录惯例。
另四件:gtest 真实链接执行一次/对 main 的 rebase 检查+lintrunner/PR 文案(引 #32145+
gpuweb#4458+小|x|精度 trade-off 说明)/push 与 PR 仍需用户显式授权。
两个 PR 技术要点:snippet 变双语句后同作用域二次注入会编译失败(naga 实证,建议加注释
声明契约);公式成为 tanh_v 之外第二份拷贝,PR 里要解释为何不共享。
