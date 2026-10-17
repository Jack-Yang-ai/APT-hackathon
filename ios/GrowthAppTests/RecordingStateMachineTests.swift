import XCTest
@testable import GrowthApp

/// 录音状态机(§六 录音内核 · PRD §4.1.3 异常表)。
///
/// 除了「跑通」,重点打三件在真机上出了错也不会有人当场发现的事:
/// ① 用户按过暂停之后,系统的中断结束会不会把录音悄悄开回来(隐私);
/// ② 离开录音态时有没有先把当前块收尾(已落盘块不丢);
/// ③ 系统说 shouldResume=false 时会不会硬起(硬起失败 → 状态机以为在录、实际没录)。
final class RecordingStateMachineTests: XCTestCase {

    private func run(_ events: [RecordingEvent],
                     from state: RecordingState = .idle) -> Transition {
        RecordingStateMachine.run(from: state, events: events)
    }

    // MARK: - 主流程

    func testStartOpensSessionAndBlock() {
        let t = run([.userStart])
        XCTAssertEqual(t.state, .recording)
        XCTAssertEqual(t.effects, [.mark(.sessionStarted), .startEngine, .openBlock])
    }

    func testBlockBoundaryCutsAndOpensNextWithoutStoppingEngine() {
        let t = run([.userStart, .blockBoundaryReached(hardCut: false)])
        XCTAssertEqual(t.state, .recording)
        XCTAssertEqual(t.effects.suffix(2), [.finalizeBlock(hardCut: false), .openBlock])
        XCTAssertFalse(t.effects.contains(.stopEngine),
                       "切块不该停引擎 —— 停一次就丢一段音频")
    }

    // MARK: - 来电

    func testCallInterruptionPausesAndResumes() {
        let t = run([.userStart, .interruptionBegan, .interruptionEnded(shouldResume: true)])
        XCTAssertEqual(t.state, .recording)
        XCTAssertEqual(t.effects.suffix(3), [.mark(.resumed), .startEngine, .openBlock])
    }

    func testInterruptionEndedWithoutShouldResumeStaysPaused() {
        // 系统说别恢复通常是因为中断方还占着音频。硬起会失败,而失败之后
        // 状态机以为在录、实际没录 —— 比停着更坏。
        let t = run([.userStart, .interruptionBegan, .interruptionEnded(shouldResume: false)])
        XCTAssertEqual(t.state, .pausedBySystem)
        XCTAssertFalse(t.effects.contains(.mark(.resumed)))
    }

    // MARK: - 隐私:用户暂停不能被系统恢复

    func testCallDuringUserPauseDoesNotResumeRecording() {
        // 用户按暂停 = 明确表达「这段别录」(PRD §4.1.4,一期只有两样隐私手段)。
        // 期间来一通电话,挂断时系统发 shouldResume=true —— 听它的就会录下
        // 用户明确要求不录的内容。
        let t = run([.userStart, .userPause,
                     .interruptionBegan, .interruptionEnded(shouldResume: true)])
        XCTAssertEqual(t.state, .pausedByUser)
        XCTAssertEqual(t.effects.filter { $0 == .startEngine }.count, 1,
                       "只该有开场那一次起引擎 —— 多一次就是把用户不想录的内容录了")
        XCTAssertFalse(t.effects.contains(.mark(.resumed)))
    }

    func testUserPauseDuringInterruptionSurvivesInterruptionEnd() {
        // 通话中用户按下暂停 = 「接下来这段别录」。挂断后不该开录。
        let t = run([.userStart, .interruptionBegan, .userPause,
                     .interruptionEnded(shouldResume: true)])
        XCTAssertEqual(t.state, .pausedByUser)
        XCTAssertEqual(t.effects.filter { $0 == .startEngine }.count, 1,
                       "只该有开场那一次起引擎 —— 多一次就是把用户暂停的内容录了")
    }

    func testResumeAfterUserPauseOpensNewBlock() {
        let t = run([.userStart, .userPause, .userResume])
        XCTAssertEqual(t.state, .recording)
        XCTAssertEqual(t.effects.suffix(3), [.mark(.resumed), .startEngine, .openBlock])
    }

    // MARK: - 路由与引擎配置(AirPods 连断)

    func testRouteChangeCutsBlockAndKeepsRecording() {
        // 重起引擎期间采不到音。接着写同一个文件会把不连续的音频拼成看起来连续的一块,
        // 「块内音频时长 ≈ 块的墙钟时长」这条不变式一破,时间轴还原(§3.1.6)就错。
        let t = run([.userStart, .routeChanged])
        XCTAssertEqual(t.state, .recording)
        XCTAssertEqual(t.effects.suffix(4),
                       [.stopEngine, .finalizeBlock(hardCut: true), .startEngine, .openBlock])
    }

