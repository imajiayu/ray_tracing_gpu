// BouncingSpheres.swift
// 经典 Bouncing Spheres 场景（参考 CPU 版本）

import simd

/// 创建 Bouncing Spheres 场景
/// 包含大量随机球体、3个大球（玻璃、漫反射、金属）
func createBouncingSpheresScene() -> Scene {
    var scene = Scene()
    var materialIndex: UInt32 = 0

    // 地面：大球体 + Checker 纹理（与CPU版本一致）
    let checkerTexIdx = scene.addTexture(CheckerTexture(
        scale: 0.32,
        evenColor: SIMD3<Float>(0.2, 0.3, 0.1),
        oddColor: SIMD3<Float>(0.9, 0.9, 0.9)
    ))
    scene.materials.append(Material.lambertian(textureIndex: checkerTexIdx))
    scene.add(Sphere(center: SIMD3<Float>(0, -1000, 0), radius: 1000, materialIndex: materialIndex))
    materialIndex += 1

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
                if chooseMat < 0.8 {
                    // Diffuse (80%)
                    let albedo = SIMD3<Float>(
                        Float.random(in: 0..<1) * Float.random(in: 0..<1),
                        Float.random(in: 0..<1) * Float.random(in: 0..<1),
                        Float.random(in: 0..<1) * Float.random(in: 0..<1)
                    )
                    scene.materials.append(Material.lambertian(albedo: albedo))
                    scene.add(Sphere(center: center, radius: 0.2, materialIndex: materialIndex))
                    materialIndex += 1
                } else if chooseMat < 0.95 {
                    // Metal (15%)
                    let albedo = SIMD3<Float>(
                        Float.random(in: 0.5..<1),
                        Float.random(in: 0.5..<1),
                        Float.random(in: 0.5..<1)
                    )
                    let fuzz = Float.random(in: 0..<0.5)
                    scene.materials.append(Material.metal(albedo: albedo, fuzz: fuzz))
                    scene.add(Sphere(center: center, radius: 0.2, materialIndex: materialIndex))
                    materialIndex += 1
                } else {
                    // Glass (5%)
                    scene.materials.append(Material.dielectric(refractionIndex: 1.5))
                    scene.add(Sphere(center: center, radius: 0.2, materialIndex: materialIndex))
                    materialIndex += 1
                }
            }
        }
    }

    // 3 个大球
    // 中心玻璃球
    scene.materials.append(Material.dielectric(refractionIndex: 1.5))
    scene.add(Sphere(center: SIMD3<Float>(0, 1, 0), radius: 1.0, materialIndex: materialIndex))
    materialIndex += 1

    // 左侧漫反射球
    scene.materials.append(Material.lambertian(albedo: SIMD3<Float>(0.4, 0.2, 0.1)))
    scene.add(Sphere(center: SIMD3<Float>(-4, 1, 0), radius: 1.0, materialIndex: materialIndex))
    materialIndex += 1

    // 右侧金属球
    scene.materials.append(Material.metal(albedo: SIMD3<Float>(0.7, 0.6, 0.5), fuzz: 0.0))
    scene.add(Sphere(center: SIMD3<Float>(4, 1, 0), radius: 1.0, materialIndex: materialIndex))


    // 相机配置
    scene.camera.aspectRatio = 16.0 / 9.0
    scene.camera.imageWidth = 800
    scene.camera.samplesPerPixel = 500  // 使用渐进式渲染，可以支持更高采样数
    scene.camera.maxDepth = 50          // 使用渐进式渲染后可以恢复完整深度
    scene.camera.vfov = 20
    scene.camera.lookFrom = SIMD3<Float>(13, 2, 3)
    scene.camera.lookAt = SIMD3<Float>(0, 0, 0)
    scene.camera.vup = SIMD3<Float>(0, 1, 0)
    scene.camera.defocusAngle = 0.6
    // focusDist 将自动计算为 lookFrom 到 lookAt 的距离
    scene.camera.focusDist = simd_length(scene.camera.lookFrom - scene.camera.lookAt)
    scene.camera.useBackground = true
    scene.camera.movementSpeed = 5.0  // Small scene: default speed

    return scene
}
