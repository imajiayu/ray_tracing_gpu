// Vec3.swift
// 3D 向量类型（使用 Swift SIMD）

import simd

// 类型别名（提供语义清晰度）
typealias Vec3 = SIMD3<Float>
typealias Point3 = SIMD3<Float>

// Vec3 扩展方法
extension SIMD3 where Scalar == Float {
    // MARK: - 长度相关

    var length: Float {
        simd_length(self)
    }

    var lengthSquared: Float {
        simd_length_squared(self)
    }

    // MARK: - 归一化

    var normalized: SIMD3<Float> {
        simd_normalize(self)
    }

    // MARK: - 随机向量生成

    /// 生成 [0, 1) 随机向量
    static func random() -> SIMD3<Float> {
        SIMD3<Float>(
            Float.random(in: 0..<1),
            Float.random(in: 0..<1),
            Float.random(in: 0..<1)
        )
    }

    /// 生成指定范围内的随机向量
    static func random(in range: Range<Float>) -> SIMD3<Float> {
        SIMD3<Float>(
            Float.random(in: range),
            Float.random(in: range),
            Float.random(in: range)
        )
    }

    /// 生成随机单位向量（均匀分布在单位球面上）
    static func randomUnitVector() -> SIMD3<Float> {
        while true {
            let p = SIMD3<Float>.random(in: -1..<1)
            let lensq = simd_length_squared(p)
            if lensq < 1 && lensq > 1e-8 {
                return p / sqrt(lensq)
            }
        }
    }

    /// 生成半球上的随机向量
    static func randomOnHemisphere(_ normal: SIMD3<Float>) -> SIMD3<Float> {
        let onUnitSphere = randomUnitVector()
        if simd_dot(onUnitSphere, normal) > 0.0 {
            return onUnitSphere
        } else {
            return -onUnitSphere
        }
    }

    /// 生成单位圆盘上的随机点（用于景深）
    static func randomInUnitDisk() -> SIMD3<Float> {
        while true {
            let p = SIMD3<Float>(
                Float.random(in: -1..<1),
                Float.random(in: -1..<1),
                0
            )
            if simd_length_squared(p) < 1 {
                return p
            }
        }
    }

    // MARK: - 反射与折射

    /// 反射向量（参考 vec3.h:reflect）
    func reflect(n: SIMD3<Float>) -> SIMD3<Float> {
        return self - 2 * simd_dot(self, n) * n
    }

    /// 折射向量（参考 vec3.h:refract）
    /// - Parameters:
    ///   - n: 法线
    ///   - etaiOverEtat: 折射率比值 (eta_i / eta_t)
    func refract(n: SIMD3<Float>, etaiOverEtat: Float) -> SIMD3<Float> {
        let cosTheta = min(simd_dot(-self, n), 1.0)
        let rOutPerp = etaiOverEtat * (self + cosTheta * n)
        let rOutParallel = -sqrt(abs(1.0 - simd_length_squared(rOutPerp))) * n
        return rOutPerp + rOutParallel
    }

    // MARK: - 实用方法

    /// 检测向量是否接近零
    var isNearZero: Bool {
        let s: Float = 1e-8
        return abs(x) < s && abs(y) < s && abs(z) < s
    }
}
