# DA3 Multiview Benchmark Rank

Date: 2026-05-24

Purpose: consolidate all current DA3 multiview benchmark evidence into one decision table. Values come from the DA3 benchmark ledger in `Aether3D-cross`, the Plan H history notes, and local CoreML quality/runtime runs.

## Current Answer

| Question | Current answer |
|---|---|
| Best phone-pass RMSE geometry candidate | `DA3-BASE pose K35@476x742 fp16 CoreML`; phone single-run pass at 112.453s / 1480MB peak RSS. |
| Best high-quality runtime candidate | `DA3-BASE pose K35@448x756 fp16 CoreML`; phone single-run pass at 93.196s / 1587MB peak RSS. |
| Best Mac geometry frontier | `K35@476x742` remains the current Mac leader after the five-point and final-tail neighborhood sweeps: RMSE `6.0733`, P90 `8.4533`; phone single-run pass. |
| Best current high-quality phone candidate | `DA3-BASE pose K35@476x742 fp16 CoreML` if geometry is primary; `K35@448x756` if runtime/thermal safety is primary. |
| Best stress-proven fallback | `DA3-BASE pose K30@504x896 fp16 CoreML`; 3-run warm repeat completed without crash, but latency degrades. |
| Why not ship the old best Mac candidate | `K40@504x896` loads, then inference is killed by iOS ActiveHard 3072MB memory limit. |
| Current fast fallback | `K40@392x392 pose-conditioned`; phone-pass and much faster than rectangular `K30@504x896`. |
| Next DA3-only tests | Real PocketWorld capture comparison for `K35@476x742` against `K35@448x756` only if runtime/thermal tradeoff needs visual confirmation. |

## Decision Rank, High To Low

This table is sorted by current product decision value: geometry quality first, then iPhone viability, then runtime/thermal risk. Empty metric cells mean that exact value was not logged for that test family.

## Compact Metric Table

Sorted by current DA3 decision value from high to low.

