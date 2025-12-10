// SceneBuilder.swift
// 场景构建辅助扩展 - 提供简洁的API用于构建场景

import simd

/// Scene 扩展 - 提供简洁的场景构建API
extension Scene {
    // MARK: - 材质构建器

    /// 添加漫反射材质
    @discardableResult
    mutating func addLambertian(albedo: SIMD3<Float>) -> UInt32 {
        return addMaterial(.lambertian(albedo: albedo))
    }

    /// 添加棋盘格漫反射材质
    @discardableResult
    mutating func addLambertianChecker(scale: Float, evenColor: SIMD3<Float>, oddColor: SIMD3<Float>) -> UInt32 {
        let texIdx = addTexture(CheckerTexture(scale: scale, evenColor: evenColor, oddColor: oddColor))
        return addMaterial(.lambertian(textureIndex: texIdx))
    }

    /// 添加图像纹理漫反射材质
    @discardableResult
    mutating func addLambertianImage(path: String) -> UInt32 {
        requireImageTexture(path)
        // 使用当前图像纹理数量作为索引（自动递增）
        let imageIndex = Int32(imageTexturePaths.count - 1)
        let texIdx = addTexture(ImageTexture(path: "Resources/images/\(path)", index: imageIndex))
        return addMaterial(.lambertian(textureIndex: texIdx))
    }

    /// 添加 Perlin 噪声漫反射材质
    @discardableResult
    mutating func addLambertianNoise(scale: Float) -> UInt32 {
        let texIdx = addTexture(NoiseTexture(scale: scale))
        return addMaterial(.lambertian(textureIndex: texIdx))
    }

    /// 添加金属材质
    @discardableResult
    mutating func addMetal(albedo: SIMD3<Float>, fuzz: Float = 0.0) -> UInt32 {
        return addMaterial(.metal(albedo: albedo, fuzz: fuzz))
    }

    /// 添加电介质材质（玻璃）
    @discardableResult
    mutating func addDielectric(refractionIndex: Float = 1.5) -> UInt32 {
        return addMaterial(.dielectric(refractionIndex: refractionIndex))
    }

    /// 添加发光材质
    @discardableResult
    mutating func addEmissive(emission: SIMD3<Float>) -> UInt32 {
        return addMaterial(.diffuseLight(emission: emission))
    }

    /// 添加各向同性散射材质（用于体积雾）
    @discardableResult
    mutating func addIsotropic(albedo: SIMD3<Float>) -> UInt32 {
        return addMaterial(.isotropic(albedo: albedo))
    }

    /// 添加各向同性散射材质（纹理版本）
    @discardableResult
    mutating func addIsotropicImage(path: String) -> UInt32 {
        requireImageTexture(path)
        let imageIndex = Int32(imageTexturePaths.count - 1)
        let texIdx = addTexture(ImageTexture(path: "Resources/images/\(path)", index: imageIndex))
        return addMaterial(.isotropic(textureIndex: texIdx))
    }

    // MARK: - 几何体构建器

    /// 添加球体
    @discardableResult
    mutating func addSphere(center: SIMD3<Float>, radius: Float, materialIndex: UInt32, transformIndex: Int32 = -1) -> Int {
        add(Sphere(center: center, radius: radius, materialIndex: materialIndex, transformIndex: transformIndex))
        return geometry.getSpheres().count - 1
    }

    /// 添加体积雾球体（Constant Medium）
    /// 注意：此函数只添加雾球本身，不添加边界球
    /// 如果需要玻璃外壳，请在调用此函数前手动添加玻璃球
    /// - Parameters:
    ///   - center: 球心
    ///   - radius: 半径
    ///   - density: 密度（控制雾的浓度）
    ///   - albedo: 雾的颜色
    ///   - transformIndex: 变换索引（可选）
    ///   - boundaryRefraction: 边界折射率（默认1.5，用于边界检测）
    /// - Returns: 球体索引
    @discardableResult
    mutating func addConstantMediumSphere(
        center: SIMD3<Float>,
        radius: Float,
        density: Float,
        albedo: SIMD3<Float>,
        transformIndex: Int32 = -1,
        boundaryRefraction: Float = 1.5
    ) -> Int {
        // 创建边界材质（dielectric，用于边界hit检测）
        let boundaryMat = addDielectric(refractionIndex: boundaryRefraction)

        // 创建体积散射材质
        let isotropicMat = addIsotropic(albedo: albedo)

        // 添加体积雾球体（带体积雾参数）
        add(Sphere(
            center: center,
            radius: radius,
            materialIndex: boundaryMat,
            transformIndex: transformIndex,
            negInvDensity: -1.0 / density,
            isotropicMatIndex: isotropicMat
        ))

        return geometry.getSpheres().count - 1
    }

