import Foundation

/// 「关于你的观察」的**类型闭集**(PRD §4.4.7「能产出哪些观察」:清单之外不做)。
///
/// ## 🔴 为什么必须有这个闭集 —— 不是为了整齐,是两条呈现规则**没它就写不出来**
///
/// §4.4.7 的呈现规则里有两条挂在「这条观察是什么性质」上:
///
/// | 规则 | 出处 |
/// |---|---|
/// | 涉及**盲区、缺席、反复困境**的观察**不在 20:00 后呈现** | R-D / §4.4.7 时段 |
/// | 顺序:**先亮点与规律,后盲区** | §4.4.7 顺序 |
///
/// 没有类型,这两条就只能靠人肉判断每一条观察的性质 —— 而那等于没有规则。
///
/// ⚠️ 用**类型**推,不落一个 `is_sensitive` 布尔:布尔是同一件事的第二个出处,
/// 而对不上时的表现是**一条盲区观察在睡前弹出来** —— R-D 那条红线的全部意义
/// 就是不让这件事发生,而它不会有任何报错。
enum ObservationKind: String, CaseIterable {
    case behaviorPattern = "行为规律"
    case overlookedStrength = "被忽略的亮点"
    case judgmentTrajectory = "判断的轨迹"
    case participationGap = "参与方式的差异"
    case recurringPredicament = "重复的处境"

    /// 呈现的次序档。数越小越靠前(§4.4.7「先亮点与规律,后盲区」)。
    enum Band: Int { case strength = 0, pattern = 1, blindSpot = 2 }

    var band: Band {
        switch self {
        case .overlookedStrength: return .strength
        case .behaviorPattern, .judgmentTrajectory: return .pattern
        case .participationGap, .recurringPredicament: return .blindSpot
        }
    }

    /// 是不是「盲区类」—— **20:00 之后不呈现**(R-D)。
    ///
    /// 🔴 这个映射是**判断**,不是抄写,所以把依据写出来:
    /// PRD 的原话是「涉及**盲区、缺席、反复困境**的观察」。
    /// · 「参与方式的差异」= 你在哪些场合没参与 ⇒ **缺席**;
    /// · 「重复的处境」= 同一种困境反复出现 ⇒ **反复困境**。
    /// 其余三型(行为规律 / 被忽略的亮点 / 判断的轨迹)不涉及这三个词里的任何一个。
    ///
    /// ⚠️ 哪天 PRD 改了那三个词,**这里要跟着改** —— 由
    /// `eval/checks/test_observation_kinds.py` 双向对撞把两侧钉在一起。
    var isBlindSpot: Bool { band == .blindSpot }

    /// 20:00。之后不呈现盲区类。
    static let blindSpotCurfewHour = 20
}
