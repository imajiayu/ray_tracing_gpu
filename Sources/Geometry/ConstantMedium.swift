// ConstantMedium.swift
// 体积雾几何定义 (CPU 端)
// 用于实现烟雾、云层等体积散射效果

import simd

/// 体积雾边界类型
enum ConstantMediumBoundary {
    case sphere(index: UInt32)  // 引用 spheres 数组中的球体
    // 未来可扩展: case quad(index: UInt32)
}

/// 体积雾几何体
///
/// 原理：
/// - 在边界几何体内部，光线按负指数分布随机散射
/// - 密度越高，散射越频繁
/// - 使用 isotropic 材质实现各向同性散射
struct ConstantMedium {
    var boundaryType: UInt32        // 0 = sphere, 1 = quad (未来扩展)
    var boundaryIndex: UInt32       // 引用边界几何体的索引
    var negInvDensity: Float        // -1 / density，用于加速计算
    var materialIndex: UInt32       // isotropic 材质索引

    // MARK: - 初始化

    /// 创建以球体为边界的体积雾
    /// - Parameters:
    ///   - sphereIndex: spheres 数组中的球体索引
    ///   - density: 密度（越高越浓）
    ///   - materialIndex: isotropic 材质索引
    init(sphereIndex: UInt32, density: Float, materialIndex: UInt32) {
        self.boundaryType = 0  // sphere
        self.boundaryIndex = sphereIndex
        self.negInvDensity = -1.0 / density
        self.materialIndex = materialIndex
    }

    // MARK: - 便捷构造

    /// 创建球形体积雾
    static func sphereBoundary(index: UInt32, density: Float, materialIndex: UInt32) -> ConstantMedium {
        return ConstantMedium(sphereIndex: index, density: density, materialIndex: materialIndex)
    }

    // MARK: - 转换为 GPU 数据

    func toGPU() -> GPUConstantMedium {
        return GPUConstantMedium(
            boundaryType: boundaryType,
            boundaryIndex: boundaryIndex,
            negInvDensity: negInvDensity,
            materialIndex: materialIndex,
            padding: SIMD3<Float>(0, 0, 0)
        )
    }
}
