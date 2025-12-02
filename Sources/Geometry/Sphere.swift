// Sphere.swift
// 球体几何定义 (CPU 端)

import simd

struct Sphere {
    var center: Point3
    var radius: Float
    var materialIndex: UInt32
    var transformIndex: Int32  // -1 表示无变换

    // MARK: - 初始化

    init(center: Point3, radius: Float, materialIndex: UInt32 = 0, transformIndex: Int32 = -1) {
        self.center = center
        self.radius = radius
        self.materialIndex = materialIndex
        self.transformIndex = transformIndex
    }

    // MARK: - 转换为 GPU 数据

    func toGPU() -> GPUSphere {
        return GPUSphere(
            center: center,
            radius: radius,
            materialIndex: materialIndex,
            transformIndex: transformIndex,
            padding: SIMD2<Float>(0, 0)
        )
    }
}
