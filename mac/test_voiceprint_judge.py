#!/usr/bin/env python3
"""判决核的夹具测试 + 跨语言常数对撞(M2-认8 ③)。

    ~/Desktop/录音文件/_pipeline/.venv/bin/python mac/test_voiceprint_judge.py
    (纯 numpy,系统 python3 装了 numpy 也能跑)

打的都是「错了不报错」的形态:
· τ / minSegments / minVoteRatio 与 SpeakerMatch.swift **从源码抠出来比**(铁律 4:
  Swift 那份代码还在,休眠;两处常数漂了不会有任何运行时报错);
· 冒充集接住陌生人(top1 落冒充 ⇒ 不给名字);
· §2.5 剔除:同一人同时在登记集与冒充集时,不剔他就被自己压死 —— 用夹具复现;
· 聚类宁裂不并;判不出的簇是**匿名候选**而不是丢弃。
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

import numpy as np

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO))
from mac.voiceprint_judge import (REVIEW_K,  # noqa: F401
    CLUSTER_LINK, MIN_SEGMENTS,       # noqa: E402
                                  MIN_VOTE_RATIO, TAU, Comparison,
                                  SegmentVote, cluster_lines, group_by_upstream,
                                  judge_two_stage,
                                  judge_cluster, score_segment)

SWIFT = REPO / "ios/GrowthApp/Voiceprint/SpeakerMatch.swift"
FAILS: list[str] = []


def check(name: str, cond: bool, why: str = "") -> None:
    print(("✅" if cond else "🔴"), name)
    if not cond:
        FAILS.append(f"{name}{':' + why if why else ''}")


def unit(seed: int, dim: int = 8) -> np.ndarray:
    rng = np.random.default_rng(seed)
    v = rng.normal(size=dim)
    return v / np.linalg.norm(v)


def near(v: np.ndarray, seed: int, eps: float = 0.15) -> np.ndarray:
    w = v + eps * unit(seed, v.shape[0])
    return w / np.linalg.norm(w)


def main() -> int:

    src = SWIFT.read_text(encoding="utf-8")
    swift_tau = float(re.search(r"static let tau: Float = ([0-9.]+)", src).group(1))
    swift_min = int(re.search(r"static let minSegments = (\d+)", src).group(1))
    m = re.search(r"static let minVoteRatio: Double = ([0-9.]+) / ([0-9.]+)", src)
    swift_ratio = float(m.group(1)) / float(m.group(2))
    check("τ 与 SpeakerMatch.swift 一致", swift_tau == TAU,
          f"swift {swift_tau} / python {TAU} —— 两份判决的旋钮漂了")
    check("minSegments 一致", swift_min == MIN_SEGMENTS)
    check("minVoteRatio 一致", abs(swift_ratio - MIN_VOTE_RATIO) < 1e-9)


    A, B = unit(1), unit(2)
    stranger = unit(3)


    cohort = np.stack([near(stranger, 30, 0.1), unit(4), unit(5)]
                      + [unit(300 + i) for i in range(10)])
    cmp = Comparison(registry={1: A[None, :], 2: B[None, :]},
                     anonymous={}, cohort=cohort)


    segs_a = [near(A, s, 0.08) for s in (10, 11, 12)]
    votes = [score_segment(v, cmp) for v in segs_a]
    v = judge_cluster(votes, np.stack(segs_a))
    check("登记者被认出", v.kind == "person" and v.person_id == 1, f"得到 {v}")


    segs_s = [near(stranger, s, 0.08) for s in (20, 21, 22)]
    votes = [score_segment(v_, cmp) for v_ in segs_s]
    v = judge_cluster(votes, np.stack(segs_s))
    check("陌生人不被安名字(冒充集接住)", v.kind != "person", f"得到 {v}")
    check("陌生人成为匿名候选而不是丢弃", v.kind == "anonymous_candidate")
    check("匿名候选带质心(手机落匿名向量表要用)", len(v.centroid) == 8)




    C = unit(6)
    cmp_bad = Comparison(registry={3: C[None, :]}, anonymous={},
                         cohort=np.stack([near(C, 40, 0.02)] + [unit(320 + i) for i in range(12)]))   # 没剔,几乎同向
    segs_c = [near(C, s, 0.05) for s in (50, 51, 52)]
    v_bad = judge_cluster([score_segment(x, cmp_bad) for x in segs_c], np.stack(segs_c))
    check("照妖镜:不剔冒充质心 ⇒ 刚登记的人被自己压死(审计 G 的形态)",
          v_bad.kind != "person",
          "夹具没复现出来 —— 那 §2.5 的剔除就没有证据支撑")
    cmp_ok = Comparison(registry={3: C[None, :]}, anonymous={},
                        cohort=np.stack([unit(7)] + [unit(340 + i) for i in range(12)]))              # 剔了
    v_ok = judge_cluster([score_segment(x, cmp_ok) for x in segs_c], np.stack(segs_c))
    check("剔除后同一人立刻认得出", v_ok.kind == "person" and v_ok.person_id == 3)


    anon_v = unit(8)
    cmp_anon = Comparison(registry={}, anonymous={-101: anon_v[None, :]},
                          cohort=np.stack([unit(9), unit(10)] + [unit(360 + i) for i in range(11)]))
    segs_n = [near(anon_v, s, 0.06) for s in (60, 61)]
    v = judge_cluster([score_segment(x, cmp_anon) for x in segs_n], np.stack(segs_n))
    check("既有匿名人格被再次认出", v.kind == "person" and v.person_id == -101, f"{v}")






    e1 = np.eye(8)[0]
    e2 = np.eye(8)[1]
    X = np.stack([near(e1, 70, 0.05), near(e1, 71, 0.05), near(e2, 72, 0.05)])
    labels = cluster_lines(X)
    check("同人行聚在一起、异人行分开",
          labels[0] == labels[1] and labels[0] != labels[2], f"labels={labels}")






    nobody = near(stranger, 25, 0.08)
    v = judge_cluster([score_segment(nobody, cmp)], nobody[None, :])
    check("单段簇里那一段真的谁都不像 ⇒ 不给名字", v.kind == "anonymous_candidate",
          f"得到 {v}")








    single = [near(A, 13, 0.08)]
    v = judge_cluster([score_segment(single[0], cmp)], np.stack(single))
    check("🔴 一段的簇,那一段过了 τ 就说了算",
          v.kind == "person" and v.person_id == 1,
          f"得到 {v} —— 用户特意录的干净声纹会被挡在比对之外")





    many = [near(A, 14, 0.08)] + [near(stranger, 40 + i, 0.08) for i in range(39)]
    v = judge_cluster([score_segment(x, cmp) for x in many], np.stack(many))
    check("🔴 多段的簇,不许一段说了算",
          v.kind != "person",
          f"得到 {v} —— 40 段里 1 段过 τ 就给整簇安名字")










    A2 = unit(1)
    good = [near(A2, s, 0.05) for s in (50, 51, 52)]
    odd  = [near(unit(9), 53, 0.05)]                    # 混进来的那一段
    embs = np.stack(good + odd)
    cmp2 = Comparison(registry={1: A2[None, :], 2: unit(2)[None, :]},
                      anonymous={}, cohort=np.stack([unit(380 + i) for i in range(14)]))
    v = judge_two_stage(embs, cmp2)
    check("二次确认候选带出来了(不是只写在 why 里)",
          bool(v.review), f"得到 {v.review} —— 不带出去手机就要把整簇重新 embed 一遍")
    check("🔴 掉队的那一段排在最前",
          bool(v.review) and v.review[0][0] == 3,
          f"{v.review} —— 第一个该是混进来的那段(簇内序号 3)")
    check("候选不超过 REVIEW_K 条",
          len(v.review) <= REVIEW_K, f"{len(v.review)} 条")




    daemon_src = (REPO / "mac/voiceprint_daemon.py").read_text(encoding="utf-8")
    check("daemon 把 review 拼进 JSON 了",
          '"review"' in daemon_src and "v.review" in daemon_src,
          "判决核算好了、测试也绿了,而它到不了手机 —— 「写好了不等于在跑」")




















    def vote(pid, margin):
        return SegmentVote(person_id=pid, score=0.5 + margin, runner_up=0.5)


    votes_m = [vote(5, 0.30), vote(6, 0.001), vote(5, 0.001)]
    E3 = np.zeros((1, 4), dtype=float); E3[0, 0] = 1.0
    v_mid = judge_cluster(votes_m, np.repeat(E3, 3, axis=0))
    check("中置信:票不够时仍是匿名候选", v_mid.kind == "anonymous_candidate", f"{v_mid}")
    check("中置信:候选人**带出来了**(不是只写在 why 里)",
          v_mid.candidate_person_id == 5,
          f"candidate={v_mid.candidate_person_id} why={v_mid.why!r} —— "
          f"没有它,PRD §4.4.10 的三档就只剩两档,而缺的恰好是中间那档")




    check("中置信:票数也带出来(口径 = 有效票)",
          v_mid.votes == 1 and v_mid.of == 1, f"{v_mid.votes}/{v_mid.of}")
    check("中置信:全簇段数没丢,写在 why 里(不然「有多少段」这个信息就没了)",
          "3 段" in v_mid.why, v_mid.why)
    check("低置信:一段都没过 τ ⇒ **不猜**,没有候选",
          judge_cluster(votes_m[1:], np.repeat(E3, 2, axis=0)).candidate_person_id is None,
          "连 τ 都没过还给了候选 —— 那是在猜,PRD 明写「未命中/低置信不猜」")

    check("CLUSTER_LINK 是实测那一档", CLUSTER_LINK == 0.60,
          "改档要先重跑 link_probe 的分布,别裸调")






    def seg(pid, margin):   # 造一段:pid=None 表示 top1 落在冒充集
        return SegmentVote(person_id=pid, score=0.5 + margin, runner_up=0.5)

    E1 = np.zeros((1, 4), dtype=float); E1[0, 0] = 1.0


    votes_abstain = [seg(7, 0.30)] * 8 + [seg(7, 0.05)] * 12
    v = judge_cluster(votes_abstain, np.repeat(E1, 20, axis=0))
    check("弃权票不当反对票:8/8 有效票 ⇒ 认出来",
          v.kind == "person" and v.person_id == 7 and v.votes == 8 and v.of == 8,
          f"{v.kind}/{v.person_id} {v.votes}/{v.of} —— 旧口径是 8/20=40% 判不出;"
          f"而「没拉开差距」是弃权不是投给别人,拿它当反对票等于让噪声段替真人否决自己")


    votes_split = [seg(7, 0.30)] * 3 + [seg(9, 0.30)] * 2 + [seg(7, 0.05)] * 15
    v2 = judge_cluster(votes_split, np.repeat(E1, 20, axis=0))
    check("真分裂还是判不出:3/5 有效票 < 2/3 ⇒ 只给候选",
          v2.kind == "anonymous_candidate" and v2.candidate_person_id == 7
          and v2.votes == 3 and v2.of == 5,
          f"{v2.kind}/{v2.candidate_person_id} {v2.votes}/{v2.of} —— "
          f"换分母不是放水,两个人抢的时候照样不给身份")






    def vec3(*xs):                # ⚠️ 别叫 unit —— 本文件上面已有一个同名的
        v = np.array(xs, dtype=float); return v / np.linalg.norm(v)

    me = vec3(1, 0, 0.0)          # 登记的人
    q  = vec3(0.92, 0.39, 0.0)    # 查询段:像「我」(cos≈0.92)
    imp = vec3(0.97, 0.24, 0.0)   # 匿名人格:更像查询(cos≈0.98)—— 就是那个域优势

    Q = np.repeat(q.reshape(1, -1), 4, axis=0)





    coh = np.stack([vec3(0.35 * np.cos(2 * np.pi * i / 12),
                         0.35 * np.sin(2 * np.pi * i / 12), 0.94)
                    for i in range(12)])
    with_anon = Comparison(registry={7: me.reshape(1, -1)},
                           anonymous={99: imp.reshape(1, -1)}, cohort=coh)

    one_shot = judge_cluster([score_segment(x, with_anon) for x in Q], Q)
    check("(现状复现)一次判完时,匿名人格把登记的人挤掉",
          one_shot.person_id != 7,
          "夹具没造出「匿名更像」那个形态,下面那条就白测了")

    two = judge_two_stage(Q, with_anon)
    check("🔴 两段式:先只跟登记的人比 ⇒ 认出「我」",
          two.kind == "person" and two.person_id == 7,
          f"{two.kind}/{two.person_id} —— 匿名人格与查询同域,让它和登记的人抢 top1,"
          f"结果是判不出 → 立更多匿名人格 → 更判不出(正反馈毒化环)")








    far = vec3(-0.6, 0.8, 0.0)
    only_anon = Comparison(registry={7: far.reshape(1, -1)},
                           anonymous={99: imp.reshape(1, -1)}, cohort=coh)
    v3 = judge_two_stage(Q, only_anon)
    check("第二段保住跨场次连续性:登记的人都不像 ⇒ 认回已有的匿名人格",
          v3.kind == "person" and v3.person_id == 99,
          f"{v3.kind}/{v3.person_id} —— 把第二段砍掉的话,同一个「声音A」"
          f"每一场都会变成一个新人格")

    check("`of` 跟着分子一起换口径",
          v2.of == 5,
          "界面上写的是「N 段里有 M 段像他」,分子换了分母不换,那句话就是假的")






    g = group_by_upstream(["speaker_0", "speaker_1", "speaker_0", "speaker_1"])
    check("上游有分人就按上游分组:2 个标签 → 2 个簇",
          g is not None and len(set(g[0])) == 2,
          f"{g}(重聚会把它切碎,而碎片会立成匿名人格写进底库)")
    check("簇号回得到上游那个标签(幂等键靠它,不许用序号)",
          g is not None and set(g[1].values()) == {"speaker_0", "speaker_1"},
          f"{g[1] if g else None} —— 用序号的话少一段就整体错位,重判会再立一批人格")
    check("同一个标签的段落进同一个簇",
          g is not None and g[0][0] == g[0][2] and g[0][1] == g[0][3], str(g))

    check("🔴 一个标签都没有(SSE 形态)⇒ 判不了,不许回落自己聚类",
          group_by_upstream([None, None, None]) is None,
          "回落 cluster_lines 会在**没有真值可对照**的场次上造同样的碎片,"
          "而那时没有任何东西会红 —— 见 M2-认9 ②")

    g2 = group_by_upstream(["speaker_0", None, "speaker_0", None])
    check("混着无标签的行:它们各自成簇,不并进已知簇",
          g2 is not None and len(set(g2[0])) == 3,
          f"{g2} —— 「不知道是谁」和「是某一簇」是两件事,并进去是替模型做判断")


    import mac.voiceprint_judge as vj
    base = unit(901, 16)
    me = np.stack([near(base, 910 + i, 0.25) for i in range(6)])
    cohort = np.stack([unit(950 + i, 16) for i in range(14)])

    def med_z(embs):
        cmp = Comparison(registry={vj.SELF_ID: me}, anonymous={}, cohort=cohort)
        mu, sd = cmp.tnorm_stats()[id(me)]
        return float(np.median((((embs @ me.T) - mu) / sd).max(axis=1)))

    mine = np.stack([near(base, 930 + i, 0.3) for i in range(5)])
    m = med_z(mine)
    saved = (vj.SELF_ACCEPT_Z, vj.SELF_ASK_Z)
    try:
        vj.SELF_ACCEPT_Z, vj.SELF_ASK_Z = m - 0.1, m - 0.5
        v = vj.judge_self(mine, me, cohort)
        check("只认我:中位过认我线 ⇒ 判成我(person_id = -1)",
              v.kind == "person" and v.person_id == -1, f"{v.kind} {v.person_id} {v.why}")
        check("判成我也附二次确认候选(最不像我的几句)",
              0 < len(v.review) <= REVIEW_K, str(v.review))

        vj.SELF_ACCEPT_Z, vj.SELF_ASK_Z = m + 0.1, m - 0.1
        v = vj.judge_self(mine, me, cohort)
        check("只认我:灰区 ⇒ 不判,但候选记成我、附最像我的几句(问「是你吗?」)",
              v.kind == "rejected" and v.person_id is None and v.candidate_person_id == -1
              and len(v.review) > 0, f"{v.kind} {v.candidate_person_id} {v.review}")
        zs = [sc for _, sc in v.review]
        check("灰区挑的是最像我的(分数降序)", zs == sorted(zs, reverse=True), str(zs))

        vj.SELF_ACCEPT_Z, vj.SELF_ASK_Z = m + 0.5, m + 0.1
        v = vj.judge_self(mine, me, cohort)
        check("只认我:低于灰区 ⇒ 不是我,不立人格、不带候选",
              v.kind == "rejected" and v.candidate_person_id is None and not v.review,
              f"{v.kind} {v.candidate_person_id} {v.review}")


        mixed = np.vstack([mine, unit(990, 16)[None], unit(991, 16)[None]])
        vj.SELF_ACCEPT_Z, vj.SELF_ASK_Z = m - 0.1, m - 0.5
        check("只认我:簇里混进两段别人,取中位结论不翻",
              vj.judge_self(mixed, me, cohort).kind == "person")

        stranger = np.stack([unit(970 + i, 16) for i in range(4)])
        vj.SELF_ACCEPT_Z, vj.SELF_ASK_Z = saved
        check("只认我:陌生人的簇在生产阈值下是 rejected",
              vj.judge_self(stranger, me, cohort).kind == "rejected")
    finally:
        vj.SELF_ACCEPT_Z, vj.SELF_ASK_Z = saved


    saved = (vj.SELF_ACCEPT_Z, vj.SELF_ASK_Z)
    try:
        vj.SELF_ACCEPT_Z, vj.SELF_ASK_Z = -100, -101
        for n in (1, 2):
            v = vj.judge_self(mine[:n], me, cohort)
            check(f"只认我:{n} 段即使高分也只能问,不自动认",
                  v.kind == "rejected" and v.candidate_person_id == vj.SELF_ID)
    finally:
        vj.SELF_ACCEPT_Z, vj.SELF_ASK_Z = saved
    for label, query, templates, impostors in [
        ("缺本人模板", mine, me[:0], cohort),
        ("空查询", mine[:0], me, cohort),
        ("NaN查询", np.full_like(mine, np.nan), me, cohort),
        ("NaN模板", mine, np.full_like(me, np.nan), cohort),
        ("零向量", np.zeros_like(mine), me, cohort),
        ("维度漂移", mine[:, :-1], me, cohort),
    ]:
        try:
            vj.judge_self(query, templates, impostors)
            check(f"只认我:{label} 必须失败可见,不能假装拒识", False)
        except (RuntimeError, ValueError):
            check(f"只认我:{label} 必须失败可见,不能假装拒识", True)
    try:
        vj.judge_self(mine, me, cohort[:5])
        check("冒充集不足 ⇒ 必须抛(半套归一化比不归一化更坏)", False)
    except RuntimeError:
        check("冒充集不足 ⇒ 必须抛(半套归一化比不归一化更坏)", True)

    if FAILS:
        print(f"\n🔴 {len(FAILS)} 条没过", file=sys.stderr)
        return 1
    print("\n✅ 判决核全部过")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
