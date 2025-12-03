// TextureTest.swift
// 简化测试场景

import simd

/// 创建简化测试场景
/// 包含：大球地面、顶部光源、1000个小球立方体
func createTextureTestScene() -> Scene {
    var scene = Scene()

    // ========================================
    // 材质定义
    // ========================================

    // 地面材质：浅灰色漫反射
    let groundMat = Material.lambertian(albedo: SIMD3<Float>(0.5, 0.5, 0.5))
    let groundMatIdx = scene.addMaterial(groundMat)

    // 面光源材质：白色光
    let lightMat = Material.diffuseLight(emission: SIMD3<Float>(4, 4, 4))
    let lightMatIdx = scene.addMaterial(lightMat)

    // 小白球材质
    let whiteMat = Material.lambertian(albedo: SIMD3<Float>(0.73, 0.73, 0.73))
    let whiteMatIdx = scene.addMaterial(whiteMat)

    // ========================================
    // 1. 地面：大球
    // ========================================
    scene.add(Sphere(
        center: SIMD3<Float>(0, -1000, 0),
        radius: 1000,
        materialIndex: groundMatIdx
    ))

    // ========================================
    // 2. 顶部光源 (与 FinalScene 一致)
    // ========================================
    scene.add(Quad(
        corner: SIMD3<Float>(123, 554, 147),
        sideA: SIMD3<Float>(300, 0, 0),
        sideB: SIMD3<Float>(0, 0, 265),
        materialIndex: lightMatIdx
    ))

    // ========================================
    // 3. 1000个小白球集群 (带Y轴15°旋转)
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
    scene.camera.samplesPerPixel = 10
    scene.camera.maxDepth = 50
    scene.camera.useBackground = false
    scene.camera.vfov = 40
    scene.camera.lookFrom = SIMD3<Float>(478, 278, -600)
    scene.camera.lookAt = SIMD3<Float>(278, 278, 0)
    scene.camera.vup = SIMD3<Float>(0, 1, 0)
    scene.camera.defocusAngle = 0

    return scene
}