| 配置 | Mac 推理/组 | Pose RMSE ↓ | Pose P90 ↓ | Edge corr ↑ | 高光 conf ↑ | 手机 CPU 峰值 |
|---|---:|---:|---:|---:|---:|---|
| K35@476x742 | 51.677s | 6.0733 | 8.4533 | 0.1331 | 13.1662 | PASS: one-core 583%; device 97.2%; peak RSS 1480MB |
| K35@476x728 | 45.997s | 6.2234 | 8.9101 | 0.1345 | 13.5979 | 未测：五点邻域第二名，但 RMSE/P90 都没超过 476x742 |
| K35@462x742 | 49.411s | 6.3095 | 9.5132 | 0.1330 | 11.8529 | 未测：RMSE 赢 462x756，但 P90 回退 |
| K35@462x756 | 51.396s | 6.3808 | 9.1589 | 0.1300 | 11.8603 | PASS: one-core 571%; device 95.2%; peak RSS 2136MB |
| K35@476x756 | 54.799s | 6.4008 | 9.1120 | 0.1334 | 12.8343 | 未测：P90 小赢 462x756，但 RMSE/速度不如 476x742 |
| K35@490x728 | 49.018s | 6.4052 | 9.4117 | 0.1337 | 14.5688 | 未测：高光强，但几何回退 |
| K35@490x742 | 50.822s | 6.4081 | 9.3231 | 0.1341 | 13.9900 | 未测：加高没赢，RMSE/P90 都回退 |
| K35@462x728 | 45.713s | 6.4338 | 9.0836 | 0.1335 | 12.7576 | 未测：左下角封口，RMSE/P90 都没超过 476x742 |
| K35@490x756 | 54.654s | 6.4782 | 9.5197 | 0.1314 | 13.5587 | 未测：右上角封口，高光尚可但几何回退 |
| K35@448x742 | 43.128s | 6.4855 | 9.1281 | 0.1334 | 10.8822 | 未测：更快近似打平；P90 比 448x756 只差 0.0126 |
| K34@476x742 | 45.319s | 6.4855 | 9.7137 | 0.1417 | 14.4662 | 未测：K-1 Edge/高光强，但几何回退 |
| K36@476x742 | 50.594s | 6.5187 | 9.4917 | 0.1421 | 14.4257 | 未测：K+1 Edge/高光强，但几何回退 |
| K36@462x756 | 54.187s | 6.5369 | 9.6135 | 0.1403 | 12.7827 | 未测：Edge/高光强，但几何未超过 K35 |
| K35@448x756 | 44.589s | 6.5642 | 9.1155 | 0.1329 | 10.4509 | PASS: one-core 526%; device 87.6%; peak RSS 1587MB |
| K35@462x770 | 52.533s | 6.6606 | 9.5207 | 0.1302 | 10.8326 | 未测：也超过 448x770，但不如 448x756 |
| K35@448x770 | 49.854s | 6.7496 | 9.7523 | 0.1312 | 9.5684 | PASS: one-core 578%; device 96.3%; peak RSS 1676MB |
| K34@448x770 | 46.993s | 6.9716 | 10.0022 | 0.1379 | 10.7924 | 未测：K 轴低一格，几何未超过 K35 |
| K36@448x770 | 52.539s | 7.0086 | 10.3254 | 0.1400 | 10.9137 | 未测：K 轴高一格，几何未超过 K35 |
| K35@420x756 | 40.435s | 6.8052 | 9.9486 | 0.1320 | 7.9228 | 未测：速度候选，但质量已不如 448x756 |
| K35@434x756 | 45.050s | 6.9751 | 9.5650 | 0.1316 | 9.1666 | 未测：旧 P90 强候选，但已不如 448x756 |
| K35@420x770 | 42.881s | 7.0273 | 10.3465 | 0.1296 | 7.1894 | 未测：RMSE 赢基准，P90 略差 |
| K35@434x784 | 47.166s | 7.1321 | 10.2969 | 0.1307 | 7.7026 | 未测：小幅超过基准，收益不大 |
| K35@434x770 | 45.152s | 7.1499 | 10.3079 | 0.1298 | 8.3094 | PASS: one-core 586%; device 97.7%; peak RSS 1856MB |
| K36@434x770 | 46.524s | 7.2423 | 10.8527 | 0.1395 | 9.6831 | 未测：K36 方向几何未超过 |
| K35@448x798 | 51.853s | 7.2360 | 10.5807 | 0.1310 | 8.5543 | PASS: one-core 585%; device 97.4%; peak RSS 1220MB |
| K36@448x798 | 100.440s | 7.1972 | 10.6224 | 0.1372 | 9.7786 | 未测：RMSE 略好但 P90 略差 |
| K35@462x826 | 63.605s | 7.4724 | 10.3020 | 0.1273 | 8.7957 | 未测：P90 近似最好，但 RMSE 明显差 |
| K34@448x798 | 84.823s | 7.4274 | 11.1824 | 0.1346 | 9.5601 | 未测：几何未超过基准 |
| K35@476x840 | 63.162s | 7.5452 | 11.0553 | 0.1263 | 9.7697 | 未测：Mac 强候选 |
| K35@490x868 | 71.115s | 7.5465 | 10.6823 | 0.1246 | 9.4822 | 未测：Mac 强候选 |
| K40@504x896 | 98.201s | 7.8586 | 11.2957 | 0.1316 | 10.5716 | 跑不动：ActiveHard 3072MB；CPU 峰值未返回 |
| K30@504x896 | 53.140s | 8.2872 | 12.0056 | 0.1272 | 10.4548 | PASS: single-run one-core 543%; device 90.4%; 3-run warm repeat completed |
| K35@504x896 | 79.944s | 8.0684 | 11.4105 | 0.1264 | 9.9203 | 未测：Mac 不如更小 K35，手机风险高 |
| K40@448x896 | 79.908s | 8.8149 | 13.2814 | 0.1335 | 6.5498 | 跑不动：per-process-limit 3074MB；CPU 峰值未返回 |
| K40@392x392 | 13.636-21.28s | 9.809-11.6656 | 14.874-17.9116 | 0.1891-0.2722 | 6.598-11.7498 | one-core 576%; device 95.9% |
| K30@336x336 | 4.38s | 10.100 | 15.092 | 0.2689 | 5.973 | one-core 565%; device 94.2% |
| K20@336x336 | 未记录 | 未记录 | 未记录 | 未记录 | 未记录 | one-core 480%; device 79.9% |
| K40@336x336 | 15.87s | 9.913 | 15.088 | 0.2717 | 6.187 | 未测 |
| K30@392x392 | 16.15s | 10.250 | 15.238 | 0.2664 | 6.340 | 未测 |
| K50@392x392 | 27.5448s | 11.7739 | 17.1430 | 0.1816 | 11.6691 | 未测 |
| K60@392x392 | 38.0297s | 12.1395 | 18.1840 | 0.1837 | 11.8603 | one-core 418%; device 69.7%; product fail |
| K40@588x1036 | 187.383s | 8.8680 | 12.7633 | 0.1227 | 11.3690 | 跑不动：BNNS workspace about 3.53GB |
| K30@588x1036 | 107.656s | 8.9662 | 12.5433 | 0.1199 | 11.0043 | 跑不动：iOS 3072MB high-watermark |
| K40@518x1036 | 143.309s | 9.7779 | 14.0057 | 0.1250 | 7.7640 | 取消手机测：Mac 质量弱于 588x1036 |

