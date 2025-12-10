// Sphere.swift
// 球体几何定义 (CPU 端)

import simd

struct Sphere {
    var center: Point3
    var radius: Float
    var materialIndex: UInt32
    var transformIndex: Int32  // -1 表示无变换
    var negInvDensity: Float   // 体积雾: -1/density, 0 = 非体积
    var isotropicMatIndex: UInt32  // 体积雾材质索引, 0xFFFFFFFF = 无

    // MARK: - 初始化

    init(center: Point3, radius: Float, materialIndex: UInt32 = 0, transformIndex: Int32 = -1,
         negInvDensity: Float = 0, isotropicMatIndex: UInt32 = 0xFFFFFFFF) {
        self.center = center
        self.radius = radius
        self.materialIndex = materialIndex
        self.transformIndex = transformIndex
        self.negInvDensity = negInvDensity
        self.isotropicMatIndex = isotropicMatIndex
    }

    // MARK: - 转换为 GPU 数据

    func toGPU() -> GPUSphere {
        return GPUSphere(
            center: center,
            radius: radius,
            materialIndex: materialIndex,
            transformIndex: transformIndex,
            negInvDensity: negInvDensity,
            isotropicMatIndex: isotropicMatIndex
        )
    }
}
