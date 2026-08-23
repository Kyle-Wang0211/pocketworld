#!/usr/bin/env node
// IP 属地库导入器 —— ip2region → public.ip_region_ranges
// =====================================================================
// 用法(在仓库根目录):
//
//   # 1) 只生成 CSV,先肉眼验一眼(不联库,安全)
//   node tool/import_ip2region.mjs --csv-only
//
//   # 2) 真正导入(需要 service_role key,会**清空并重建**整张表)
//   SUPABASE_URL=https://xxxx.supabase.co \
//   SUPABASE_SERVICE_ROLE_KEY=sb_secret_xxx \
//   node tool/import_ip2region.mjs
//
//   # 只导 IPv4(省磁盘;Supabase 免费档 500MB 时用)
//   node tool/import_ip2region.mjs --skip-v6
//
//   # 用本地已下好的源文件,不联网
//   node tool/import_ip2region.mjs --v4 ./ipv4_source.txt --v6 ./ipv6_source.txt
//
// 迁移到自建 PostgreSQL(阿里云)后,更省事的是走 psql:
//   node tool/import_ip2region.mjs --csv-only
//   psql "$DATABASE_URL" -c "truncate public.ip_region_ranges" \
//     -c "\copy public.ip_region_ranges (ip_start, ip_end, region) from 'ip_region_ranges.csv' csv"
//
// ---------------------------------------------------------------------
// 数据源:github.com/lionsoul2014/ip2region,Apache-2.0,可商用。
// ipv4_source.txt / ipv6_source.txt 每行 7 段,`|` 分隔:
//   起始IP|结束IP|国家|省份|城市|ISP|ISO国家码
//   1.0.1.0|1.0.3.255|中国|福建省|福州市|中国电信|CN
//   1.0.0.0|1.0.0.255|Australia|Queensland|0|0|AU
// 缺失值一律是字符串 "0"。境外行的国家名是**英文**。
//
// 🔑 港澳台在该库里 ISO 码就是 CN,省份是"香港特别行政区/澳门特别行政区/
//    台湾省" —— 与要展示的口径一致,不需要特殊处理。
//
// 零依赖:Node 18+ 的内建 fetch + 流式按行解析。不装 pg,因为本机没有
// psql/pg,而且走 PostgREST 的路径在阿里云自建后同样能用(Supabase 兼容层)。

import fs from 'node:fs';
import path from 'node:path';
import readline from 'node:readline';
import { Readable } from 'node:stream';

const SRC = {
  v4: 'https://raw.githubusercontent.com/lionsoul2014/ip2region/master/data/ipv4_source.txt',
  v6: 'https://raw.githubusercontent.com/lionsoul2014/ip2region/master/data/ipv6_source.txt',
};

// ── 国家中文名:用 CLDR,不手写 240 条对照表 ─────────────────────────
// Intl.DisplayNames 的数据就是 CLDR(ICU),Node 内建、随版本更新。
// 手写对照表是"自研"—— 会漏、会过时、也没人复核。
const DISPLAY = new Intl.DisplayNames(['zh-CN'], { type: 'region' });
const countryZh = (iso) => {
  if (!iso || iso === '0' || iso.length !== 2) return null;
  const code = iso.toUpperCase();
  // 🔴 ZZ 是 CLDR 保留的"未知地区"码,DisplayNames 会**成功**返回
  //    中文字符串「未知地区」。不显式排掉的话,它会当成一个正常国家名
  //    落进 region 列,前端就显示「IP属地:未知地区」。
  //    (拿不到属地的正确表现是**不展示那一行**,不是展示"未知"。)
  if (code === 'ZZ') return null;
  try {
    const n = DISPLAY.of(code);
    // 码本身查不到时,DisplayNames 把输入原样吐回来(如 "QQ" → "QQ")。
    return n && n !== code ? n : null;
  } catch {
    return null;
  }
};

// ── 省份短称 ────────────────────────────────────────────────────────
// 展示粒度照抄 2022 年全行业统一落点(微博/抖音/小红书/B站/知乎):
// 境内到省(区、市),境外到国家(地区)。不比同行更细 —— 更细 = 无谓的
// 隐私暴露,《个人信息保护法》第六条"最小必要"。
//
// ip2region 的省份取值是**封闭集合**(实测 34 个值 + "0"),所以这里不是
// 猜规则,是把那 34 个值逐一落到短称上。ip2region 自己的地名标准是:
//   "新疆/西藏等自治区使用短称,香港/澳门等特别行政区使用长称,
//    直辖市携带'市'行政单位,其他统一使用带'省'的全称"
const PROVINCE_ZH = {
  '北京市': '北京', '天津市': '天津', '上海市': '上海', '重庆市': '重庆',
  '河北省': '河北', '山西省': '山西', '辽宁省': '辽宁', '吉林省': '吉林',
  '黑龙江省': '黑龙江', '江苏省': '江苏', '浙江省': '浙江', '安徽省': '安徽',
  '福建省': '福建', '江西省': '江西', '山东省': '山东', '河南省': '河南',
  '湖北省': '湖北', '湖南省': '湖南', '广东省': '广东', '海南省': '海南',
  '四川省': '四川', '贵州省': '贵州', '云南省': '云南', '陕西省': '陕西',
  '甘肃省': '甘肃', '青海省': '青海', '台湾省': '台湾',
  '内蒙古': '内蒙古', '广西': '广西', '西藏': '西藏', '宁夏': '宁夏',
  '新疆': '新疆',
  '香港特别行政区': '香港', '澳门特别行政区': '澳门',
};

