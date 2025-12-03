// Material.swift
// 材质定义 (CPU 端)

import simd

// MARK: - 材质类型枚举

enum MaterialType: UInt32 {
    case lambertian = 0
    case metal = 1
    case dielectric = 2
    case diffuseLight = 3
}

// MARK: - 材质结构

struct Material {
    var type: MaterialType
    var albedo: Color           // 固定颜色（无纹理时使用）
    var fuzz: Float             // Metal 材质用
    var refractionIndex: Float  // Dielectric 材质用
    var textureIndex: Int32     // 纹理索引（-1表示无纹理）
    var emission: Color         // 发光颜色

    // MARK: - 便捷构造函数

    /// 创建 Lambertian 漫反射材质（固定颜色）
    static func lambertian(albedo: Color) -> Material {
        return Material(
            type: .lambertian,
            albedo: albedo,
            fuzz: 0,
            refractionIndex: 1.0,
            textureIndex: -1,
            emission: Color(0, 0, 0)
        )
    }

    /// 创建 Lambertian 漫反射材质（纹理）
    static func lambertian(textureIndex: Int32) -> Material {
        return Material(
            type: .lambertian,
            albedo: Color(0, 0, 0),
            fuzz: 0,
            refractionIndex: 1.0,
            textureIndex: textureIndex,
            emission: Color(0, 0, 0)
        )
    }

    /// 创建 Metal 金属材质
    static func metal(albedo: Color, fuzz: Float) -> Material {
        return Material(
            type: .metal,
            albedo: albedo,
            fuzz: min(fuzz, 1.0),
            refractionIndex: 1.0,
            textureIndex: -1,
            emission: Color(0, 0, 0)
        )
    }

    /// 创建 Dielectric 电介质材质
    static func dielectric(refractionIndex: Float) -> Material {
        return Material(
            type: .dielectric,
            albedo: Color(1, 1, 1),
            fuzz: 0,
            refractionIndex: refractionIndex,
            textureIndex: -1,
            emission: Color(0, 0, 0)
        )
    }

    /// 创建 DiffuseLight 发光材质（固定颜色）
    static func diffuseLight(emission: Color) -> Material {
        return Material(
            type: .diffuseLight,
            albedo: Color(0, 0, 0),
            fuzz: 0,
            refractionIndex: 1.0,
            textureIndex: -1,
            emission: emission
        )
    }

    /// 创建 DiffuseLight 发光材质（纹理）
    static func diffuseLight(textureIndex: Int32) -> Material {
        return Material(
            type: .diffuseLight,
            albedo: Color(0, 0, 0),
            fuzz: 0,
            refractionIndex: 1.0,
            textureIndex: textureIndex,
            emission: Color(0, 0, 0)
        )
    }

    // MARK: - 转换为 GPU 数据

    func toGPU() -> GPUMaterial {
        return GPUMaterial(
            type: type.rawValue,
            padding1: SIMD3<UInt32>(0, 0, 0),
            albedo: albedo,
            fuzz: fuzz,
            refractionIndex: refractionIndex,
            textureIndex: textureIndex,
            padding2: SIMD2<Float>(0, 0),
            emission: emission,
            padding3: 0
        )
    }
}
