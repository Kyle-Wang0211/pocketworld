# sfm_cmp 启动脚本存档(2026-08-23)

来源:`pocketworld-research-benchmarks` 的 `tools/python/sfm_cmp/`,
在提交「删除 sfm_cmp 旧位置」之前从 git 历史(HEAD)取出。

## 为什么单独存这 7 个

08-18 的提交 `4657203`「抢救 sfm_cmp 的 214 个结果文件(5.3MB),之后删掉 7GB
数据本体」把工具链搬到了 `experiments/sfm_cmp_rescue_2026-08-18/` 并已推送远端。
搬过去的**只有 Python 部分**(7 个,逐字节相同),这 6 个 shell 启动脚本
与 `.gitignore` **没有跟着搬**,全仓也没有别的副本。

删除提交之后它们仍在 git 历史里(`git show <删除前的提交>:tools/python/sfm_cmp/...`),
这份存档只是让取用不必翻历史。

## 已逐字节校验

7/7 sha256 与 git 中的版本一致。

## 对应关系

搬过去了、因此**不在**本存档里的 7 个 Python 文件:
  pw_sfm_align.py · sfm_dsp/{align_dsp,align_prod,build_pairs}.py
  sfm_hd/align_hd.py · sfm_v6/{align_v6,robust_align}.py
它们在 `experiments/sfm_cmp_rescue_2026-08-18/` 下,且那边多出 sfm_v7/ sfm_v8/ 两代。
