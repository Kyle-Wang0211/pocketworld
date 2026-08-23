// 改名冷却 —— 抽成独立文件是为了能被测试 import。
//
// ⚠️ 不要把这类纯函数留在 set-profile-name/index.ts 里:那个文件顶层是
//    `Deno.serve(...)`,import 它就会启 HTTP 服务,deno test 会直接报
//    "This error was not caught from a test ... top-level code" 而整体失败。
//    upload-finalize 就踩过这个坑 —— 它的 12 个 validate 用例因此**从未真正
//    跑过**,直到 2026-08-23 抽出 validate.ts 才第一次执行。同样的错不要犯第二次。

/**
 * 改名冷却期:3 天。
 *
 * 依据是 Discourse 的 `username_change_period` 默认值(单位:天),被数万站点
 * 验证过 —— 不是拍脑袋的数字。它同时服务两件事:
 *   · 合规:《互联网用户账号信息管理规定》第十五条要求"适时核验存量账号信息",
 *     无限频改名会让核验失去意义;
 *   · 成本:每次改名都要走一遍审核链路,不限频等于把调用量交给对方决定。
 */
export const RENAME_COOLDOWN_MS = 3 * 24 * 60 * 60 * 1000;

/**
 * 返回还需等待的毫秒数;0 表示可以改。
 *
 * 首次设置(from 为 null)不受冷却限制 —— 新用户设第一个名字不该被挡。
 * 无法解析的时间戳按"可以改"处理:宁可放行一次改名,也不要因为一条脏数据
 * 把用户永久锁死在旧名字上。
 */
export function cooldownLeft(from: string | null, now: number): number {
  if (!from) return 0;
  const last = Date.parse(from);
  if (Number.isNaN(last)) return 0;
  const left = RENAME_COOLDOWN_MS - (now - last);
  return left > 0 ? left : 0;
}
