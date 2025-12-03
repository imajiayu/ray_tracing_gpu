// PerlinData.swift
// Perlin 噪声数据生成器（使用 PCG，与 CPU 版本完全一致）

import simd

/// PCG32 随机数生成器（与 CPU 版本完全一致）
struct PCG32 {
    private var state: UInt64
    private let inc: UInt64 = 1442695040888963407

    init(seed: UInt64 = 42) {
        self.state = 0
        _ = next()
        self.state &+= seed
        _ = next()
    }

    mutating func next() -> UInt32 {
        let oldState = state
        state = oldState &* 6364136223846793005 &+ inc

        let xorShifted = UInt32(truncatingIfNeeded: ((oldState >> 18) ^ oldState) >> 27)
        let rot = UInt32(truncatingIfNeeded: oldState >> 59)

        return (xorShifted >> rot) | (xorShifted << ((UInt32(0) &- rot) & 31))
    }

    /// 生成 [0, 1) 范围的浮点数
    /// 注意：与 CPU 版本一致，除以 2^32 (4294967296.0) 而不是 UInt32.max (4294967295)
    mutating func uniformFloat() -> Float {
        return Float(next()) / 4294967296.0  // 2^32，与 ldexp(rng(), -32) 一致
    }

    /// 生成 [min, max) 范围的浮点数
    mutating func uniformFloat(min: Float, max: Float) -> Float {
        return min + (max - min) * uniformFloat()
    }

    /// 生成 [min, max] 范围的整数
    mutating func uniformInt(min: Int, max: Int) -> Int {
        let range = UInt32(max - min + 1)
        return min + Int(next() % range)
    }
}

/// Perlin 噪声数据（与 CPU 版本完全一致）
struct PerlinData {
    static let pointCount = 256

    var randvec: [SIMD3<Float>]  // 256 个梯度向量
    var permX: [Int32]            // X 轴置换表
    var permY: [Int32]            // Y 轴置换表
    var permZ: [Int32]            // Z 轴置换表

    /// 使用固定种子 42 初始化（与 CPU 版本一致）
    init(seed: UInt64 = 42) {
        var rng = PCG32(seed: seed)

        // 1. 生成 256 个随机梯度向量
        randvec = []
        for _ in 0..<Self.pointCount {
            let x = rng.uniformFloat(min: -1, max: 1)
            let y = rng.uniformFloat(min: -1, max: 1)
            let z = rng.uniformFloat(min: -1, max: 1)
            let vec = normalize(SIMD3<Float>(x, y, z))
            randvec.append(vec)
        }

        // 2. 生成三个置换表
        permX = Self.generatePermutation(rng: &rng)
        permY = Self.generatePermutation(rng: &rng)
        permZ = Self.generatePermutation(rng: &rng)
    }

    /// 生成置换表（与 CPU 版本的 perlin_generate_perm 一致）
    private static func generatePermutation(rng: inout PCG32) -> [Int32] {
        var p: [Int32] = Array(0..<Int32(pointCount))
        permute(&p, rng: &rng)
        return p
    }

    /// 置换数组（与 CPU 版本的 permute 一致）
    private static func permute(_ p: inout [Int32], rng: inout PCG32) {
        for i in stride(from: pointCount - 1, through: 1, by: -1) {
            let target = rng.uniformInt(min: 0, max: i)
            p.swapAt(i, target)
        }
    }
}
