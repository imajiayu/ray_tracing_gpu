// Transform.swift
// 几何体变换（平移、旋转）

import simd

/// 3D变换
/// 支持平移和旋转（Pitch、Yaw、Roll）
struct Transform {
    var translation: SIMD3<Float>  // 平移向量
    var rotation: SIMD3<Float>     // 旋转角度 (pitch, yaw, roll) in degrees

    // MARK: - 初始化

    /// 默认变换（无变换）
    init() {
        self.translation = SIMD3<Float>(0, 0, 0)
        self.rotation = SIMD3<Float>(0, 0, 0)
    }

    /// 仅平移
    init(translation: SIMD3<Float>) {
        self.translation = translation
        self.rotation = SIMD3<Float>(0, 0, 0)
    }

    /// 仅旋转
    init(rotation: SIMD3<Float>) {
        self.translation = SIMD3<Float>(0, 0, 0)
        self.rotation = rotation
    }

    /// 平移+旋转
    init(translation: SIMD3<Float>, rotation: SIMD3<Float>) {
        self.translation = translation
        self.rotation = rotation
    }

    // MARK: - 便捷构造

    /// 仅Y轴旋转（与CPU版本的rotate_y对应）
    static func rotateY(_ degrees: Float) -> Transform {
        return Transform(rotation: SIMD3<Float>(0, degrees, 0))
    }

    /// 完整的3D旋转
    static func rotate(pitch: Float, yaw: Float, roll: Float) -> Transform {
        return Transform(rotation: SIMD3<Float>(pitch, yaw, roll))
    }

    /// 仅平移
    static func translate(_ offset: SIMD3<Float>) -> Transform {
        return Transform(translation: offset)
    }

    // MARK: - 判断

    /// 是否为恒等变换（无变换）
    var isIdentity: Bool {
        return simd_length(translation) < 1e-6 && simd_length(rotation) < 1e-6
    }

    // MARK: - GPU数据转换

    /// 转换为GPU数据
    func toGPU() -> GPUTransform {
        // 将角度转换为弧度
        let pitch = rotation.x * Float.pi / 180.0
        let yaw = rotation.y * Float.pi / 180.0
        let roll = rotation.z * Float.pi / 180.0

        // 计算旋转矩阵（ZYX顺序：先Roll，再Yaw，最后Pitch）
        // Pitch (绕X轴旋转)
        let cosPitch = cos(pitch)
        let sinPitch = sin(pitch)

        // Yaw (绕Y轴旋转)
        let cosYaw = cos(yaw)
        let sinYaw = sin(yaw)

        // Roll (绕Z轴旋转)
        let cosRoll = cos(roll)
        let sinRoll = sin(roll)

        // 组合旋转矩阵 R = Rz(roll) * Ry(yaw) * Rx(pitch)
        // 展开的3x3旋转矩阵
        let m00 = cosYaw * cosRoll
        let m01 = cosYaw * sinRoll
        let m02 = -sinYaw

        let m10 = sinPitch * sinYaw * cosRoll - cosPitch * sinRoll
        let m11 = sinPitch * sinYaw * sinRoll + cosPitch * cosRoll
        let m12 = sinPitch * cosYaw

        let m20 = cosPitch * sinYaw * cosRoll + sinPitch * sinRoll
        let m21 = cosPitch * sinYaw * sinRoll - sinPitch * cosRoll
        let m22 = cosPitch * cosYaw

        return GPUTransform(
            translation: translation,
            hasRotation: simd_length(rotation) > 1e-6 ? 1 : 0,
            // 旋转矩阵的3行
            rotationRow0: SIMD3<Float>(m00, m01, m02),
            padding0: 0,
            rotationRow1: SIMD3<Float>(m10, m11, m12),
            padding1: 0,
            rotationRow2: SIMD3<Float>(m20, m21, m22),
            padding2: 0
        )
    }
}
