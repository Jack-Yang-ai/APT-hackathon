import Foundation

// 录音状态机(§六 录音内核 · PRD §4.1.3 异常表)。
//
// 这个文件**不 import AVFoundation**,是刻意的:中断处理对不对全在这张迁移表上,
// 而 AVAudioSession 在单元测试里跑不起来。把「判断」和「副作用」分开,
// 才能拿一串模拟的中断事件去打它(本任务验收要的就是这个)。
//
// 表里有三处是反直觉但必须这样的,都在对应分支上写了理由:
//   · 用户暂停期间来电挂断后**不自动恢复**
//   · 系统中断期间用户按了暂停,之后中断结束也**不自动恢复**
//   · 系统说 shouldResume=false 就**不硬起**

/// 录音状态。
enum RecordingState: Equatable {
    case idle
    case recording

    /// **用户按的**暂停。PRD §4.1.4:一期只有两样隐私手段(暂停、移出记忆),
    /// 暂停是其中之一 —— 所以它必须与「系统中断导致的暂停」分成两个状态。
    /// 合成一个的后果:用户暂停期间来一通电话,挂断时系统发 shouldResume=true,
    /// 录音就自动恢复了 —— 录下用户明确要求不录的内容。
    case pausedByUser

    /// 系统中断(来电 / Siri / 被别的 App 抢占)导致的暂停。中断结束且系统说
    /// 该恢复时,自动恢复。
    case pausedBySystem

    /// 已收尾。终态,任何事件都不再改变它。
    case stopped
}

/// 状态机要求外壳去做的事。外壳照单执行,不自己判断。
enum RecordingEffect: Equatable {
    case startEngine
    case stopEngine

    /// 收尾当前块并落盘。`hardCut` 进块元数据(§3.1.6):
    /// true 表示切点**不是**在静音处取的,下游据此知道这里可能有截断句。
    case finalizeBlock(hardCut: Bool)

    /// 开一个新块(新文件、新起始时间)。
    case openBlock

    /// 往账本追一条标记。重开 App 时靠它区分「你自己暂停的」与「录音被打断了」。
    case mark(SessionMark)
}

/// 账本里的场次标记。**不含块记录** —— 块由 `finalizeBlock` 的执行方追加。
enum SessionMark: String, Equatable, Codable {
    case sessionStarted
    case paused
    case resumed
    /// 系统中断开始。注意它**不闭合「用户以为在录」的意图区间** ——
    /// 中断恰恰是用户以为还在录、实际没在录的那段(见 BlockLedger 的空洞算法)。
    case interrupted
    case sessionEnded
}

enum RecordingEvent: Equatable {
    case userStart
    case userPause
    case userResume
    case userStop

    /// 来电 / Siri / 其他 App 抢占(AVAudioSession.interruptionNotification .began)
    case interruptionBegan
    /// 中断结束。`shouldResume` 来自系统的 .shouldResume 选项。
    case interruptionEnded(shouldResume: Bool)
    /// 路由切换(拔耳机、AirPods 断开)
    case routeChanged
    /// 引擎配置变化(AVAudioEngineConfigurationChange,AirPods 连断会触发)
    case engineConfigurationChanged

    /// 到了分段边界。`hardCut` 由 `BlockCutPolicy` 算出来。
    case blockBoundaryReached(hardCut: Bool)

    /// 静音够久,自己收尾(`AutoStopPolicy`)。
    ///
    /// 🔴 **不复用 `.userStop`。** 落进去的状态与副作用完全一样,
    /// 但「谁结束的这一场」是用户要知道的事:他没按过结束,却看到「已结束」,
    /// 而不说明原因的话他只会以为 App 崩了 —— 与「用户暂停 vs 被电话打断
    /// 必须分开说」是同一条(见 `RecordingViewModel.statusText`)。
    case autoStopped

    /// **麦克风数据不来了,而系统没告诉我们为什么。** `gapMs` 是断流时长。
    ///
    /// 与 `interruptionBegan` 的区别是关键的:中断是系统**通知**我们的,会有
    /// `interruptionEnded` 配对,可以自动恢复;断流是我们**自己发现**的,
    /// 没有任何配对事件会来,**不会自动恢复**。
    ///
    /// 它存在的理由:切到后台之后音频悄悄停了,而界面照样显示「录音中」、
    /// 计时照样在涨 —— 那正是本仓最怕的「看起来完全正常」。
    case audioStalled(gapMs: Int)

