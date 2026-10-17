import SwiftUI

// 从旧仓 ios/GrowthAgent/Theme.swift 原样搬来。DesignSystem.swift 的整张色板
// 都写成 Color(hex: 0x…),没有这个 init 一行都编译不过——搬运时漏了它。
extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}