    /// 添加四边形
    @discardableResult
    mutating func addQuad(corner: SIMD3<Float>, sideA: SIMD3<Float>, sideB: SIMD3<Float>, materialIndex: UInt32, transformIndex: Int32 = -1) -> Int {
        add(Quad(corner: corner, sideA: sideA, sideB: sideB, materialIndex: materialIndex, transformIndex: transformIndex))
        return geometry.getQuads().count - 1
    }

    /// 添加立方体（6个四边形组成）
    /// - Parameters:
    ///   - min: 最小点 (x_min, y_min, z_min)
    ///   - max: 最大点 (x_max, y_max, y_max)
    ///   - materialIndex: 材质索引
    ///   - transformIndex: 变换索引（可选）
    /// - Returns: 6个四边形的索引数组
    @discardableResult
    mutating func addBox(min: SIMD3<Float>, max: SIMD3<Float>, materialIndex: UInt32, transformIndex: Int32 = -1) -> [Int] {
        let dx = SIMD3<Float>(max.x - min.x, 0, 0)
        let dy = SIMD3<Float>(0, max.y - min.y, 0)
        let dz = SIMD3<Float>(0, 0, max.z - min.z)

        var indices: [Int] = []

        // 前面 (z = min.z)
        indices.append(addQuad(
            corner: SIMD3<Float>(min.x, min.y, min.z),
            sideA: dx,
            sideB: dy,
            materialIndex: materialIndex,
            transformIndex: transformIndex
        ))

        // 后面 (z = max.z)
        indices.append(addQuad(
            corner: SIMD3<Float>(max.x, min.y, max.z),
            sideA: -dx,
            sideB: dy,
            materialIndex: materialIndex,
            transformIndex: transformIndex
        ))

        // 左面 (x = min.x)
        indices.append(addQuad(
            corner: SIMD3<Float>(min.x, min.y, max.z),
            sideA: -dz,
            sideB: dy,
            materialIndex: materialIndex,
            transformIndex: transformIndex
        ))

        // 右面 (x = max.x)
        indices.append(addQuad(
            corner: SIMD3<Float>(max.x, min.y, min.z),
            sideA: dz,
            sideB: dy,
            materialIndex: materialIndex,
            transformIndex: transformIndex
        ))

        // 底面 (y = min.y)
        indices.append(addQuad(
            corner: SIMD3<Float>(min.x, min.y, min.z),
            sideA: dx,
            sideB: dz,
            materialIndex: materialIndex,
            transformIndex: transformIndex
        ))

        // 顶面 (y = max.y)
        indices.append(addQuad(
            corner: SIMD3<Float>(min.x, max.y, max.z),
            sideA: dx,
            sideB: -dz,
            materialIndex: materialIndex,
            transformIndex: transformIndex
        ))

        return indices
    }

    // MARK: - 光源管理（扩展）

    // 注意：markLastQuadAsLight 和 markLastSphereAsLight 已在 Scene 中定义
    // 这里不需要重复定义

    // MARK: - 相机配置快捷方法

    /// 设置相机基本参数
    mutating func setupCamera(
        lookFrom: SIMD3<Float>,
        lookAt: SIMD3<Float>,
        vup: SIMD3<Float> = SIMD3<Float>(0, 1, 0),
        vfov: Float = 40,
        aspectRatio: Float = 1.0
    ) {
        camera.lookFrom = lookFrom
        camera.lookAt = lookAt
        camera.vup = vup
        camera.vfov = vfov
        camera.aspectRatio = aspectRatio
        camera.focusDist = simd_length(lookFrom - lookAt)
    }

    /// 设置渲染质量参数
    mutating func setupQuality(
        imageWidth: Int = 800,
        samplesPerPixel: UInt32 = 100,
        maxDepth: UInt32 = 50
    ) {
        camera.imageWidth = imageWidth
        camera.samplesPerPixel = samplesPerPixel
        camera.maxDepth = maxDepth
    }

    /// 设置景深效果
    mutating func setupDepthOfField(
        defocusAngle: Float,
        focusDist: Float? = nil
    ) {
        camera.defocusAngle = defocusAngle
        if let dist = focusDist {
            camera.focusDist = dist
        }
    }

    /// 设置背景
    mutating func setupBackground(enabled: Bool) {
        camera.useBackground = enabled
    }
}
