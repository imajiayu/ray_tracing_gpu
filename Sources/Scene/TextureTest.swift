// TextureTest.swift
// 纹理测试场景 - 地球纹理

import simd

/// 创建纹理测试场景
/// 展示地球图片纹理
/// 注意：图片纹理需要在main.swift中加载后添加到scene
func createTextureTestScene() -> Scene {
    var scene = Scene()

    // 纹理 0: 地球图片纹理（需要在main.swift中加载）
    let earthTexIdx = scene.addTexture(ImageTexture(path: "Resources/images/earthmap.jpg", index: 0))

    // 纹理 1: Checker 纹理（用于地面）
    let checkerTexIdx = scene.addTexture(CheckerTexture(
        scale: 0.32,
        evenColor: SIMD3<Float>(0.2, 0.3, 0.1),
        oddColor: SIMD3<Float>(0.9, 0.9, 0.9)
    ))

    // 材质
    let groundMat = Material.lambertian(textureIndex: checkerTexIdx)
    let earthMat = Material.lambertian(textureIndex: earthTexIdx)
    // let fogMat = Material.isotropic(albedo: SIMD3<Float>(0.9, 0.9, 0.9))  // 白色体积雾

    scene.materials.append(groundMat)    // 0
    scene.materials.append(earthMat)     // 1
    // scene.materials.append(fogMat)       // 2

    // 地面（棋盘格纹理）
    scene.add(Sphere(
        center: SIMD3<Float>(0, -1000, 0),
        radius: 1000,
        materialIndex: 0
    ))

    // 地球球体（图片纹理）
    // let earthSphereIdx = UInt32(scene.geometry.getSpheres().count)
    scene.add(Sphere(
        center: SIMD3<Float>(0, 2, 0),
        radius: 2,
        materialIndex: 1
    ))

    // TODO: 体积雾功能待修复，暂时注释
    // 体积雾：包裹地球球体
    // scene.add(ConstantMedium(
    //     sphereIndex: earthSphereIdx,
    //     density: 0.5,  // 密度：0.5 = 中等雾效
    //     materialIndex: 2
    // ))

    // 相机配置
    scene.camera.aspectRatio = 16.0 / 9.0
    scene.camera.imageWidth = 800
    scene.camera.samplesPerPixel = 100
    scene.camera.maxDepth = 50
    scene.camera.vfov = 20
    scene.camera.lookFrom = SIMD3<Float>(13, 2, 3)
    scene.camera.lookAt = SIMD3<Float>(0, 2, 0)
    scene.camera.vup = SIMD3<Float>(0, 1, 0)
    scene.camera.defocusAngle = 0
    scene.camera.useBackground = true

    return scene
}
