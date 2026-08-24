# 交接任务书:A/B 位姿口径改善研究(2026-08-20 晚)

你接手的是"稠密成品位姿口径"战役的下一阶段:**A(refined 位姿)已判胜但尾巴贵,
B(live 位姿)已判负但承载着"拍完即交付"的产品梦想**。任务=研究如何改善两者。
本文档自包含:项目脉络、设计思路、今晚全部实测、避雷、工具车床、文件总表。

## 一、项目脉络与设计目的(为什么有 A/B 之争)

产品=手机扫描 3.5-5 分钟 → 交付稠密点云(CasDiffMVS 推理+官方融合)。架构已签
(08-18 五连拍板):live 稀疏 SfM 是拍摄期的眼睛和位姿引擎;稠密要**实时生长**
(用户原话"第一帧就出现、每帧都更新");交付绝对无损。

位姿在管线里产出两次:①拍摄期 live_recon(ARKit 锚定+滑窗局部 BA,逐帧就有);
②按完成后 finalize phase-2 全局 BA("refined",10-25s)。稠密推理吃三输入:
位姿 / 逐帧深度范围(稀疏点 1%/99% 分位)/ 有序 top-10 选源——三者都来自稀疏重建。

- **A 口径**:成品稠密用 refined 位姿拍完全量重推 ⇒ 质量最好,但尾巴固定
  ≈ 帧数×2.0-2.7s(A16 冷/热),100 帧≈4 分钟、160 帧≈7 分钟;拍摄期生长只算预览。
- **B 口径**:拍摄期用 live 位姿的推理直接当成品 ⇒ 拍完即交付,但质量今晚被判负。
- **C 口径**(journal:冻结时刻输入推理+终态位姿重融合):尾巴最短,但其质量上限
  =B,B 判负则 C 连坐。**⚠️ 若研究把 B 的质量修好,C 自动复活——它才是终局形态。**

## 二、今晚实测全档(全部可复现,判据预注册)

案卷主文件:`_host_experiments/live_vs_refined_20260820/PREREG.md`(含两次诚实修订,
修订原因都写在里面——读它=读完整案情)。素材:cap41(101 帧)与 cap160(160 帧),
b28 已灭失不可用。

1. **三输入演化(实验二)**:逐位闭包下,深度范围/top-10 跟着稀疏云长到最后一刻
   (cap160 最后 20 步才定格:深度范围 98%/top-10 70%/位姿 52%)⇒ **B-strict
   (MD5 绑终态批)的尾巴≈全量重推,时间上就无意义**;晚期还有全局性事件把旧帧
   位姿摸一遍(incr=off 情况下仍发生,机制未定罪——候选:滑窗 BA 吃进空间近邻旧帧)。
2. **稠密 A/B 对拍(实验一,98 交集帧,单变量自检=两臂网络输入逐字节同)**:
   B 点数 −1.95%(灰区上沿)/ 覆盖 FAIL / **粗糙度 +26.9% 超换种子地板 ~400×** /
   两臂 Umeyama 尺度 **0.9860**、光心残差中位 6.4mm、95/98 帧 top-10 不同。
3. **覆盖差异体检(用户肉眼触发)**:B 体素 +15.4%,其中 71% 贴壳毛边;
4. **全场地板瓦片扫描(用户追问触发)**:A 地板全场平(std 0.6cm);**B 地板局部
   塌陷 ~5cm**(24/163 共同瓦片错位≥3cm 且全是 B 低,28 瓦片双层)。
   真相判定法=平面自洽性。塌陷区特征:离相机远、掠射角、无纹理——live 位姿误差
   在此放大成一致性错误,凑够 geo≥3 存活(与墙面雾"同走廊互证"同族病根)。

**净结论**:refined 全局 BA 修掉的是真几何(尺度 1.4% + 地板塌陷 + 毛壳),
不是仪式。用户价值序:肉眼 > 覆盖 > 粗糙度 > 点数;选区载体视觉必须完美。

## 三、研究方向(按性价比排序,均为 host 零手机实验)

### B 线(修 live 位姿质量;修好则 C 复活="拍完即交付")
1. 🔑 **首选:AETHER_INCREMENTAL_GLOBAL_BA 杠杆**——replay 日志自报 `incr=off`,
   即**拍摄期增量全局 BA 是已装机但默认关的现成开关**(08-11 finalize 法医战役留下,
   全默认关待 env A/B——记忆索引"迭代帽/TVG-FARM"条)。实验:同素材 incr=on 重放
   → live_end 质量是否逼近 refined(整套对拍流水线现成,换个 env 就能跑)。
   顺带量:incr=on 的拍摄期耗时代价(它当年默认关就是因为算力/热)。