| Rank | Config | Route | Mac infer/group | Pose RMSE ↓ | Pose P90 ↓ | Edge corr ↑ | Highlight conf ↑ | iPhone status | iPhone infer | Phone CPU peak | Memory / failure note | Read |
|---:|---|---|---:|---:|---:|---:|---:|---|---:|---|---|---|
| 1 | K35@476x742 | pose-conditioned fp16 CoreML | 51.677s | 6.0733 | 8.4533 | 0.1331 | 13.1662 | PASS | 112.453s | one-core 583%; device 97.2% | load 13.627s; peak RSS 1480MB; jetsam 2814->2645MB | New phone-proven geometry winner; best RMSE/P90 and lower RSS than 462x756, with higher CPU load. |
| 2 | K35@476x728 | pose-conditioned fp16 CoreML | 45.997s | 6.2234 | 8.9101 | 0.1345 | 13.5979 | not run |  | 未测 | exported package 794MB | Closest five-point challenger, but both RMSE and P90 lose to 476x742. |
| 3 | K35@462x756 | pose-conditioned fp16 CoreML | 51.396s | 6.3808 | 9.1589 | 0.1300 | 11.8603 | PASS | 115.453s | one-core 571%; device 95.2% | load 20.322s; peak RSS 2136MB; jetsam 2807->2615MB | Previous phone-proven RMSE route; now beaten by 476x742. |
| 4 | K35@462x742 | pose-conditioned fp16 CoreML | 49.411s | 6.3095 | 9.5132 | 0.1330 | 11.8529 | not run |  | 未测 | exported package 788MB | RMSE beats 462x756, but P90 is worse than 476x742 and 462x756. |
| 5 | K35@476x756 | pose-conditioned fp16 CoreML | 54.799s | 6.4008 | 9.1120 | 0.1334 | 12.8343 | not run |  | 未测 | exported package 815MB | P90 slightly beats 462x756, but RMSE/runtime lose to 476x742. |
| 6 | K35@490x728 | pose-conditioned fp16 CoreML | 49.018s | 6.4052 | 9.4117 | 0.1337 | 14.5688 | not run |  | 未测 | exported package 810MB | Strong high-conf row, but geometry regresses versus 476x742. |
| 7 | K35@490x742 | pose-conditioned fp16 CoreML | 50.822s | 6.4081 | 9.3231 | 0.1341 | 13.9900 | not run |  | 未测 | exported package 821MB | Wider/taller variant did not improve geometry. |
| 8 | K35@448x756 | pose-conditioned fp16 CoreML | 44.589s | 6.5642 | 9.1155 | 0.1329 | 10.4509 | PASS | 93.196s | one-core 526%; device 87.6% | load 7.104s; peak RSS 1587MB; jetsam 2801->2615MB | Best high-quality runtime fallback; safest product fallback. |
| 9 | K35@448x742 | pose-conditioned fp16 CoreML | 43.128s | 6.4855 | 9.1281 | 0.1334 | 10.8822 | not run |  | 未测 | exported package 772MB | Faster near-tie challenger; RMSE beats 448x756 and P90 is nearly equal. |
| 10 | K34@476x742 | pose-conditioned fp16 CoreML | 45.319s | 6.4855 | 9.7137 | 0.1417 | 14.4662 | not run |  | 未测 | exported package 756MB | K-1 at champion resolution: edge/highlight improve, geometry regresses. |
| 11 | K36@476x742 | pose-conditioned fp16 CoreML | 50.594s | 6.5187 | 9.4917 | 0.1421 | 14.4257 | not run |  | 未测 | exported package 853MB | K+1 at champion resolution: edge/highlight improve, geometry regresses. |
| 12 | K36@462x756 | pose-conditioned fp16 CoreML | 54.187s | 6.5369 | 9.6135 | 0.1403 | 12.7827 | not run |  | 未测 | exported package 846MB | Edge/highlight improve, but geometry does not beat K35. |
| 13 | K35@462x770 | pose-conditioned fp16 CoreML | 52.533s | 6.6606 | 9.5207 | 0.1302 | 10.8326 | not run |  | 未测 | exported package 808MB | Also beats 448x770, but slower and weaker than the latest frontier. |
| 14 | K35@448x770 | pose-conditioned fp16 CoreML | 49.854s | 6.7496 | 9.7523 | 0.1312 | 9.5684 | PASS | 128.063s | one-core 578%; device 96.3% | load 12.793s; peak RSS 1676MB; jetsam 2809->2618MB | Previous phone-pass fallback; demoted by 448x756 on quality and runtime. |
| 15 | K35@420x756 | pose-conditioned fp16 CoreML | 40.435s | 6.8052 | 9.9486 | 0.1320 | 7.9228 | not run |  | 未测 | exported package 748MB | Fastest near-winner from previous micro sweep. |
| 16 | K35@434x756 | pose-conditioned fp16 CoreML | 45.050s | 6.9751 | 9.5650 | 0.1316 | 9.1666 | not run |  | 未测 | exported package 765MB | Best P90 in the previous micro sweep, but not as strong as 448x756. |
| 17 | K35@434x770 | pose-conditioned fp16 CoreML | 45.152s | 7.1499 | 10.3079 | 0.1298 | 8.3094 | PASS | 82.886s | one-core 586%; device 97.7% | load 12.390s; peak RSS 1856MB; jetsam 2810->2628MB | Fast phone-pass fallback. |
| 18 | K35@448x798 | pose-conditioned fp16 CoreML | 51.853s | 7.2360 | 10.5807 | 0.1310 | 8.5543 | PASS | 158.595s | one-core 585%; device 97.4% | load 17.720s; peak RSS 1220MB; jetsam 2793->2604MB | Previous phone-pass geometry; weaker than 448x756/448x770. |
| 19 | K36@448x798 | pose-conditioned fp16 CoreML | 100.440s | 7.1972 | 10.6224 | 0.1372 | 9.7786 | not run |  | 未测 | exported package 861MB | RMSE/edge/highlight improve over K35@448, but P90 is slightly worse and runtime is much slower. |
| 20 | K35@462x826 | pose-conditioned fp16 CoreML | 63.605s | 7.4724 | 10.3020 | 0.1273 | 8.7957 | not run |  | 未测 | exported package 849MB | P90 is marginally best, but RMSE is clearly worse than 434/448; not the geometry winner. |
| 21 | K34@448x798 | pose-conditioned fp16 CoreML | 84.823s | 7.4274 | 11.1824 | 0.1346 | 9.5601 | not run |  | 未测 | exported package 762MB | Did not beat K35@448 or K35@434 on geometry. |
| 22 | K35@476x840 | pose-conditioned fp16 CoreML | 63.162s | 7.5452 | 11.0553 | 0.1263 | 9.7697 | not run |  | 未测 | exported package 878MB | Stronger highlight/conf than K35@448, but more pixels and slower. |
| 23 | K35@490x868 | pose-conditioned fp16 CoreML | 71.115s | 7.5465 | 10.6823 | 0.1246 | 9.4822 | not run |  | 未测 | exported package 918MB | Similar RMSE to 476, better P90, weaker edge/highlight and higher phone risk. |
| 24 | K40@504x896 | pose-conditioned fp16 CoreML | 98.201s | 7.8586 | 11.2957 | 0.1316 | 10.5716 | INFER FAIL | FAIL after ~219s | not returned; killed before sampler stop | load 19.175s; inference killed at 3,145,731KB / ActiveHard 3072MB | Old best Mac geometry, but not iPhone 14 Pro single-pass viable. |
| 25 | K30@504x896 | pose-conditioned fp16 CoreML | 53.140s | 8.2872 | 12.0056 | 0.1272 | 10.4548 | PASS | single 197.771s; warm repeat 173.626s / 262.815s / 309.580s | single-run one-core 543%; device 90.4% | single peak RSS 1290MB; repeat peak RSS 1069/1270/1311MB; repeat final jetsam avail 2745MB | Stress-proven high-quality fallback; memory/stress viable, but very slow. |
| 26 | K35@504x896 | pose-conditioned fp16 CoreML | 79.944s | 8.0684 | 11.4105 | 0.1264 | 9.9203 | not run |  | 未测 | exported package 959MB | Larger than needed: worse Mac geometry than smaller K35 variants and higher phone risk. |
| 27 | K40@448x896 | pose-conditioned fp16 CoreML | 79.908s | 8.8149 | 13.2814 | 0.1335 | 6.5498 | INFER FAIL | FAIL after ~398s | not returned; CPU resource avg 53% over 170s | load 20.577s; inference killed at 3074MB / per-process-limit | Better than 392 on Mac geometry, but not iPhone 14 Pro single-pass viable. |
| 28 | K40@392x392 | pose-conditioned fp16 CoreML | 13.636-21.28s | 9.809-11.6656 | 14.874-17.9116 | 0.1891-0.2722 | 6.598-11.7498 | PASS | 18.519s | one-core 576%; device 95.9% | peak RSS 1019MB | Current fast mobile fallback. |
| 29 | K30@336x336 | pose-conditioned fp16 CoreML | 4.38s | 10.100 | 15.092 | 0.2689 | 5.973 | PASS | 20.555s | one-core 565%; device 94.2% | peak RSS 1387MB | Conservative fallback; proven but CPU peak is high. |
| 30 | K20@336x336 | pose-conditioned fp16 CoreML |  |  |  |  |  | PASS | 11.912s | one-core 480%; device 79.9% | peak RSS 1560MB | Runtime fallback if K30/K40 thermal repeat fails. |
| 31 | K40@336x336 | pose-conditioned fp16 CoreML | 15.87s | 9.913 | 15.088 | 0.2717 | 6.187 | not run |  |  |  | Better than K30 in Mac square sweep, but K40@392 already passed phone and scored higher. |
| 32 | K30@392x392 | pose-conditioned fp16 CoreML | 16.15s | 10.250 | 15.238 | 0.2664 | 6.340 | not run |  |  |  | More pixels did not help geometry in square sweep. |
| 33 | K50@392x392 | pose-conditioned fp16 CoreML | 27.5448s | 11.7739 | 17.1430 | 0.1816 | 11.6691 | not run |  |  |  | P90 slightly better than K40 in one sweep, but RMSE/edge worse. |
| 34 | K60@392x392 | pose-conditioned fp16 CoreML | 38.0297s | 12.1395 | 18.1840 | 0.1837 | 11.8603 | output pass, product fail | 337.221s | one-core 418%; device 69.7% | later signal 9 memory termination | Not product viable despite finite output. |

