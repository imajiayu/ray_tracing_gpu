// Quad.swift
// Phase 2 Task 2.4 - Quad 四边形几何体

import simd

/// Quad (矩形) 几何体
/// 由一个角点和两个边向量定义
struct Quad {
    var corner: Point3
    var sideA: Vec3
    var sideB: Vec3
    var materialIndex: UInt32
    var transformIndex: Int32  // -1 表示无变换

    // 预计算的平面参数
    var normal: Vec3
    var D: Float
    var w: Vec3

    init(corner: Point3, sideA: Vec3, sideB: Vec3, materialIndex: UInt32, transformIndex: Int32 = -1) {
        self.corner = corner
        self.sideA = sideA
        self.sideB = sideB
        self.materialIndex = materialIndex
        self.transformIndex = transformIndex

        // 预计算平面参数
        let n = simd_cross(sideA, sideB)
        self.normal = simd_normalize(n)
        self.D = -simd_dot(self.normal, corner)
        self.w = n * (1.0 / simd_dot(n, n))
    }

    /// 转换为 GPU 数据
    func toGPU() -> GPUQuad {
        return GPUQuad(
            corner: corner,
            padding1: 0,
            sideA: sideA,
            padding2: 0,
            sideB: sideB,
            padding3: 0,
            normal: normal,
            D: D,
            w: w,
            materialIndex: materialIndex,
            transformIndex: transformIndex,
            padding4: SIMD2<Float>(0, 0)
        )
    }
}