2. **尺度真相**:Umeyama 0.986——ARKit(IMU 米制)和全局 BA 谁的尺度对?
   这不只关 B:若 ARKit 才是米制真值,A 的绝对尺度反而偏 1.4%,影响交付测量/AR 摆放。
   实验思路:已知尺寸物体/多采集互证/重力锚与平移先验在 BA 里的权重考古
   (gravity anchors 只锚 roll/pitch,尺度是自由的——查 official_bundle_adjustment_ceres.cc)。
3. **塌陷区机制定罪**:塌陷瓦片位置 vs 相机轨迹/视角掠射度/纹理度的相关分析
   (机制探针,可自研);若定罪=掠射+远距,选源或融合的官方向策略里找对症配方
   (先查 OpenMVS/COLMAP 官方处理,复刻不自研)。
4. 晚期"全局摸位姿"事件定罪:在 dump 快照上做逐帧位姿变更集分析,找触发点
   (滑窗成员?空间回访?)——它决定 C 复活后的真实尾巴。

### A 线(缩尾巴;质量已达标不许动)
5. **#32145 补丁验证与上游 PR**(⑥号线,补丁候选已过独立审查,差运行时验证:
   本机 .deps/ort_build ninja 树增量重编 15-30 分钟跑 h1 冻结复现 572→0+parity)
   ⇒ EXTENDED 解锁=A16 唯一剩余无损提速+推迟热拐点。
6. **BlendedMVG 重训**(⑤号线,用户在训):换 checkpoint=换速度/质量档,
   4 分钟/ckpt 的雾基准现成(run_official_chain.sh 换 CKPT= 即测)。
7. **位姿扰动-质量响应曲线**(机制探针):对 refined 位姿注入受控扰动跑稠密,
   用换种子地板+粗糙度尺标定"多大位姿误差是稠密无害的"——这是将来任何
   "部分复用拍摄期推理"方案的科学地基;但任何据此的生产阈值=自定数字,须用户签。

### 已判死勿复活(案卷里有死因)
fp16 全转 / 降档(num_view=5、小分辨率——用户否决)/ 无验证的容差门(自研违禁)/
B-strict(时间无意义)/ C(在 B 质量修好前连坐)/ 挤水分图切分 / 关键帧筛选。

## 四、工具车床(今晚建好的,全部可复用)

- **host 重放+位姿 dump**:`official_replay_bench_exe <全量db> <fed_frames.jsonl> <out>`
  + env `OFFICIAL_AETHER_LIVE_POSE_DUMP=<dir>`(finalize 进入时刻 dump live_end/)
  + `OFFICIAL_AETHER_LIVE_POSE_DUMP_EVERY=10`(每 10 注册帧 dump 演化快照)。
  101 帧全程 38s;out 目录自带 refined COLMAP bin 模型。二进制已带插桩
  (build-host-fullbench/,Aug 20 10:23)。
- **稠密两臂链**(dense_ab_inputs/ 存了全口径):官方 colmap_input.py(三通道转换)
  → run_arm_lever.py(MPS 推理,固定噪声,~356ms/帧)→ fuse_arm.py(官方融合)
  → measure_arms.py;768×576/num_view=10/官方 filter 一个参数不许动;
  帧集按 image.name 交集;两臂网络输入逐字节自检。
- **分析脚本**(实验目录内,EXP 可传参):analyze_evolution.py(位姿/深度范围逐位
  收敛)、analyze_top10.py(官方 calc_score 语义选源收敛)、analyze_coverage_diff.py
  (体素三集合+贴壳/远分档+连通域)、瓦片扫描(PREREG 补充二内嵌脚本)、
  build_diff_page.py(橙/青叠加查看器生成器,int16 量化 9B/点,DataView 解码)。
- **对比页两张已发布**:并排 B|A(claude.ai/code/artifact/17a73c51-…)、
  鬼层叠加(…/6343a970-…);同文件路径重发布=原链接更新。

## 五、避雷(每条都咬过人)

1. **本机无 /usr/bin/timeout**:`timeout N cmd` exit 127 静默失败——一律
   `perl -e 'alarm N; exec @ARGV' -- cmd`。
2. **iCloud 驱逐**:~/Documents 全境(含 progecttwo!)是同步区,磁盘紧时文件被抽成
   dataless(已中招:cap160 的 db-wal 与 arkit sidecar、Aether3D git 元数据、8145 个
   工件文件)。任何关键输入先 `ls -lO` 查旗;**SQLite 库连 WAL 一起检查,WAL dataless
   =开库 disk I/O error,绕法=只拷主库到 scratchpad 跑**(WAL 逻辑 0 字节时安全)。
3. **aether_cpp 禁一切 git 命令**(挂起);插桩是未提交工作树改动,原文件备份+patch 在
   `_artifacts/live_pose_dump_20260820/`(原 SHA e597e85b…,恢复=cp 回去+重编)。
4. **归档 zpaq 库不能喂重放**(B1 剪枝删了描述子);全量库只在
   `_host_experiments/live_lba_three_arms_20260810/input/` 下。
