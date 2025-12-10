// CornellBox.swift
// 标准 Cornell Box 场景（参考 CPU 版本）

import simd

/// 创建 Cornell Box 场景
/// 包含标准 Cornell Box 墙壁、面光源、镜面盒子和玻璃球
func createCornellBoxScene() -> Scene {
    var scene = Scene()

    // 材质定义
    let redMat = scene.addLambertian(albedo: SIMD3<Float>(0.65, 0.05, 0.05))
    let whiteMat = scene.addLambertian(albedo: SIMD3<Float>(0.73, 0.73, 0.73))
    let greenMat = scene.addLambertian(albedo: SIMD3<Float>(0.12, 0.45, 0.15))
    let lightMat = scene.addEmissive(emission: SIMD3<Float>(15, 15, 15))
    let mirrorMat = scene.addMetal(albedo: SIMD3<Float>(0.9, 0.9, 0.9), fuzz: 0.0)
    let glassMat = scene.addDielectric()

    // Cornell Box 墙壁（555x555x555 单位）
    // 绿色右墙 (X=555)
    scene.addQuad(
        corner: SIMD3<Float>(555, 0, 0),
        sideA: SIMD3<Float>(0, 0, 555),
        sideB: SIMD3<Float>(0, 555, 0),
        materialIndex: greenMat
    )

    // 红色左墙 (X=0)
    scene.addQuad(
        corner: SIMD3<Float>(0, 0, 555),
        sideA: SIMD3<Float>(0, 0, -555),
        sideB: SIMD3<Float>(0, 555, 0),
        materialIndex: redMat
    )

    // 白色天花板 (Y=555)
    scene.addQuad(
        corner: SIMD3<Float>(0, 555, 0),
        sideA: SIMD3<Float>(555, 0, 0),
        sideB: SIMD3<Float>(0, 0, 555),
        materialIndex: whiteMat
    )

    // 白色地板 (Y=0)
    scene.addQuad(
        corner: SIMD3<Float>(0, 0, 555),
        sideA: SIMD3<Float>(555, 0, 0),
        sideB: SIMD3<Float>(0, 0, -555),
        materialIndex: whiteMat
    )

    // 白色后墙 (Z=555)
    scene.addQuad(
        corner: SIMD3<Float>(555, 0, 555),
        sideA: SIMD3<Float>(-555, 0, 0),
        sideB: SIMD3<Float>(0, 555, 0),
        materialIndex: whiteMat
    )

    // 面光源（顶部中心）
    scene.addQuad(
        corner: SIMD3<Float>(213, 554, 227),
        sideA: SIMD3<Float>(130, 0, 0),
        sideB: SIMD3<Float>(0, 0, 105),
        materialIndex: lightMat
    )
    scene.markLastQuadAsLight()

    // 镜面盒子（带变换：倾斜）
    let boxSize = SIMD3<Float>(100, 180, 100)
    let boxMin = -boxSize / 2
    let boxMax = boxSize / 2

    // 计算变换：使盒子倾斜，一个角接触地面
    let distSquared: Float = 2500.0 + 8100.0 + 2500.0  // 50^2 + 90^2 + 50^2
    let cornerHeight: Float = sqrt(distSquared)  // 约 114.5

    let boxTransform = Transform(
        translation: SIMD3<Float>(350, cornerHeight, 350),
        rotation: SIMD3<Float>(35, 45, 0)
    )
    let boxTransformIdx = scene.addTransform(boxTransform)

    scene.addBox(min: boxMin, max: boxMax, materialIndex: mirrorMat, transformIndex: boxTransformIdx)

    // 玻璃球
    scene.addSphere(
        center: SIMD3<Float>(190, 90, 190),
        radius: 90,
        materialIndex: glassMat
    )

    // 相机配置
    scene.setupCamera(
        lookFrom: SIMD3<Float>(278, 278, -800),
        lookAt: SIMD3<Float>(278, 278, 0),
        vfov: 40,
        aspectRatio: 1.0
    )

    scene.setupQuality(
        imageWidth: 600,
        samplesPerPixel: 1000,
        maxDepth: 50
    )

    scene.setupDepthOfField(defocusAngle: 0)
    scene.setupBackground(enabled: false)

    scene.camera.movementSpeed = 200.0  // Large scene (555 units): 10x default speed

    return scene
}
