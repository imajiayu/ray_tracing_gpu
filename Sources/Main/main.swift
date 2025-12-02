// main.swift
// Ray Tracing GPU - 主程序入口

import Foundation
import Metal
import MetalKit

// MARK: - 主程序

print("=== Ray Tracing GPU ===")

// 1. 解析命令行参数
guard let cmdArgs = CommandLineArgs.parse() else {
    exit(0)
}

print("Scene: \(cmdArgs.sceneName)")

// 2. 初始化 Metal
guard let context = MetalContext() else {
    print("❌ Failed to initialize Metal")
    exit(1)
}

// 3. 加载着色器库
let metalLibPath = "Resources/default.metallib"
guard let library = try? context.device.makeLibrary(URL: URL(fileURLWithPath: metalLibPath)) else {
    print("❌ Failed to load shader library from: \(metalLibPath)")
    print("   Make sure to run: ./compile_shaders.sh")
    exit(1)
}

// 4. 创建计算管线
guard let pipeline = context.makeComputePipeline(functionName: "simple_raytrace", library: library) else {
    print("❌ Failed to create compute pipeline")
    exit(1)
}

// 5. 创建场景
print("[Scene] Creating scene...")

guard let currentScene = cmdArgs.getSceneType() else {
    print("❌ 未知场景: '\(cmdArgs.sceneName)'")
    print("可用场景: bouncingSpheres, cornellBox, textureTest, finalScene")
    exit(1)
}

var scene = switch currentScene {
case .bouncingSpheres:
    createBouncingSpheresScene()
case .cornellBox:
    createCornellBoxScene()
case .textureTest:
    createTextureTestScene()
case .finalScene:
    createFinalScene()
}

// 应用命令行参数覆盖
if let spp = cmdArgs.spp {
    scene.camera.samplesPerPixel = UInt32(spp)
}
if let maxDepth = cmdArgs.maxDepth {
    scene.camera.maxDepth = UInt32(maxDepth)
}
if let width = cmdArgs.width {
    scene.camera.imageWidth = width
}
if let defocusAngle = cmdArgs.defocusAngle {
    scene.camera.defocusAngle = defocusAngle
}
if let focusDist = cmdArgs.focusDist {
    scene.camera.focusDist = focusDist
}

// 6. 加载图片纹理（如果需要）
let imageLoader = ImageLoader(device: context.device)
if currentScene == .textureTest || currentScene == .finalScene {
    if let earthTexture = imageLoader.loadTextureSearching(filename: "earthmap.jpg") {
        scene.addImageTexture(earthTexture)
    } else {
        print("⚠️  Failed to load earth texture, will show magenta")
    }
}

// 7. 转换为 GPU 数据并构建 BVH
let (gpuSpheres, gpuQuads, gpuConstantMediums, gpuMaterials, gpuTextures, gpuTransforms) = scene.toGPU()

print("[Scene] ✓ \(gpuSpheres.count) spheres, \(gpuQuads.count) quads, \(gpuConstantMediums.count) constant mediums, \(gpuMaterials.count) materials, \(gpuTextures.count) textures, \(gpuTransforms.count) transforms, \(scene.imageTextures.count) image textures")

// 8. 构建 BVH
let bvh = FlatBVH()
let spheres = scene.geometry.getSpheres()
let quads = scene.geometry.getQuads()

bvh.build(spheres: spheres, quads: quads, transforms: scene.cpuTransforms, debug: false)
print("[BVH] ✓ Built BVH: \(bvh.nodes.count) nodes, \(bvh.geometryIndices.count) geometry indices")

// 9. 创建相机
let camera = Camera(config: scene.camera)
camera.printInfo()

// 10. 执行渲染 - 根据模式选择
if cmdArgs.mode == "window" {
    // 窗口模式 - 实时渲染
    runWindowMode(
        context: context,
        scene: scene,
        camera: camera,
        bvh: bvh,
        cmdArgs: cmdArgs
    )
} else {
    // Image 模式 - 离线渲染
    let renderer = Renderer(context: context, pipeline: pipeline)
    let (pixelData, renderTime) = renderer.render(
        scene: scene,
        camera: camera,
        bvh: bvh,
        batchSize: cmdArgs.batchSize
    )

    // 11. 保存结果
    var mutablePixelData = pixelData
    ImageWriter.averageAndSavePPM(
        accumulatedPixels: &mutablePixelData,
        samplesPerPixel: scene.camera.samplesPerPixel,
        width: camera.imageWidth,
        height: camera.imageHeight,
        filename: cmdArgs.outputFile
    )

    // 12. 统计信息
    let totalPixels = camera.imageWidth * camera.imageHeight
    let totalRays = totalPixels * Int(scene.camera.samplesPerPixel)
    let raysPerSecond = Double(totalRays) / renderTime

    print("\n=== Statistics ===")
    print("Total pixels: \(totalPixels)")
    print("Total rays: \(totalRays)")
    print("Rays/second: \(String(format: "%.2f", raysPerSecond / 1_000_000)) M")
    print("Time per pixel: \(String(format: "%.2f", renderTime * 1000000 / Double(totalPixels))) μs")

    print("\n✅ Rendering Completed!")
    print("Output: \(cmdArgs.outputFile)")
}
