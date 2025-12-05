// FinalScene.swift
// 最终场景 - Ray Tracing: The Next Week 的完整演示场景
// 参考：~/ray_tracing/src/scenes/final_scene.cc

import simd

/// 创建最终场景
/// 包含：地面盒子、面光源、运动模糊球、玻璃球、金属球、地球纹理、Perlin噪声、小球集群
func createFinalScene() -> Scene {
    var scene = Scene()

    // ========================================
    // 材质定义
    // ========================================

    // 地面材质：绿灰色漫反射
    let groundMat = Material.lambertian(albedo: SIMD3<Float>(0.48, 0.83, 0.53))
    let groundMatIdx = scene.addMaterial(groundMat)

    // 面光源材质：白色强光
    let lightMat = Material.diffuseLight(emission: SIMD3<Float>(7, 7, 7))
    let lightMatIdx = scene.addMaterial(lightMat)

    // 运动模糊球材质：棕橙色漫反射
    let movingSphereMat = Material.lambertian(albedo: SIMD3<Float>(0.7, 0.3, 0.1))
    let movingSphereMatIdx = scene.addMaterial(movingSphereMat)

    // 玻璃材质
    let glassMat = Material.dielectric(refractionIndex: 1.5)
    let glassMatIdx = scene.addMaterial(glassMat)

    // 金属材质：银灰色，完全模糊
    let metalMat = Material.metal(albedo: SIMD3<Float>(0.8, 0.8, 0.9), fuzz: 1.0)
    let metalMatIdx = scene.addMaterial(metalMat)

    // 地球纹理材质（注册图片路径，稍后自动加载）
    scene.requireImageTexture("earthmap.jpg")
    let earthTexIdx = scene.addTexture(ImageTexture(path: "Resources/images/earthmap.jpg", index: 0))
    let earthMat = Material.lambertian(textureIndex: earthTexIdx)
    let earthMatIdx = scene.addMaterial(earthMat)

    // Perlin 噪声材质
    let noiseTexIdx = scene.addTexture(NoiseTexture(scale: 0.2))
    let noiseMat = Material.lambertian(textureIndex: noiseTexIdx)
    let noiseMatIdx = scene.addMaterial(noiseMat)

    // 小白球材质
    let whiteMat = Material.lambertian(albedo: SIMD3<Float>(0.73, 0.73, 0.73))
    let whiteMatIdx = scene.addMaterial(whiteMat)

    // ========================================
    // 1. 地面：400个随机高度盒子 (20×20网格)
    // ========================================
    // 位置: 底部 (y=0 到 y=1~101)
    // 覆盖范围: x: -1000~1000, z: -1000~1000

    let boxesPerSide = 20
    for i in 0..<boxesPerSide {
        for j in 0..<boxesPerSide {
            let w: Float = 100.0
            let x0 = -1000.0 + Float(i) * w
            let z0 = -1000.0 + Float(j) * w
            let y0: Float = 0.0
            let x1 = x0 + w
            let y1 = Float.random(in: 1...101)  // 随机高度
            let z1 = z0 + w

            // 创建盒子 (使用6个Quad)
            let p0 = SIMD3<Float>(x0, y0, z0)
            let p1 = SIMD3<Float>(x1, y1, z1)

            // 底面
            scene.add(Quad(
                corner: SIMD3<Float>(p0.x, p0.y, p0.z),
                sideA: SIMD3<Float>(p1.x - p0.x, 0, 0),
                sideB: SIMD3<Float>(0, 0, p1.z - p0.z),
                materialIndex: groundMatIdx
            ))

            // 顶面
            scene.add(Quad(
                corner: SIMD3<Float>(p0.x, p1.y, p0.z),
                sideA: SIMD3<Float>(p1.x - p0.x, 0, 0),
                sideB: SIMD3<Float>(0, 0, p1.z - p0.z),
                materialIndex: groundMatIdx
            ))

            // 前面
            scene.add(Quad(
                corner: SIMD3<Float>(p0.x, p0.y, p0.z),
                sideA: SIMD3<Float>(p1.x - p0.x, 0, 0),
                sideB: SIMD3<Float>(0, p1.y - p0.y, 0),
                materialIndex: groundMatIdx
            ))

            // 后面
            scene.add(Quad(
                corner: SIMD3<Float>(p0.x, p0.y, p1.z),
                sideA: SIMD3<Float>(p1.x - p0.x, 0, 0),
                sideB: SIMD3<Float>(0, p1.y - p0.y, 0),
                materialIndex: groundMatIdx
            ))

            // 左面
            scene.add(Quad(
                corner: SIMD3<Float>(p0.x, p0.y, p0.z),
                sideA: SIMD3<Float>(0, 0, p1.z - p0.z),
                sideB: SIMD3<Float>(0, p1.y - p0.y, 0),
                materialIndex: groundMatIdx
            ))

            // 右面
            scene.add(Quad(
                corner: SIMD3<Float>(p1.x, p0.y, p0.z),
                sideA: SIMD3<Float>(0, 0, p1.z - p0.z),
                sideB: SIMD3<Float>(0, p1.y - p0.y, 0),
                materialIndex: groundMatIdx
            ))
        }
    }

    // ========================================
    // 2. 面光源 (天花板)
    // ========================================
    scene.add(Quad(
        corner: SIMD3<Float>(123, 554, 147),
        sideA: SIMD3<Float>(300, 0, 0),
        sideB: SIMD3<Float>(0, 0, 265),
        materialIndex: lightMatIdx
    ))

    // ========================================
    // 3. 运动模糊球体（简化为静态球）
    // ========================================
    // 注：GPU 版本暂不支持运动模糊，使用静态位置
    scene.add(Sphere(
        center: SIMD3<Float>(400, 400, 200),
        radius: 50,
        materialIndex: movingSphereMatIdx
    ))

    // ========================================
    // 4. 玻璃球 #1
    // ========================================
    scene.add(Sphere(
        center: SIMD3<Float>(260, 150, 45),
        radius: 50,
        materialIndex: glassMatIdx
    ))

    // ========================================
    // 5. 金属球 (模糊反射)
    // ========================================
    scene.add(Sphere(
        center: SIMD3<Float>(0, 150, 145),
        radius: 50,
        materialIndex: metalMatIdx
    ))

    // ========================================
    // 6. 玻璃球 #2
    // ========================================
    scene.add(Sphere(
        center: SIMD3<Float>(360, 150, 145),
        radius: 70,
        materialIndex: glassMatIdx
    ))

    // ========================================
    // 7. 地球纹理球体
    // ========================================
    scene.add(Sphere(
        center: SIMD3<Float>(400, 200, 400),
        radius: 100,
        materialIndex: earthMatIdx
    ))

    // ========================================
    // 8. Perlin 噪声球体 (大理石纹理)
    // ========================================
    scene.add(Sphere(
        center: SIMD3<Float>(220, 280, 300),
        radius: 80,
        materialIndex: noiseMatIdx
    ))

    // ========================================
    // 9. 1000个小白球集群 (带Y轴15°旋转)
    // ========================================
    let clusterTransform = Transform(
        translation: SIMD3<Float>(-100, 270, 395),
        rotation: SIMD3<Float>(0, 15, 0)
    )
    let clusterTransformIdx = Int32(scene.addTransform(clusterTransform))

    let ns = 1000
    for _ in 0..<ns {
        let randomPos = SIMD3<Float>(
            Float.random(in: 0...165),
            Float.random(in: 0...165),
            Float.random(in: 0...165)
        )

        scene.add(Sphere(
            center: randomPos,
            radius: 10,
            materialIndex: whiteMatIdx,
            transformIndex: clusterTransformIdx
        ))
    }

    // ========================================
    // 相机配置
    // ========================================
    scene.camera.aspectRatio = 1.0
    scene.camera.imageWidth = 800
    scene.camera.samplesPerPixel = 10  // 降低采样（GPU优化）
    scene.camera.maxDepth = 10
    scene.camera.useBackground = false  // 黑色背景
    scene.camera.vfov = 40
    scene.camera.lookFrom = SIMD3<Float>(478, 278, -600)
    scene.camera.lookAt = SIMD3<Float>(278, 278, 0)
    scene.camera.vup = SIMD3<Float>(0, 1, 0)
    scene.camera.defocusAngle = 0
    scene.camera.movementSpeed = 50.0  // Large scene (555 units): 10x default speed

    return scene
}