    /// 连续几次重起都没换回一帧音频 —— 这才是「麦克风真的死了」。
    /// 与 `audioStalled` 分成两个事件,是因为它俩该做的事**完全相反**:
    /// 一个接着录,一个必须停。合成一个的话,状态机就得知道「这是第几次」,
    /// 而它是纯函数、数不了数。
    case audioDead(gapMs: Int)
}

struct Transition: Equatable {
    let state: RecordingState
    let effects: [RecordingEffect]
}

enum RecordingStateMachine {
    /// Watch的新一场从零计时,暂停恢复继续同一场。纯判据供WatchRecorder与回归测试共用。
    static func startsFresh(from previous: RecordingState, to newState: RecordingState) -> Bool {
        newState == .recording && (previous == .idle || previous == .stopped)
    }


    /// 纯函数:当前状态 + 事件 → 新状态 + 要做的事。
    ///
    /// 一条贯穿全表的不变式:**任何离开 `recording` 的迁移,都先 `stopEngine` 再 `finalizeBlock`**。
    ///
    /// ⚠️ 这个顺序**是反过来改的**。原来写的是「先收尾再停引擎」,理由写成
    /// 「引擎一停,正在写的那个块的尾巴就没了」—— **那句话是错的**:停引擎只是
    /// 不再有新音频送来,已经写进文件的字节一个不少。
    /// 反过来的代价是真的:`finalizeBlock` 把 `file` 置空之后、`stopEngine` 摘掉 tap 之前,
    /// 音频线程还会送一帧过来 → 「没有打开的块却收到音频」。
    /// 用户 2026-08-10 真机点「结束」时看到的就是这条报错。
    /// 先停再收尾,这个窗口从结构上就不存在。
    static func next(state: RecordingState, event: RecordingEvent) -> Transition {
        switch (state, event) {

        // MARK: 空闲 / 上一场已结束 —— 都能开新的一场
        //
        // ⚠️ `.stopped` **不是终态,是「上一场结束了」**。两者曾经被混为一谈:
        // 下面那条 `case (.stopped, _)` 把所有事件都吞掉,包括 `.userStart` ——
        // 于是**一场录完之后「开始记录」永远点不动,必须杀掉 App 重开**。
        // 2026-08-14 真机撞到:断流看门狗把一场判死落进 `.stopped`,人就再也录不了了。
        //
        // 根因是这台状态机管的是**录音机**,不是**场次**:场次结束了,录音机还在那儿。
        // 一个全时录音的产品,「录完一场就不能再录」等于产品没了。
        case (.idle, .userStart), (.stopped, .userStart):
            return Transition(state: .recording,
                              effects: [.mark(.sessionStarted), .startEngine, .openBlock])

        // MARK: 录音中
        case (.recording, .userPause):
            return Transition(state: .pausedByUser,
                              effects: [.stopEngine, .finalizeBlock(hardCut: true), .mark(.paused)])

        case (.recording, .userStop), (.recording, .autoStopped):
            // 自动收尾与手动结束**落一样的状态和副作用** —— 场次就是结束了,
            // 账本上也该是 `sessionEnded`(编一个新标记会让 `relaunchReport`
            // 与空洞算法多一个不认识的取值)。差别只在**告诉用户是谁结束的**,
            // 那件事由 `onAutoStopped` 带上去。
            return Transition(state: .stopped,
                              effects: [.stopEngine, .finalizeBlock(hardCut: true),
                                        .mark(.sessionEnded)])

        // 断流 → **终态**,不是「暂停」。没有任何事件会来恢复它,
        // 摆成暂停就是在暗示「等等会好」,而它不会。
        // 用 `.interrupted` 这个账本标记,让 `relaunchReport` 的口径保持一致。
        // 断流 —— **先自己接上,不结束这一场。**
        //
        // 2026-08-14 改。原来这里直接落 `.stopped`:麦克风哑 3 秒,整场就没了。
        // 而 3 秒是一个**探测**阈值,不是一个**判死**阈值 —— 拿探测阈值当判死用,
        // 等于把「可能只是抖了一下」和「这台设备的麦克风死了」判成同一件事。
        //
        // `interrupted` 这个标记**刻意不闭合意图区间**(见 BlockLedger 的注释),
        // 本来就是为「录音断了但这一场还在」准备的 —— 续跑正好用它:
        // 账本上留下一个如实的洞,场次继续。
        //
        // 停引擎 → 收尾当前块 → 记一个洞 → 重起引擎 → 开新块。
        // 重起失败会被 `dispatch` 接住并落回 `.stopped`(那条路已经在了),
        // 所以这里不需要为「起不来」再写一遍兜底。
        case (.recording, .audioStalled):
            return Transition(state: .recording,
                              effects: [.stopEngine, .finalizeBlock(hardCut: true),
                                        .mark(.interrupted), .startEngine, .openBlock])

        // 接不上了 —— 连续几次重起都没换回一帧音频,这才真的停。
        //
        // 判据是「重起之后**有没有真的收到过音频**」,不是「重起成没成功」:
        // 引擎能起来但一帧不来,恰恰是最需要停的那种情况,而它看起来一切正常。
        // 计数在 `RecordingKernel`(状态机是纯函数,数不了数)。
        case (.recording, .audioDead):
            // 🔴 **要写 `sessionEnded`,不能只写 `interrupted`。**(2026-08-19)
            //
            // `.stopped` 是终态 —— 没有任何事件会来恢复它。而只写 `interrupted`
            // 的话账本里这一场**永远没有闭合**:`isOpen` 恒真 ⇒ `sessions.status`
            // 停在 `recording` ⇒ 首页无条件显示「录音中」(那个态压过一切),
            // 而处理链要等到**下次进程启动**由 `closeAbandoned` 才收得掉。
            //
            // 2026-08-19 之后这一条更要紧:边录边传让「还在录」变成了一个
            // **会被下游读**的判据(上传腿据它决定要不要留着、转写腿据它
            // 决定能不能冻)。一个永远不闭合的场次会让那两条腿一直空转。
            //
            // 两个标记都写:`interrupted` 记录「用户以为在录而其实没在录」那段洞
            // (它刻意不闭合意图区间),`sessionEnded` 闭合这一场。
            return Transition(state: .stopped,
                              effects: [.stopEngine, .finalizeBlock(hardCut: true),
                                        .mark(.interrupted), .mark(.sessionEnded)])

        // 已经不在录了就没什么可断的 —— 原地不动,别把终态推回去。
        case (.idle, .audioStalled), (.stopped, .audioStalled),
             (.pausedByUser, .audioStalled), (.pausedBySystem, .audioStalled),
             (.idle, .audioDead), (.stopped, .audioDead),
             (.pausedByUser, .audioDead), (.pausedBySystem, .audioDead):
            return Transition(state: state, effects: [])

        case (.recording, .interruptionBegan):
            return Transition(state: .pausedBySystem,
                              effects: [.stopEngine, .finalizeBlock(hardCut: true),
                                        .mark(.interrupted)])

        // 路由切换与引擎配置变化都要重起引擎。**必须切块**,不能接着往同一个文件写:
        // 重起期间采不到音,续写会把一段不连续的音频拼成看起来连续的一块,
        // 于是「块内音频时长 ≈ 块的墙钟时长」这条不变式被破坏 —— 而时间轴还原
        // (§3.1.6 时间轴对账契约)整个建立在它上面。切成两块,不连续就显式暴露成
        // 两块之间的空隙,是能被看见的。
        case (.recording, .routeChanged), (.recording, .engineConfigurationChanged):
            return Transition(state: .recording,
                              effects: [.stopEngine, .finalizeBlock(hardCut: true),
                                        .startEngine, .openBlock])

        case (.recording, .blockBoundaryReached(let hardCut)):
            return Transition(state: .recording,
                              effects: [.finalizeBlock(hardCut: hardCut), .openBlock])

        // 没在中断里却收到中断结束 —— 系统偶尔会发,忽略。
        case (.recording, .interruptionEnded), (.recording, .userResume),
             (.recording, .userStart):
            return Transition(state: state, effects: [])

        // MARK: 用户暂停
        case (.pausedByUser, .userResume):
            return Transition(state: .recording,
                              effects: [.mark(.resumed), .startEngine, .openBlock])

        case (.pausedByUser, .userStop):
            return Transition(state: .stopped, effects: [.mark(.sessionEnded)])

        // ⚠️ 用户暂停期间中断结束,**不恢复**。
        // 用户按暂停是明确表达「这段别录」(PRD §4.1.4);系统的 shouldResume
        // 说的是「音频会话可以还给你了」,不是「用户想继续录了」。听系统的就会
        // 录下用户明确要求不录的内容 —— 一期只有两样隐私手段,不能在这里漏掉一样。
        case (.pausedByUser, .interruptionEnded), (.pausedByUser, .interruptionBegan),
             (.pausedByUser, .routeChanged), (.pausedByUser, .engineConfigurationChanged),
             (.pausedByUser, .blockBoundaryReached), (.pausedByUser, .userPause),
             (.pausedByUser, .userStart):
            return Transition(state: state, effects: [])

        // MARK: 系统中断导致的暂停
        case (.pausedBySystem, .interruptionEnded(let shouldResume)):
            // 系统说别恢复(常见于中断方仍占着音频)就别硬起 —— 硬起会失败,
            // 而失败之后状态机以为在录、实际没录,是最坏的一种不一致。
            guard shouldResume else { return Transition(state: state, effects: []) }
            return Transition(state: .recording,
                              effects: [.mark(.resumed), .startEngine, .openBlock])

        // ⚠️ 中断期间用户按了暂停 → 转成「用户暂停」。
        // 之后中断结束时走上面那条 pausedByUser 分支,**不会自动恢复**。
        // 场景很具体:通话中用户按下暂停表示「接下来这段别录」,挂断后不该开录。
        case (.pausedBySystem, .userPause):
            return Transition(state: .pausedByUser, effects: [.mark(.paused)])

        case (.pausedBySystem, .userResume):
            return Transition(state: .recording,
                              effects: [.mark(.resumed), .startEngine, .openBlock])

        case (.pausedBySystem, .userStop):
            return Transition(state: .stopped, effects: [.mark(.sessionEnded)])

        // 引擎已经停了,路由/配置变化此刻无事可做;恢复时本来就要重起引擎。
        case (.pausedBySystem, .routeChanged), (.pausedBySystem, .engineConfigurationChanged),
             (.pausedBySystem, .interruptionBegan), (.pausedBySystem, .blockBoundaryReached),
             (.pausedBySystem, .userStart),
             // 暂停期间引擎是停的,音频线程不会再来问 —— 这两条到不了。
             // 写出来只是因为这台状态机**刻意不写 `default`**:
             // 以后加一个态而漏了它,编译器要在这里拦住人。
             (.pausedBySystem, .autoStopped), (.pausedByUser, .autoStopped):
            return Transition(state: state, effects: [])

        // MARK: 上一场已结束 —— 除了「再开一场」(在上面),其余事件都没什么可做
        //
        // ⚠️ 这条**必须留在 `(.stopped, .userStart)` 后面**。Swift 的 switch 从上往下
        // 第一个匹配的赢,写到前面就会把开新一场那条盖掉 —— 而盖掉的表现是
        // 「按钮没反应」,不报错、不崩,只是永远录不了。
        case (.stopped, _):
            return Transition(state: .stopped, effects: [])

        // MARK: 空闲态收到的其余事件
        case (.idle, _):
            return Transition(state: .idle, effects: [])
        }
    }

    /// 一串事件跑下来的最终状态与累计副作用。测试用它喂中断序列。
    static func run(from state: RecordingState,
                    events: [RecordingEvent]) -> Transition {
        var current = state
        var effects: [RecordingEffect] = []
        for event in events {
            let t = next(state: current, event: event)
            current = t.state
            effects += t.effects
        }
        return Transition(state: current, effects: effects)
    }
}
