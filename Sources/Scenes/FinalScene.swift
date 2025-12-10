// FinalScene.swift
// 最终场景 - Ray Tracing: The Next Week 的完整演示场景
// 参考：~/ray_tracing/src/scenes/final_scene.cc

import simd

/// 创建最终场景
/// 包含：地面盒子、面光源、运动模糊球、玻璃球、金属球、体积雾、地球纹理、Perlin噪声、小球集群
func createFinalScene() -> Scene {
    var scene = Scene()

    // 材质定义
    let groundMat = scene.addLambertian(albedo: SIMD3<Float>(0.48, 0.83, 0.53))
    let lightMat = scene.addEmissive(emission: SIMD3<Float>(7, 7, 7))
    let movingSphereMat = scene.addLambertian(albedo: SIMD3<Float>(0.7, 0.3, 0.1))
    let glassMat = scene.addDielectric()
    let metalMat = scene.addMetal(albedo: SIMD3<Float>(0.8, 0.8, 0.9), fuzz: 1.0)
    let earthMat = scene.addLambertianImage(path: "earthmap.jpg")
    let noiseMat = scene.addLambertianNoise(scale: 0.2)
    let whiteMat = scene.addLambertian(albedo: SIMD3<Float>(0.73, 0.73, 0.73))

    // 1. 地面：400个随机高度盒子 (20×20网格)
    let boxesPerSide = 20
    for i in 0..<boxesPerSide {
        for j in 0..<boxesPerSide {
            let w: Float = 100.0
            let x0 = -1000.0 + Float(i) * w
            let z0 = -1000.0 + Float(j) * w
            let y0: Float = 0.0
            let x1 = x0 + w
            let y1 = Float.random(in: 1...101)
            let z1 = z0 + w

            scene.addBox(
                min: SIMD3<Float>(x0, y0, z0),
                max: SIMD3<Float>(x1, y1, z1),
                materialIndex: groundMat
            )
        }
    }

    // 2. 面光源 (天花板)
    scene.addQuad(
        corner: SIMD3<Float>(123, 554, 147),
        sideA: SIMD3<Float>(300, 0, 0),
        sideB: SIMD3<Float>(0, 0, 265),
        materialIndex: lightMat
    )

    // 3. 运动模糊球体（简化为静态球）
    scene.addSphere(
        center: SIMD3<Float>(400, 400, 200),
        radius: 50,
        materialIndex: movingSphereMat
    )

    // 4-6. 玻璃球和金属球
    scene.addSphere(center: SIMD3<Float>(260, 150, 45), radius: 50, materialIndex: glassMat)
    scene.addSphere(center: SIMD3<Float>(0, 150, 145), radius: 50, materialIndex: metalMat)

    // 玻璃球#2 + 内部蓝色体积雾（参考 final_scene.cc:88-92）
    scene.addSphere(center: SIMD3<Float>(360, 150, 145), radius: 70, materialIndex: glassMat)
    scene.addConstantMediumSphere(
        center: SIMD3<Float>(360, 150, 145),
        radius: 70,
        density: 0.2,
        albedo: SIMD3<Float>(0.2, 0.4, 0.9),
        boundaryRefraction: 1.5
    )

    // 全局大气雾（参考 final_scene.cc:95-103）
    scene.addConstantMediumSphere(
        center: SIMD3<Float>(0, 0, 0),
        radius: 5000,
        density: 0.0001,
        albedo: SIMD3<Float>(1, 1, 1),
        boundaryRefraction: 1.5
    )

    // 7. 地球纹理球体
    scene.addSphere(
        center: SIMD3<Float>(400, 200, 400),
        radius: 100,
        materialIndex: earthMat
    )

    // 8. Perlin 噪声球体 (大理石纹理)
    scene.addSphere(
        center: SIMD3<Float>(220, 280, 300),
        radius: 80,
        materialIndex: noiseMat
    )

    // 9. 1000个小白球集群 (带Y轴15°旋转)
    let clusterTransform = Transform(
        translation: SIMD3<Float>(-100, 270, 395),
        rotation: SIMD3<Float>(0, 15, 0)
    )
    let clusterTransformIdx = scene.addTransform(clusterTransform)

    for _ in 0..<1000 {
        let randomPos = SIMD3<Float>(
            Float.random(in: 0...165),
            Float.random(in: 0...165),
            Float.random(in: 0...165)
        )

        scene.addSphere(
            center: randomPos,
            radius: 10,
            materialIndex: whiteMat,
            transformIndex: clusterTransformIdx
        )
    }

    // 相机配置
    scene.setupCamera(
        lookFrom: SIMD3<Float>(478, 278, -600),
        lookAt: SIMD3<Float>(278, 278, 0),
        vfov: 40,
        aspectRatio: 1.0
    )

    scene.setupQuality(
        imageWidth: 800,
        samplesPerPixel: 10,
        maxDepth: 10
    )

    scene.setupDepthOfField(defocusAngle: 0)
    scene.setupBackground(enabled: false)

    scene.camera.movementSpeed = 50.0  // Large scene (555 units): 10x default speed

    return scene
}