## Mac Quality Ceiling And Phone Boundary

These are sorted by Mac geometry quality. They show where quality wants to go, and which rows are actually iPhone 14 Pro single-pass routes.

| Config | Mac infer/group | Pose RMSE ↓ | Pose P90 ↓ | Pose median ↓ | Edge corr ↑ | Conf mean | Highlight conf ↑ | iPhone status | Failure / note |
|---|---:|---:|---:|---:|---:|---:|---:|---|---|
| K35@476x742 | 51.677s | 6.0733 | 8.4533 | 5.4936 | 0.1331 | 10.3499 | 13.1662 | PASS | Phone infer 112.453s; peak RSS 1480MB; device CPU peak 97.2%; new phone-proven geometry winner. |
| K35@476x728 | 45.997s | 6.2234 | 8.9101 | 5.2997 | 0.1345 | 10.6655 | 13.5979 | not run | Five-point neighborhood second place; faster and better edge/highlight, but geometry does not beat 476x742. |
| K35@462x742 | 49.411s | 6.3095 | 9.5132 | 5.2329 | 0.1330 | 9.2685 | 11.8529 | not run | RMSE beats 462x756, but P90 regresses. |
| K35@462x756 | 51.396s | 6.3808 | 9.1589 | 5.6182 | 0.1300 | 9.3248 | 11.8603 | PASS | Phone infer 115.453s; peak RSS 2136MB; device CPU peak 95.2%; previous phone-proven RMSE row. |
| K35@476x756 | 54.799s | 6.4008 | 9.1120 | 5.8213 | 0.1334 | 10.1059 | 12.8343 | not run | P90 slightly beats 462x756, but RMSE is weaker and runtime is higher. |
| K35@490x728 | 49.018s | 6.4052 | 9.4117 | 5.2835 | 0.1337 | 11.4436 | 14.5688 | not run | Higher conf/highlight, but geometry regresses. |
| K35@490x742 | 50.822s | 6.4081 | 9.3231 | 5.7044 | 0.1341 | 11.0054 | 13.9900 | not run | Height +14 over champion did not help geometry. |
| K35@462x728 | 45.713s | 6.4338 | 9.0836 | 5.5897 | 0.1335 | 9.9924 | 12.7576 | not run | Final-tail lower-left check; faster, but RMSE/P90 both lose to 476x742. |
| K35@490x756 | 54.654s | 6.4782 | 9.5197 | 5.8600 | 0.1314 | 10.6552 | 13.5587 | not run | Final-tail upper-right check; high conf, but geometry regresses. |
| K35@448x742 | 43.128s | 6.4855 | 9.1281 | 5.5163 | 0.1334 | 8.5163 | 10.8822 | not run | Faster near-tie; P90 is only 0.0126 worse than 448x756. |
| K34@476x742 | 45.319s | 6.4855 | 9.7137 | 5.7060 | 0.1417 | 11.5187 | 14.4662 | not run | K-1 at champion resolution: edge/highlight improve, geometry regresses. |
| K36@476x742 | 50.594s | 6.5187 | 9.4917 | 5.4088 | 0.1421 | 11.7667 | 14.4257 | not run | K+1 at champion resolution: edge/highlight improve, geometry regresses. |
| K36@462x756 | 54.187s | 6.5369 | 9.6135 | 5.7100 | 0.1403 | 10.3724 | 12.7827 | not run | Edge/highlight improve, but geometry does not beat K35. |
| K35@448x756 | 44.589s | 6.5642 | 9.1155 | 5.6378 | 0.1329 | 8.1777 | 10.4509 | PASS | Phone infer 93.196s; peak RSS 1587MB; device CPU peak 87.6%; best high-quality runtime fallback. |
| K35@462x770 | 52.533s | 6.6606 | 9.5207 | 5.9720 | 0.1302 | 8.4994 | 10.8326 | not run | Also beats 448x770 but not 448x756. |
| K35@448x770 | 49.854s | 6.7496 | 9.7523 | 5.6501 | 0.1312 | 7.4544 | 9.5684 | PASS | Phone infer 128.063s; peak RSS 1676MB; device CPU peak 96.3%; previous phone-pass fallback. |
| K35@420x756 | 40.435s | 6.8052 | 9.9486 | 5.7045 | 0.1320 | 6.0742 | 7.9228 | not run | Mac second place and fastest in the micro sweep. |
| K35@434x756 | 45.050s | 6.9751 | 9.5650 | 5.7181 | 0.1316 | 7.1096 | 9.1666 | not run | Best P90, but RMSE is behind 448x770 and 420x756. |
| K35@420x770 | 42.881s | 7.0273 | 10.3465 | 6.0394 | 0.1296 | 5.4912 | 7.1894 | not run | RMSE improves over K35@434x770, but P90 regresses slightly. |
| K35@434x784 | 47.166s | 7.1321 | 10.2969 | 5.8683 | 0.1307 | 5.8906 | 7.7026 | not run | Tiny geometry gain over K35@434x770; not worth prioritizing. |
| K35@434x770 | 45.152s | 7.1499 | 10.3079 | 6.1436 | 0.1298 | 6.4274 | 8.3094 | PASS | Phone infer 82.886s; peak RSS 1856MB; device CPU peak 97.7%; fast phone-pass fallback. |
| K36@448x798 | 100.440s | 7.1972 | 10.6224 | 5.6642 | 0.1372 | 7.8043 | 9.7786 | not run | RMSE/edge/highlight improve over K35@448, but P90 is slightly worse and runtime is much slower. |
| K35@448x798 | 51.853s | 7.2360 | 10.5807 | 6.3263 | 0.1310 | 6.6004 | 8.5543 | PASS | Phone infer 158.595s; peak RSS 1220MB; device CPU peak 97.4%; previous phone-pass geometry winner. |
| K36@434x770 | 46.524s | 7.2423 | 10.8527 | 5.9385 | 0.1395 | 7.7402 | 9.6831 | not run | K36 at this resolution improves edge/highlight, but geometry is worse. |
| K34@448x798 | 84.823s | 7.4274 | 11.1824 | 5.9071 | 0.1346 | 7.4944 | 9.5601 | not run | Did not beat K35@448 or K35@434 on geometry. |
| K35@462x826 | 63.605s | 7.4724 | 10.3020 | 6.2173 | 0.1273 | 6.7447 | 8.7957 | not run | P90 is marginally best, but RMSE is clearly worse than 434/448. |
| K35@476x840 | 63.162s | 7.5452 | 11.0553 | 6.2494 | 0.1263 | 7.6120 | 9.7697 | not run | Strong quality/highlight balance; second phone candidate if K35@448 passes but highlight is too weak. |
| K35@490x868 | 71.115s | 7.5465 | 10.6823 | 6.4951 | 0.1246 | 7.3656 | 9.4822 | not run | P90 is strong, but more pixels than 476 and weaker edge/highlight. |
| K40@504x896 | 98.201s | 7.8586 | 11.2957 | 7.2031 | 0.1316 | 8.2739 | 10.5716 | INFER FAIL | Loaded in 19.175s; inference killed after ~219s at ActiveHard 3072MB. |
| K35@504x896 | 79.944s | 8.0684 | 11.4105 | 7.3725 | 0.1264 | 7.6453 | 9.9203 | not run | Worse than smaller K35 variants; phone risk is near failed K40@448 token budget. |
| K30@504x896 | 53.140s | 8.2872 | 12.0056 | 7.1667 | 0.1272 | 8.1141 | 10.4548 | PASS | Phone infer 197.771s single-run; 3-run warm repeat completed at 173.626s / 262.815s / 309.580s; repeat peak RSS max 1311MB. |
| K40@448x896 | 79.908s | 8.8149 | 13.2814 | 7.0728 | 0.1335 | 5.1619 | 6.5498 | INFER FAIL | Loaded in 20.577s; inference killed after ~398s at 3074MB per-process limit. |
| K40@588x1036 | 187.383s | 8.8680 | 12.7633 | 7.4278 | 0.1227 | 8.8972 | 11.3690 | LOAD PASS, INFER FAIL | BNNS requested 3,533,322,576 bytes workspace. |
| K30@588x1036 | 107.656s | 8.9662 | 12.5433 | 7.9762 | 0.1199 | 8.6075 | 11.0043 | LOAD PASS, INFER FAIL | Slim test app still hit iOS 3072MB high-watermark in BNNS. |
| K40@518x1036 | 143.309s | 9.7779 | 14.0057 | 8.4763 | 0.1250 | 5.9769 | 7.7640 | CANCELED | Mac quality weaker than 588x1036; phone test not worth it. |
| K40@392x392 | 13.636s | 11.6656 | 17.9116 | 9.5439 | 0.1891 | 9.6850 | 11.7498 | PASS | Best edge proxy and current phone-stable floor. |

