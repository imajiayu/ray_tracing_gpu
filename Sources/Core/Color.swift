// Color.swift
// 颜色处理（gamma 校正、格式转换）

import simd

typealias Color = SIMD3<Float>

extension Color {
    // MARK: - Gamma 校正

    /// Gamma 校正 (gamma = 2.0，使用 sqrt)
    var gammaCorrected: Color {
        return Color(sqrt(x), sqrt(y), sqrt(z))
    }

    // MARK: - 格式转换

    /// 转换为 0-255 整数 RGB
    func toRGB255() -> (r: UInt8, g: UInt8, b: UInt8) {
        let corrected = self.gammaCorrected
        let r = UInt8(256 * corrected.x.clamped(to: 0..<0.999))
        let g = UInt8(256 * corrected.y.clamped(to: 0..<0.999))
        let b = UInt8(256 * corrected.z.clamped(to: 0..<0.999))
        return (r, g, b)
    }

    // MARK: - 预设颜色

    static let black = Color(0, 0, 0)
    static let white = Color(1, 1, 1)
    static let red = Color(1, 0, 0)
    static let green = Color(0, 1, 0)
    static let blue = Color(0, 0, 1)
}

// MARK: - Float 扩展

extension Float {
    /// 将浮点数限制在指定范围内
    func clamped(to range: Range<Float>) -> Float {
        return max(range.lowerBound, min(self, range.upperBound - Float.ulpOfOne))
    }
}