5. **python3.14 的 cv2 断链**(ffmpeg dylib):diffmvs 链一律 python3.11 或
   `/Users/kaidongwang/.venv/pocketworld/bin/python`。
6. **尾巴度量的快照对齐陷阱**:帧数整除 dump 间隔时"最后快照=终态",跨采集比较必须
   用对齐无关度量(如"最后 N 步内才定格的帧数")——实验二修订一的教训。
7. **跨臂空间比较先 Umeyama 对齐**(尺度差 1.4%,不对齐全是假差异);逐视图一律按
   image.name 配对;top-10 是有序列表。
8. 磁盘只剩 ~4-11GB:中间深度图放 scratchpad,PLY 放实验目录,开工先 df。
9. 18GB 内存:MPS 单帧串行;别开大并发。
10. 长命令输出落盘再读,禁 `| tail` 直连;`pgrep/pkill -f` 用 `"[x]xx"` 写法。
11. WebGL 查看器 9 字节记录必须 DataView 解码(Int16Array 奇偶偏移会炸);
    浏览器面板不开 file://,用 `python3 -m http.server` 临时服。
12. **判据先预注册再跑**;判负照实写;修订留痕;异常旗=停下找用户;
    肉眼终审归用户(真彩并排页,不是散点图);他质疑时先查自己——今晚两次
    ("B 覆盖大"、"地面不重叠")他的眼睛都推进了诊断。
13. 复刻不自研:机制探针可自研证因果,**装机配方必须官方出处**;任何自定阈值
    (容差门、C 的 M 参数)标注自定并等签。
14. host 重放的绝对耗时不可外推真机(历史失真 18-26%);质量结论同机两臂内有效。

## 六、文件总表

- **案卷主目录** `_host_experiments/live_vs_refined_20260820/`:
  PREREG.md(判据+两次修订+三份终审=完整案情)/ DENSE_AB_RESULT.md(实验一全档)/
  evolution_verdict.json + cap160/evolution_verdict.json / coverage_diff_verdict.json /
  dense_A.ply、dense_B.ply、aligned_B.ply / compare_dense_B_vs_A.html /
  coverage_diff_viewer.html / dumps/(cap41 快照)+ cap160/dumps/(16 份)/
  replay_out/ ×2(refined 模型)/ 全部分析脚本 / dense_ab_inputs/(口径存档)
- **插桩存档** `_artifacts/live_pose_dump_20260820/`:原文件备份、live_pose_dump.patch、
  pre_edit_sha.txt、rebuild.log
- **重放器** `~/Developer/Aether3D-cross/aether_cpp/third_party/glomap_vendor/build-host-fullbench/official_replay_bench_exe`;
  插桩源码位置 official_pipeline/src/official_aether_sfm_c.cc:10890 一带(live_end)与
  :10096 一带(演化);incr 开关=env `AETHER_INCREMENTAL_GLOBAL_BA`(用法先 grep bench 源
  third_party/glomap_vendor/bench/sfm_replay_bench.cc 与主源,别猜值)
- **重放素材** `_host_experiments/live_lba_three_arms_20260810/input/`:
  cap_1786414194441541(101 帧,全量 db+fed_frames+已解码 photos_jpg 在
  `_host_experiments/phone_cap_20260811/photos_jpg`)、cap_1786294229793160
  (160 帧,⚠️ WAL dataless,拷主库到 scratchpad 用)
- **稠密链工具**:官方转换 `~/Developer/Aether3D-cross/pocketworld_research_benchmarks/tools/python/diffmvs/colmap_input.py`;
  推理 `_artifacts/lever1_source_reform_20260818/run_arm_lever.py`;融合/量测/建页
  `~/Developer/Aether3D-cross/pocketworld_research_benchmarks/experiments/mvs_pose_ablation_2026-08-18/tools/`;
  CKPT `…/experiments/casdiffmvs_blendmvg_scratch_2026-08-16/ckpts/casdiffmvs_C_long_ep31.ckpt`
- **上级战役文档**:HANDOFF_20260819_four_workstreams.md(四线任务书,②③④⑥全景+
  签字史)、EXECUTION_GATE_20260819_four_workstreams.md、
  VERIFICATION_20260819_report_check.md(两轮核查回执)
- **BA 尺度考古入口**:aether_cpp 的 official_bundle_adjustment_ceres.cc
  (gravity anchors :1535 一带,查尺度自由度);雾基准
  `_artifacts/lever1_source_reform_20260818/run_official_chain.sh`

## 七、汇报纪律

结论先行、判据表并排、口径与代价标齐;>10 分钟必被问进度,长任务先给预计再开跑;
说人话不用比喻;耗时分开报(纯算力 vs 工程开销);产品仓/管线仓任何生产性改动
先出清单等用户签字——本研究线是 host 实验,唯一已存在的管线改动就是那个
默认关的 dump 插桩(去留也待签)。