    func testEngineConfigurationChangeBehavesLikeRouteChange() {
        XCTAssertEqual(run([.userStart, .engineConfigurationChanged]).effects,
                       run([.userStart, .routeChanged]).effects)
    }

    // MARK: - 不变式:已落盘块不丢

    func testEveryExitFromRecordingStopsEngineBeforeFinalizing() {
        // 逐个事件穷举,不举例 —— 将来加事件时漏掉收尾,这条会自己红。
        let allEvents: [RecordingEvent] = [
            .userStart, .userPause, .userResume, .userStop,
            .interruptionBegan, .interruptionEnded(shouldResume: true),
            .interruptionEnded(shouldResume: false),
            .routeChanged, .engineConfigurationChanged,
            .blockBoundaryReached(hardCut: true), .blockBoundaryReached(hardCut: false),
        ]
        for event in allEvents {
            let effects = RecordingStateMachine.next(state: .recording, event: event).effects
            guard let stopAt = effects.firstIndex(of: .stopEngine) else { continue }
            let finalizeAt = effects.firstIndex {
                if case .finalizeBlock = $0 { return true } else { return false }
            }
            XCTAssertNotNil(finalizeAt, "\(event) 停了引擎却没收尾当前块 —— 这一块不会进账本")
            // ⚠️ 这条断言**是反过来改的**(2026-08-10 真机)。原来要求「先收尾再停引擎」,
            // 理由是「引擎一停尾巴就没了」—— 那句话是错的:停引擎只是不再送新音频,
            // 已写进文件的字节一个不少。反过来的代价是真的:file 置空之后、tap 摘掉之前,
            // 音频线程还会送一帧 → 用户点「结束」时看到「没有打开的块却收到音频」。
            XCTAssertLessThan(stopAt, finalizeAt ?? .max,
                              "\(event) 先收尾再停引擎 —— 中间那一帧会撞上空的 file")
        }
    }

    // MARK: - 终态

    /// ⚠️ **2026-08-14 收窄。** 原来这条把 `.userStart` 也算进「结束之后不该起引擎」的
    /// 事件里,断言「任何事件都不该把引擎再起来」。那句话太宽了:
    ///
    /// 它想守的是**野事件**——迟到的 `.userResume`、系统补发的 `.interruptionEnded`——
    /// 不能把已经收尾的场次悄悄拉回录音中。这个invariant 仍然成立,下面照旧断言。
    ///
    /// 但 `.userStart` 不是野事件,是**用户按下的按钮**。把它一起挡掉的后果是
    /// 真机上撞到的那个:一场录完之后「开始记录」永远点不动,必须杀掉 App 重开 ——
    /// 不报错、不崩,按钮就是没反应。对一个全时录音的产品,这等于产品没了。
    ///
    /// 根因是把两件事混成了一个词:`.stopped` 是**上一场结束了**,
    /// 不是**这台录音机从此不能用了**。开新一场见 `testStoppedCanStartANewSession`。
    func testStoppedIgnoresStrayEventsButNotAnExplicitStart() {
        let t = run([.userStart, .userStop,
                     .userResume, .interruptionEnded(shouldResume: true), .userPause])
        XCTAssertEqual(t.state, .stopped, "野事件把已经结束的场次拉回去了")
        XCTAssertEqual(t.effects.filter { $0 == .startEngine }.count, 1,
                       "结束之后**野事件**不该把引擎再起来(用户明确按开始是另一回事)")
    }

    func testIdleIgnoresEverythingButStart() {
        for event in [RecordingEvent.userPause, .userResume, .userStop,
                      .interruptionBegan, .routeChanged] {
            let t = RecordingStateMachine.next(state: .idle, event: event)
            XCTAssertEqual(t.state, .idle)
            XCTAssertTrue(t.effects.isEmpty, "\(event) 在空闲态不该有副作用")
        }
    }

    // MARK: - 断流:自己发现的,没有配对事件会来

