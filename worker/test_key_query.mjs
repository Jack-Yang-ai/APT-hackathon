import assert from "node:assert";
import { keyFromQuery } from "./src/index.js";

let pass = 0, fail = 0;
const test = (name, fn) => {
  try { fn(); console.log("✅", name); pass++; }
  catch (e) { console.log("🔴", name, "\n   ", e.message); fail++; }
};

const q = (s) => keyFromQuery(new URL(`https://x/upload?${s}`));

// 🔴 这一组守的是 2026-08-25 实测的那个 400。
//
// `url.searchParams.get('key')` 按表单编码解,而那套编码里 **`+` 表示空格**。
// 可 key 是不透明标识,不是表单字段 —— 快照的 key 里那个 `+` 是 ISO 时间的
// 时区偏移(`+08:00`)。于是手机发 `…T16-37-00+08-00.json`,
// Worker 收到 `…T16-37-00 08-00.json`,空格不在 KEY_RE 里 ⇒ 400。
//
// ⚠️ 后果不是「少一个备份」:`M2-认8` 之后快照是 **Mac 判决的输入** ——
// 推不上去 = Mac 一直拿旧底库判人,而两端都不报错。
// 实测:`RemoteSnapshotStore` 那条路一次都没成功过。

test("裸加号原样保留(旧版 App 发的就是这个)", () => {
  assert.strictEqual(q("key=snapshots/voiceprints/2026-08-25T16-37-00+08-00.json"),
                     "snapshots/voiceprints/2026-08-25T16-37-00+08-00.json");
});

test("照妖镜:同一个串走 searchParams 会被改成空格", () => {
  const bad = new URL("https://x/upload?key=a+b").searchParams.get("key");
  assert.strictEqual(bad, "a b", "URLSearchParams 不再把 + 解成空格了?那这组测试的前提没了");
});

test("%2B 照样解成加号(新版 App 发的是这个)", () => {
  assert.strictEqual(q("key=a%2Bb"), "a+b");
});

test("普通 key 不受影响", () => {
  assert.strictEqual(q("key=inbox/audio/2895/block-0000.wav"),
                     "inbox/audio/2895/block-0000.wav");
});

test("百分号编码的斜杠与中文照常解", () => {
  assert.strictEqual(q("key=a%2Fb"), "a/b");
});

test("没有 key 返回 null,不是空串 —— 空串会被 isLegalKey 判非法,语义混在一起", () => {
  assert.strictEqual(q("other=1"), null);
});

test("只取 key= 这一个参数,不被别的参数带偏", () => {
  assert.strictEqual(q("t=1&key=a%2Bb"), "a+b");
});

test("坏的百分号编码返回 null,不抛 —— 抛出去会变成 500,而它其实是 400", () => {
  assert.strictEqual(q("key=%E0%A4%A"), null);
});

console.log(`\n${pass} 过 · ${fail} 没过`);
process.exit(fail ? 1 : 0);
