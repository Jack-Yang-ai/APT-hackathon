import Foundation
import GRDB
@testable import GrowthApp

/// 测试用的一小拨「人」。
///
/// ## 为什么突然需要它
///
/// migration **v14** 之后 `line_speakers.person_id` 与 `voiceprints.person_id`
/// 有了**真外键** —— 一个 person id 必须对应 `persons` 里一行真实存在的人。
/// 而在那之前,测试里那些 `7` / `8` / `9` 是凭空写的号,库里没有对应的人。
///
/// 🔴 **这不是「为了让测试变绿而放宽」,方向恰好相反**:测试从此必须先声明
/// 「这一拨人存在」,而**生产代码也得这么做**(导底库前要先建人,声纹派号只能派
/// 已存在的人)。改测试是让它们如实反映新契约,不是绕开新契约。
///
/// 单独一个文件而不是各写各的,是因为「这一拨人是谁」应该只有一个出处 ——
/// 各 suite 各插各的,迟早出现「7 号在这个文件叫张三、在那个文件是李四」。
enum TestPeople {

    /// 测试里用到的号。**新增号码请加在这里**,不要在某个 suite 里就地插一行 ——
    /// 就地插的那行只有那个文件知道,而外键是全库的。
    static let cast: [Int64] = [1, 2, 7, 8, 9, 42]

    /// 把这一拨人放进库。名字留 NULL:测试关心的是**身份**(谁是谁),
    /// 不是称呼 —— 编一个名字进去会让 `SpeakerNaming` 的编号断言跟着变,
    /// 而那不是这些 suite 想测的东西。
    static func seed(_ ids: [Int64] = cast, at now: String = "2026-08-17T00:00:00+08:00",
                     in writer: some DatabaseWriter) throws {
        try writer.write { db in
            for id in ids {
                try db.execute(sql: """
                    INSERT OR IGNORE INTO persons (id, name, source, created_at, updated_at)
                    VALUES (?, NULL, '用户创建', ?, ?)
                    """, arguments: [id, now, now])
            }
        }
    }
}