    /// 断流**绝不能摆成 `.pausedBySystem`** —— 那个状态在等 `interruptionEnded`
    /// 来恢复,而断流没有任何配对事件会来:界面会一直显示「被打断」,
    /// 等一个不来的恢复。
    ///
    /// ⚠️ **2026-08-14 改写。** 原来这条把上面那个不变式表达成
    /// 「断流 ⇒ `.stopped`」,并断言等于 `.stopped`。那是**一种**满足方式,
    /// 不是那个不变式本身 —— 而它顺手锁死了一个更糟的行为:
    /// 麦克风哑 3 秒,整场就没了(3 秒是探测阈值,不是判死阈值)。
    ///
    /// 现在的满足方式是**主动重起**:不等任何人,自己接上。
    /// 不变式照旧,而且这里把它写成了真正该守的那句话 ——
    /// **不许停在一个「声称在录、却没有引擎」的状态上。**
    func testAudioStallNeverLeavesTheSessionWaitingForAnEventThatNeverComes() {
        let t = RecordingStateMachine.next(state: .recording, event: .audioStalled(gapMs: 8000))
        XCTAssertNotEqual(t.state, .pausedBySystem, "断流被摆成了暂停 —— 它不会自己恢复")
        XCTAssertTrue(t.effects.contains(.finalizeBlock(hardCut: true)),
                      "没收尾当前块 —— 已经录到的那部分会丢")
        if t.state == .recording {
            XCTAssertTrue(t.effects.contains(.startEngine),
                          "状态说还在录,却没把引擎重起来 —— 那就是「显示录音中而一字节没录」")
        }
    }

    /// 不在录的时候报断流,不该把终态推回去。
    func testAudioStallIsIgnoredWhenNotRecording() {
        for state in [RecordingState.idle, .stopped, .pausedByUser, .pausedBySystem] {
            let t = RecordingStateMachine.next(state: state, event: .audioStalled(gapMs: 8000))
            XCTAssertEqual(t.state, state, "\(state) 收到断流却换了状态 —— 会把已结束的场次推回去")
            XCTAssertTrue(t.effects.isEmpty, "\(state) 收到断流却做了事")
        }
    }
}

// MARK: - 🔴 一场结束之后还能不能再录(2026-08-14 真机撞到)

extension RecordingStateMachineTests {

    /// **`.stopped` 不是终态,是「上一场结束了」。**
    ///
    /// 原来 `case (.stopped, _)` 把所有事件都吞掉,包括 `.userStart` ——
    /// 于是一场录完之后「开始记录」永远点不动,**必须杀掉 App 重开**。
    /// 不报错、不崩,按钮就是没反应。
    ///
    /// 根因是这台状态机管的是**录音机**,不是**场次**:场次结束了,录音机还在那儿。
    func testStoppedCanStartANewSession() {
        let t = RecordingStateMachine.next(state: .stopped, event: .userStart)
        XCTAssertEqual(t.state, .recording, "一场结束之后就再也开不了新的一场了")
        // 必须是**新一场**:要写 sessionStarted、要起引擎、要开块 —— 缺一样都是
        // 「状态变成录音中,而实际什么都没在录」,本仓最怕的那种不一致
        XCTAssertEqual(t.effects, [.mark(.sessionStarted), .startEngine, .openBlock])
    }

    /// 麦克风判死之后也要能重来。
    /// 接不上是**一场**的事故,不是**这台设备**从此不能录音。
    func testStartWorksAgainAfterTheMicIsDeclaredDead() {
        let dead = RecordingStateMachine.next(state: .recording, event: .audioDead(gapMs: 9000))
        XCTAssertEqual(dead.state, .stopped)
        XCTAssertEqual(RecordingStateMachine.next(state: dead.state, event: .userStart).state,
                       .recording, "麦克风判死之后人就再也录不了了")
    }

    /// 开新一场与从空闲开,必须走**同一条**路 —— 两条路迟早会漏掉一样
    /// (比如少写一次 sessionStarted),而那种漏只表现为账本少一行。
    func testStartFromStoppedIsIdenticalToStartFromIdle() {
        XCTAssertEqual(RecordingStateMachine.next(state: .stopped, event: .userStart),
                       RecordingStateMachine.next(state: .idle, event: .userStart))
    }

    /// 除了「再开一场」,`.stopped` 收到的其余事件仍然原地不动 ——
    /// 别把已经收尾的场次推回去。
    func testStoppedStillSwallowsEverythingElse() {
        for e: RecordingEvent in [.userPause, .userResume, .userStop, .interruptionBegan,
                                  .routeChanged, .engineConfigurationChanged,
                                  .blockBoundaryReached(hardCut: true),
                                  .audioStalled(gapMs: 9000)] {
            let t = RecordingStateMachine.next(state: .stopped, event: e)
            XCTAssertEqual(t.state, .stopped, "\(e) 把已经结束的场次推走了")
            XCTAssertTrue(t.effects.isEmpty, "\(e) 在终态上产生了副作用:\(t.effects)")
        }
    }
}

