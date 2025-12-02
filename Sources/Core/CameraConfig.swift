// CameraConfig.swift
// 相机配置结构（参考 CPU 版本）

import simd

/// 相机配置
struct CameraConfig {
    // 图像设置
    var aspectRatio: Float = 16.0 / 9.0
    var imageWidth: Int = 800

    // 采样设置
    var samplesPerPixel: UInt32 = 100
    var maxDepth: UInt32 = 50

    // 相机姿态
    var lookFrom: Point3 = SIMD3<Float>(0, 0, 0)
    var lookAt: Point3 = SIMD3<Float>(0, 0, -1)
    var vup: Vec3 = SIMD3<Float>(0, 1, 0)

    // 视野
    var vfov: Float = 90.0  // 垂直 FOV (度)

    // 景深
    var defocusAngle: Float = 0.0
    var focusDist: Float = 10.0

    // 背景色（0 = 黑色，1 = 天空渐变）
    var useBackground: Bool = true

    /// 默认配置
    static let `default` = CameraConfig()
}
