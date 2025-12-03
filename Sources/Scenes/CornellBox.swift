// CornellBox.swift
// 标准 Cornell Box 场景（参考 CPU 版本）

import simd

/// 创建 Cornell Box 场景
/// 包含标准 Cornell Box 墙壁、面光源、白色盒子和玻璃球
func createCornellBoxScene() -> Scene {
    var scene = Scene()

    // 材质定义
    let redMaterial = Material.lambertian(albedo: SIMD3<Float>(0.65, 0.05, 0.05))
    let whiteMaterial = Material.lambertian(albedo: SIMD3<Float>(0.73, 0.73, 0.73))
    let greenMaterial = Material.lambertian(albedo: SIMD3<Float>(0.12, 0.45, 0.15))
    let lightMaterial = Material.diffuseLight(emission: SIMD3<Float>(15, 15, 15))
    let glassMaterial = Material.dielectric(refractionIndex: 1.5)

    scene.materials.append(redMaterial)    // 0: 红色
    scene.materials.append(whiteMaterial)  // 1: 白色
    scene.materials.append(greenMaterial)  // 2: 绿色
    scene.materials.append(lightMaterial)  // 3: 光源
    scene.materials.append(glassMaterial)  // 4: 玻璃

    // Cornell Box 墙壁（555x555x555 单位）

    // 右墙（绿色）- X=555 面
    scene.add(Quad(
        corner: SIMD3<Float>(555, 0, 0),
        sideA: SIMD3<Float>(0, 0, 555),
        sideB: SIMD3<Float>(0, 555, 0),
        materialIndex: 2
    ))

    // 左墙（红色）- X=0 面
    scene.add(Quad(
        corner: SIMD3<Float>(0, 0, 555),
        sideA: SIMD3<Float>(0, 0, -555),
        sideB: SIMD3<Float>(0, 555, 0),
        materialIndex: 0
    ))

    // 天花板（白色）- Y=555 面
    scene.add(Quad(
        corner: SIMD3<Float>(0, 555, 0),
        sideA: SIMD3<Float>(555, 0, 0),
        sideB: SIMD3<Float>(0, 0, 555),
        materialIndex: 1
    ))

    // 地板（白色）- Y=0 面
    scene.add(Quad(
        corner: SIMD3<Float>(0, 0, 555),
        sideA: SIMD3<Float>(555, 0, 0),
        sideB: SIMD3<Float>(0, 0, -555),
        materialIndex: 1
    ))

    // 后墙（白色）- Z=555 面
    scene.add(Quad(
        corner: SIMD3<Float>(555, 0, 555),
        sideA: SIMD3<Float>(-555, 0, 0),
        sideB: SIMD3<Float>(0, 555, 0),
        materialIndex: 1
    ))

    // 面光源（顶部中心）
    scene.add(Quad(
        corner: SIMD3<Float>(213, 554, 227),
        sideA: SIMD3<Float>(130, 0, 0),
        sideB: SIMD3<Float>(0, 0, 105),
        materialIndex: 3
    ))

    // 镜面盒子（6个quad组成，使用变换）
    // 镜面金属材质（全反射）
    let mirrorMaterial = Material.metal(albedo: SIMD3<Float>(0.9, 0.9, 0.9), fuzz: 0.0)
    scene.materials.append(mirrorMaterial)  // 5: 镜面材质

    // 创建一个长方体 (100x180x100)，中心在原点
    // 高一些，这样倾斜后能更好地反射球体
    let boxSize = SIMD3<Float>(100, 180, 100)
    let boxMin = -boxSize / 2
    let boxMax = boxSize / 2

    let dx = SIMD3<Float>(boxSize.x, 0, 0)
    let dy = SIMD3<Float>(0, boxSize.y, 0)
    let dz = SIMD3<Float>(0, 0, boxSize.z)

    // 创建变换：让盒子倾斜，使其只有一个角接触地面
    // 对于长方体，底角到中心的距离约为 sqrt((100/2)^2 + (180/2)^2 + (100/2)^2) = sqrt(13100) ≈ 114.5
    // 使用 pitch=35, yaw=45, roll=0 来实现倾斜效果
    let distSquared: Float = 2500.0 + 8100.0 + 2500.0  // 50^2 + 90^2 + 50^2
    let cornerHeight: Float = sqrt(distSquared)  // 约 114.5
    let boxTransform = Transform(
        translation: SIMD3<Float>(350, cornerHeight, 350),  // 抬高到角刚好接触地面
        rotation: SIMD3<Float>(35, 45, 0)  // pitch=35度倾斜，yaw=45度旋转
    )
    let boxTransformIndex = scene.addTransform(boxTransform)

    // Box 6个面（相对于中心定义，将通过变换移动和旋转）
    // 前面 (z=max)
    scene.add(Quad(
        corner: SIMD3<Float>(boxMin.x, boxMin.y, boxMax.z),
        sideA: dx,
        sideB: dy,
        materialIndex: 5,
        transformIndex: boxTransformIndex
    ))
    // 右面 (x=max)
    scene.add(Quad(
        corner: SIMD3<Float>(boxMax.x, boxMin.y, boxMax.z),
        sideA: -dz,
        sideB: dy,
        materialIndex: 5,
        transformIndex: boxTransformIndex
    ))
    // 后面 (z=min)
    scene.add(Quad(
        corner: SIMD3<Float>(boxMax.x, boxMin.y, boxMin.z),
        sideA: -dx,
        sideB: dy,
        materialIndex: 5,
        transformIndex: boxTransformIndex
    ))
    // 左面 (x=min)
    scene.add(Quad(
        corner: SIMD3<Float>(boxMin.x, boxMin.y, boxMin.z),
        sideA: dz,
        sideB: dy,
        materialIndex: 5,
        transformIndex: boxTransformIndex
    ))
    // 顶面 (y=max)
    scene.add(Quad(
        corner: SIMD3<Float>(boxMin.x, boxMax.y, boxMax.z),
        sideA: dx,
        sideB: -dz,
        materialIndex: 5,
        transformIndex: boxTransformIndex
    ))
    // 底面 (y=min)
    scene.add(Quad(
        corner: SIMD3<Float>(boxMin.x, boxMin.y, boxMin.z),
        sideA: dx,
        sideB: dz,
        materialIndex: 5,
        transformIndex: boxTransformIndex
    ))

    // 玻璃球
    scene.add(Sphere(
        center: SIMD3<Float>(190, 90, 190),
        radius: 90,
        materialIndex: 4
    ))

    // 相机配置
    scene.camera.aspectRatio = 1.0
    scene.camera.imageWidth = 600
    scene.camera.samplesPerPixel = 1000
    scene.camera.maxDepth = 50
    scene.camera.useBackground = false  // 黑色背景
    scene.camera.vfov = 40
    scene.camera.lookFrom = SIMD3<Float>(278, 278, -800)
    scene.camera.lookAt = SIMD3<Float>(278, 278, 0)
    scene.camera.vup = SIMD3<Float>(0, 1, 0)
    scene.camera.defocusAngle = 0  // 无景深

    return scene
}
