// Interval.swift
// 数学区间类（用于范围检测）

struct Interval {
    var min: Float
    var max: Float

    // MARK: - 静态常量

    static let empty = Interval(min: Float.infinity, max: -Float.infinity)
    static let universe = Interval(min: -Float.infinity, max: Float.infinity)

    // MARK: - 初始化

    init(min: Float, max: Float) {
        self.min = min
        self.max = max
    }

    // MARK: - 范围检测

    /// 检测是否包含 x (闭区间 [min, max])
    func contains(_ x: Float) -> Bool {
        return min <= x && x <= max
    }

    /// 检测是否包围 x (开区间 (min, max))
    func surrounds(_ x: Float) -> Bool {
        return min < x && x < max
    }

    /// 将 x 限制在区间内
    func clamp(_ x: Float) -> Float {
        if x < min { return min }
        if x > max { return max }
        return x
    }

    /// 区间大小
    var size: Float {
        return max - min
    }

    /// 扩展区间（两侧各加 delta）
    func expand(_ delta: Float) -> Interval {
        let padding = delta / 2
        return Interval(min: min - padding, max: max + padding)
    }
}