/** 一行 → 展示串;拿不到就 null(前端不展示,而不是展示"未知")。 */
export function regionOf(country, province, iso) {
  if (iso === 'CN') {
    if (province && province !== '0') {
      const short = PROVINCE_ZH[province];
      if (short) return short;
      // 🔴 未登记的取值一律**降到"中国"**,绝不原样输出。
      //    这不是保守起见 —— ipv6_source.txt 里真的有 20 段把**城市**写进了
      //    省份列(武汉 ×10、广州 ×10,城市列同为"武汉市/广州市")。
      //    原样输出就会显示「IP属地:武汉」,比我们承诺的省级粒度更细,
      //    正是《个人信息保护法》第六条"最小必要"要避免的过度披露。
      //    宁可粗一级,不可细一级。
      process.emitWarning(`未登记的省份取值,已降级为"中国": ${province}`);
      return '中国';
    }
    return '中国';           // 省份未知但确定在境内
  }
  return countryZh(iso);     // 境外:走 CLDR,忽略源文件里的英文名
}

// ── 解析 ────────────────────────────────────────────────────────────
async function* lines(src) {
  let stream;
  if (/^https?:/.test(src)) {
    const res = await fetch(src);
    if (!res.ok) throw new Error(`${src} → HTTP ${res.status}`);
    stream = Readable.fromWeb(res.body);
  } else {
    stream = fs.createReadStream(src);
  }
  yield* readline.createInterface({ input: stream, crlfDelay: Infinity });
}

function csvCell(v) {
  if (v == null) return '';
  return /[",\n]/.test(v) ? `"${v.replace(/"/g, '""')}"` : v;
}

async function main() {
  const argv = process.argv.slice(2);
  const flag = (n) => argv.includes(n);
  const opt = (n, d) => {
    const i = argv.indexOf(n);
    return i >= 0 && argv[i + 1] ? argv[i + 1] : d;
  };

  const csvOnly = flag('--csv-only');
  const skipV6 = flag('--skip-v6');
  const outPath = path.resolve(opt('--out', 'ip_region_ranges.csv'));

  const sources = [opt('--v4', SRC.v4)];
  if (!skipV6) sources.push(opt('--v6', SRC.v6));

  const out = fs.createWriteStream(outPath, { encoding: 'utf8' });
  let total = 0, resolved = 0, bad = 0;
  let prevStart = null;

  for (const src of sources) {
    process.stderr.write(`读取 ${src} …\n`);
    for await (const line of lines(src)) {
      if (!line) continue;
      const f = line.split('|');
      if (f.length < 7) { bad++; continue; }
      const [start, end, country, province, , , iso] = f;
      const region = regionOf(country, province, iso);
      total++;
      if (region) resolved++;
      // ip_start 是主键 ⇒ 源文件里若有重复起点会在 COPY 时炸。
      // ip2region 保证区间不重叠且升序,这里只做**断言**,不做去重 ——
      // 真出现重复说明源文件变了,应该停下来看,而不是静默丢行。
      if (prevStart === start) throw new Error(`重复的起始 IP: ${start}`);
      prevStart = start;
      out.write(`${csvCell(start)},${csvCell(end)},${csvCell(region)}\n`);
    }
    prevStart = null;   // v4 段与 v6 段之间重新计
  }
  await new Promise((r) => out.end(r));

  process.stderr.write(
    `\n共 ${total} 段,其中 ${resolved} 段能给出属地` +
    ` (${((resolved / total) * 100).toFixed(1)}%),跳过畸形行 ${bad}\n` +
    `CSV → ${outPath} (${(fs.statSync(outPath).size / 1e6).toFixed(1)} MB)\n`);

  if (csvOnly) {
    process.stderr.write('\n--csv-only:没有写库。\n');
    return;
  }

  const url = process.env.SUPABASE_URL;
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !key) {
    console.error('\n缺 SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY。' +
      '只要 CSV 的话加 --csv-only。');
    process.exit(2);
  }

  // ⚠️ 全量重建。ip2region 的区间边界会随版本变动,增量合并没有意义,
  //    而且半新半旧的区间表会产生错误的属地。
  process.stderr.write('清空 ip_region_ranges …\n');
  const del = await fetch(`${url}/rest/v1/ip_region_ranges?ip_start=not.is.null`, {
    method: 'DELETE',
    headers: { apikey: key, Authorization: `Bearer ${key}` },
  });
  if (!del.ok) throw new Error(`清空失败 ${del.status}: ${await del.text()}`);

  const BATCH = 5000;
  let buf = [], sent = 0;
  const flush = async () => {
    if (!buf.length) return;
    const res = await fetch(`${url}/rest/v1/ip_region_ranges`, {
      method: 'POST',
      headers: {
        apikey: key,
        Authorization: `Bearer ${key}`,
        'Content-Type': 'application/json',
        Prefer: 'return=minimal',
      },
      body: JSON.stringify(buf),
    });
    if (!res.ok) throw new Error(`批次 @${sent} 失败 ${res.status}: ${await res.text()}`);
    sent += buf.length;
    buf = [];
    process.stderr.write(`\r已写入 ${sent}/${total}`);
  };

  for await (const line of lines(outPath)) {
    const [ip_start, ip_end, region] = line.split(',');
    buf.push({ ip_start, ip_end, region: region || null });
    if (buf.length >= BATCH) await flush();
  }
  await flush();
  process.stderr.write(`\n完成。\n`);
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main().catch((e) => { console.error(e); process.exit(1); });
}
