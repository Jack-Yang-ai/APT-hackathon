import assert from "node:assert";
import { purgeSession, remaining } from "./src/purge.js";

let pass = 0, fail = 0;
const tests = [];
const test = (name, fn) => tests.push([name, fn]);

/** 最小的 R2 假桶。`list` 按前缀,支持 truncated —— 分页是这一层最容易漏的地方。 */
function bucket(init = {}, pageSize = 1000) {
  const m = new Map(Object.entries(init));
  return {
    _m: m,
    async list({ prefix, limit = 1000 }) {
      const all = [...m.keys()].filter((k) => k.startsWith(prefix)).sort();
      const page = all.slice(0, Math.min(limit, pageSize));
      return { objects: page.map((key) => ({ key })), truncated: all.length > page.length };
    },
    async delete(key) { m.delete(key); },
  };
}

const full = () => bucket({
  "inbox/audio/7/block-0000.m4a": "a",
  "inbox/audio/7/block-0001.m4a": "a",
  "asr/claim/inbox/audio/7/block-0000.m4a.json": "c",
  "voiceprint/jobs/7.json": "v",
  "voiceprint/out/7.json": "v",
  "extract/jobs/31-0-abc.json": "j",
  "extract/out/31-0-abc.json": "o",
  "extract/out/31-1-def.json": "o",
  "asr/pending/900.json": "p",
  "asr/result/900.json": "r",
  "asr/trace/900-block-0000.json": "t",
  // 别人家的东西,一个都不许动
  "inbox/audio/8/block-0000.m4a": "keep",
  "extract/out/32-0-zzz.json": "keep",
  "asr/pending/901.json": "keep",
});

const args = { session: 7, transcripts: [31], tasks: [900] };

test("🔴 一场的云端副本全删干净 —— 界面承诺的是「都会删掉」", async () => {
  const b = full();
  const counts = await purgeSession(b, args);
  assert.strictEqual(await remaining(b, args).then((l) => l.length), 0,
    "删完还有剩 —— 用户以为内容没了,而云端还能还原");
  assert.strictEqual(counts.audio, 2);
  assert.strictEqual(counts.extract, 3);
  assert.strictEqual(counts.asr, 3);
  assert.ok(counts.total >= 11);
});

test("🔴 别的场次一个都不许被带走", async () => {
  const b = full();
  await purgeSession(b, args);
  for (const k of ["inbox/audio/8/block-0000.m4a", "extract/out/32-0-zzz.json",
                   "asr/pending/901.json"]) {
    assert.ok(b._m.has(k), `删过头了,连 ${k} 都没了`);
  }
});

test("重复删是成功,不是错 —— 手机会重试,第二次报错会让一次成功的删除看起来像失败",
  async () => {
    const b = full();
    await purgeSession(b, args);
    const again = await purgeSession(b, args);
    assert.strictEqual(again.total, 0);
    assert.deepStrictEqual(await remaining(b, args), []);
  });

test("🔴 分页:一页列不完也要删干净", async () => {
  const many = {};
  for (let i = 0; i < 7; i++) many[`inbox/audio/7/block-000${i}.m4a`] = "a";
  const b = bucket(many, 2);          // 每页只给 2 条
  await purgeSession(b, { session: 7 });
  assert.strictEqual(b._m.size, 0, "分页没走完 ⇒ 悄悄漏删,而 delete 一次都没报错");
});

test("没有任何副本的场次:删了等于 0,回读也是空 —— 不许因此报错", async () => {
  const b = bucket();
  assert.strictEqual((await purgeSession(b, args)).total, 0);
  assert.deepStrictEqual(await remaining(b, args), []);
});

for (const [name, fn] of tests) {
  try { await fn(); console.log("PASS", name); pass++; }
  catch (e) { console.log("FAIL", name, "\n   ", e.message); fail++; }
}
console.log(fail ? `\n${fail} failed / ${pass + fail}` : `\nall passed (${pass})`);
process.exit(fail ? 1 : 0);
