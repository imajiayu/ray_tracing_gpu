// BouncingSpheres.swift
// 经典 Bouncing Spheres 场景（参考 CPU 版本）

import simd

/// 创建 Bouncing Spheres 场景
/// 包含大量随机球体、3个大球（玻璃、漫反射、金属）
func createBouncingSpheresScene() -> Scene {
    var scene = Scene()

    // 地面：大球体 + Checker 纹理
    let groundMat = scene.addLambertianChecker(
        scale: 0.32,
        evenColor: SIMD3<Float>(0.2, 0.3, 0.1),
        oddColor: SIMD3<Float>(0.9, 0.9, 0.9)
    )
    scene.addSphere(center: SIMD3<Float>(0, -1000, 0), radius: 1000, materialIndex: groundMat)

    // 随机小球体
    for a in -11..<11 {
        for b in -11..<11 {
            let chooseMat = Float.random(in: 0..<1)
            let center = SIMD3<Float>(
                Float(a) + 0.9 * Float.random(in: 0..<1),
                0.2,
                Float(b) + 0.9 * Float.random(in: 0..<1)
            )

            // 避免与大球重叠
            if simd_length(center - SIMD3<Float>(4, 0.2, 0)) > 0.9 {
                let matIdx: UInt32
                if chooseMat < 0.8 {
                    // Diffuse (80%)
                    let albedo = SIMD3<Float>(
                        Float.random(in: 0..<1) * Float.random(in: 0..<1),
                        Float.random(in: 0..<1) * Float.random(in: 0..<1),
                        Float.random(in: 0..<1) * Float.random(in: 0..<1)
                    )
                    matIdx = scene.addLambertian(albedo: albedo)
                } else if chooseMat < 0.95 {
                    // Metal (15%)
                    let albedo = SIMD3<Float>(
                        Float.random(in: 0.5..<1),
                        Float.random(in: 0.5..<1),
                        Float.random(in: 0.5..<1)
                    )
                    let fuzz = Float.random(in: 0..<0.5)
                    matIdx = scene.addMetal(albedo: albedo, fuzz: fuzz)
                } else {
                    // Glass (5%)
                    matIdx = scene.addDielectric()
                }

                scene.addSphere(center: center, radius: 0.2, materialIndex: matIdx)
            }
        }
    }

    // 3 个大球
    let glassMat = scene.addDielectric()
    scene.addSphere(center: SIMD3<Float>(0, 1, 0), radius: 1.0, materialIndex: glassMat)

    let brownMat = scene.addLambertian(albedo: SIMD3<Float>(0.4, 0.2, 0.1))
    scene.addSphere(center: SIMD3<Float>(-4, 1, 0), radius: 1.0, materialIndex: brownMat)

    let metalMat = scene.addMetal(albedo: SIMD3<Float>(0.7, 0.6, 0.5), fuzz: 0.0)
    scene.addSphere(center: SIMD3<Float>(4, 1, 0), radius: 1.0, materialIndex: metalMat)

    // 相机配置
    scene.setupCamera(
        lookFrom: SIMD3<Float>(13, 2, 3),
        lookAt: SIMD3<Float>(0, 0, 0),
        vfov: 20,
        aspectRatio: 16.0 / 9.0
    )

    scene.setupQuality(
        imageWidth: 800,
        samplesPerPixel: 500,
        maxDepth: 50
    )

    scene.setupDepthOfField(defocusAngle: 0.6)
    scene.setupBackground(enabled: true)

    scene.camera.movementSpeed = 5.0  // Small scene: default speed

    return scene
}