## DA3METRIC-LARGE Scale Prior Runs

These runs added DA3METRIC-LARGE as a scale sanity path. The metric prior was not yet fused into the BASE pose/depth metrics, so it added runtime without changing the quality row.

| Route | BASE infer | Metric prior | Total/group | Highlight conf | Pose Sim3 RMSE | Read |
|---|---:|---:|---:|---:|---:|---|
| K30@336 + DA3METRIC-LARGE | 4.62s | 4.08s | 8.71s | 5.973 | 10.100 | Extra scale sanity, not fused quality gain. |
| K30@518 + DA3METRIC-LARGE | 24.12s | 13.61s | 37.73s | 7.223 | 10.666 | Same quality metrics as BASE row because fusion was not included. |

## Next Test Order

1. Treat `K35@476x742` as the DA3-only geometry winner unless real PocketWorld capture comparison contradicts the proxy metrics.
2. Compare real PocketWorld capture quality against `K35@448x756` only if runtime/thermal tradeoff needs visual confirmation.
3. Optional warm/lifecycle repeat only if thermal confidence is needed beyond the single-pass product scenario.
4. Keep `K35@448x756` as the runtime fallback, `K35@462x756` as the old RMSE fallback, and `K40@392x392` as the fast floor.

## Still Missing

| Missing test | Why it matters |
|---|---|
| Real PocketWorld capture manifest benchmark | DTU/bench images do not include handheld focus, exposure, motion, and view-graph problems. |
| Scene class coverage | Need glossy, matte, flat, thin, transparent/black objects, cluttered desks, wall corners, and human-scale scenes. |
| Real capture confirmation for new winner | `K35@476x742` passed phone and wins Mac geometry; compare against `K35@448x756` only if runtime/thermal tradeoff needs visual confirmation. |
| Thermal repeat | Repeat only the final phone-proven winner if we need evidence for hot-device stress beyond normal use. |
| Memory fragmentation / lifecycle | Need cold app, warm app, after capture, after background/foreground. |
| Downstream proxy | DA3 metrics must correlate with SAP/3DGS final geometry, not just DA3 proxy metrics. |
| Scale alignment quality | Record VIO Sim3 residual before/after DA3 output on real captures. |