// MARK: - 🔴 断流:先接上,不判死(2026-08-14 用户拍板)

extension RecordingStateMachineTests {

    /// **3 秒是探测阈值,不是判死阈值。**
    /// 原来麦克风哑 3 秒整场就没了 —— 等于把「可能只是抖了一下」和
    /// 「这台设备的麦克风死了」判成同一件事。
    func testStallRecoversInsteadOfEndingTheSession() {
        let t = RecordingStateMachine.next(state: .recording, event: .audioStalled(gapMs: 3200))
        XCTAssertEqual(t.state, .recording, "断一下就把整场结束了")
        // 停引擎 → 收尾当前块 → 记一个洞 → 重起 → 开新块,顺序不能乱:
        // 先开块后停引擎的话,那一帧会撞上已经置空的 file
        XCTAssertEqual(t.effects, [.stopEngine, .finalizeBlock(hardCut: true),
                                   .mark(.interrupted), .startEngine, .openBlock])
    }

    /// `interrupted` **刻意不闭合意图区间**(BlockLedger 的设计),
    /// 所以续跑之后这一场在账本上仍然是开着的 —— 洞如实记下,场次继续。
    /// 这条钉住的是「续跑没有偷偷把场次结束掉」。
    func testRecoveryMarksTheGapButDoesNotEndTheSession() {
        let t = RecordingStateMachine.next(state: .recording, event: .audioStalled(gapMs: 3200))
        XCTAssertTrue(t.effects.contains(.mark(.interrupted)), "洞没记下来")
        XCTAssertFalse(t.effects.contains(.mark(.sessionEnded)),
                       "续跑却把场次标成结束了 —— 账本会认为用户主动收的工")
    }

    /// 接不上了才真的停。**与 `audioStalled` 是两个事件**,因为它俩该做的事相反。
    func testAudioDeadEndsTheSession() {
        let t = RecordingStateMachine.next(state: .recording, event: .audioDead(gapMs: 9000))
        XCTAssertEqual(t.state, .stopped)
        XCTAssertFalse(t.effects.contains(.startEngine), "都判死了还在重起引擎")
        XCTAssertTrue(t.effects.contains(.finalizeBlock(hardCut: true)),
                      "停了却没收尾当前块 —— 这一块不会进账本")
    }

    /// 🔴 **判死也要闭合这一场。**(2026-08-19)
    ///
    /// 只写 `interrupted` 的话账本里这一场永远不闭合 ⇒ `sessions.status` 停在
    /// `recording` ⇒ 首页无条件显示「录音中」,而处理链要等下次进程启动才收得掉。
    /// 边录边传之后更要紧:「还在录」现在是**会被下游读**的判据(上传腿据它
    /// 决定要不要留着任务、转写腿据它决定能不能冻结),不闭合就是让那两条腿一直空转。
    func testAudioDeadAlsoClosesTheSessionInTheLedger() {
        let t = RecordingStateMachine.next(state: .recording, event: .audioDead(gapMs: 9000))
        XCTAssertTrue(t.effects.contains(.mark(.interrupted)),
                      "洞没记 —— 「用户以为在录而其实没在录」那段就没了")
        XCTAssertTrue(t.effects.contains(.mark(.sessionEnded)),
                      "这一场没闭合 —— 它会永远挂在「录音中」,上传与转写两条腿跟着空转")
    }

    /// 判死之后还能再开一场(和 `.stopped` 那条修复配套)。
    func testYouCanStartAgainAfterAudioDead() {
        let dead = RecordingStateMachine.next(state: .recording, event: .audioDead(gapMs: 9000))
        XCTAssertEqual(RecordingStateMachine.next(state: dead.state, event: .userStart).state,
                       .recording)
    }

    /// 不在录的时候收到这两个事件,原地不动 —— 别把已收尾的场次拉回去,
    /// 更别在暂停时偷偷把引擎起起来。
    func testStallAndDeathAreIgnoredWhenNotRecording() {
        for s: RecordingState in [.idle, .stopped, .pausedByUser, .pausedBySystem] {
            for e: RecordingEvent in [.audioStalled(gapMs: 5000), .audioDead(gapMs: 9000)] {
                let t = RecordingStateMachine.next(state: s, event: e)
                XCTAssertEqual(t.state, s, "\(s) 收到 \(e) 之后状态变了")
                XCTAssertTrue(t.effects.isEmpty, "\(s) 收到 \(e) 之后产生了副作用:\(t.effects)")
            }
        }
    }
}
