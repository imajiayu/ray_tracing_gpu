// main.swift
// Ray Tracing GPU - Phase 2: 材质测试

import Foundation
import Metal
import MetalKit

// MARK: - 场景选择

enum SceneType {
    case bouncingSpheres       // 经典 Bouncing Spheres 场景
    case cornellBox            // 标准 Cornell Box 场景
    case textureTest           // 纹理测试场景
    case finalScene            // 最终场景（完整演示）
}

// 解析命令行参数
guard let cmdArgs = CommandLineArgs.parse() else {
    exit(0)  // 解析失败或显示帮助后退出
}

// 获取场景类型
guard let currentScene = cmdArgs.getSceneType() else {
    print("错误: 未知场景 '\(cmdArgs.sceneName)'")
    print("可用场景: bouncingSpheres, cornellBox, textureTest, finalScene")
    exit(1)
}

// MARK: - PPM 保存

/// 保存为 PPM 图片
func savePPM(pixels: [Float], width: Int, height: Int, filename: String) {
    var ppmContent = "P3\n\(width) \(height)\n255\n"

    for y in 0..<height {
        for x in 0..<width {
            let index = (y * width + x) * 4
            let r = pixels[index]
            let g = pixels[index + 1]
            let b = pixels[index + 2]

            // Gamma 校正 (gamma = 2)
            let rGamma = sqrt(r)
            let gGamma = sqrt(g)
            let bGamma = sqrt(b)

            // 转换为 0-255
            let ir = UInt8(256 * Swift.min(Swift.max(rGamma, 0), 0.999))
            let ig = UInt8(256 * Swift.min(Swift.max(gGamma, 0), 0.999))
            let ib = UInt8(256 * Swift.min(Swift.max(bGamma, 0), 0.999))

            ppmContent += "\(ir) \(ig) \(ib)\n"
        }
    }

    do {
        try ppmContent.write(toFile: filename, atomically: true, encoding: .utf8)
        print("[Output] ✓ Saved: \(filename)")
    } catch {
        print("[Output] ❌ Failed to save: \(error)")
    }
}

// MARK: - 主程序

print("=== Ray Tracing GPU ===")
print("Scene: \(cmdArgs.sceneName)")

// 1. 初始化 Metal
guard let context = MetalContext() else {
    print("❌ Failed to initialize Metal")
    exit(1)
}

// 2. 加载着色器库
let metalLibPath = "Resources/default.metallib"
guard let library = try? context.device.makeLibrary(URL: URL(fileURLWithPath: metalLibPath)) else {
    print("❌ Failed to load shader library from: \(metalLibPath)")
    print("   Make sure to run: ./compile_shaders.sh")
    exit(1)
}

// 3. 创建计算管线
guard let pipeline = context.makeComputePipeline(functionName: "simple_raytrace", library: library) else {
    print("❌ Failed to create compute pipeline")
    exit(1)
}

// 4. 创建场景
print("[Scene] Creating scene...")
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

// 应用命令行参数覆盖场景配置
if let spp = cmdArgs.spp {
    scene.camera.samplesPerPixel = UInt32(spp)
}
if let maxDepth = cmdArgs.maxDepth {
    scene.camera.maxDepth = UInt32(maxDepth)
}
if let width = cmdArgs.width {
    scene.camera.imageWidth = width
}

// 加载图片纹理（如果场景需要）
let imageLoader = ImageLoader(device: context.device)
if currentScene == .textureTest || currentScene == .finalScene {
    if let earthTexture = imageLoader.loadTextureSearching(filename: "earthmap.jpg") {
        scene.addImageTexture(earthTexture)
    } else {
        print("⚠️  Failed to load earth texture, will show magenta")
    }
}

// 转换为 GPU 数据
let (gpuSpheres, gpuQuads, gpuConstantMediums, gpuMaterials, gpuTextures, gpuTransforms) = scene.toGPU()

print("[Scene] ✓ \(gpuSpheres.count) spheres, \(gpuQuads.count) quads, \(gpuConstantMediums.count) constant mediums, \(gpuMaterials.count) materials, \(gpuTextures.count) textures, \(gpuTransforms.count) transforms, \(scene.imageTextures.count) image textures")

// 5. 创建 GPU 缓冲区
guard let sphereBuffer = context.makeBuffer(array: gpuSpheres),
      let materialBuffer = context.makeBuffer(array: gpuMaterials) else {
    print("❌ Failed to create buffers")
    exit(1)
}

// 创建 Quad 缓冲区（如果有）
let quadBuffer: MTLBuffer?
if gpuQuads.isEmpty {
    // 即使没有 quad，也需要创建一个空缓冲区避免 Metal 错误
    quadBuffer = context.device.makeBuffer(length: MemoryLayout<GPUQuad>.stride, options: [])
} else {
    quadBuffer = context.makeBuffer(array: gpuQuads)
}

guard quadBuffer != nil else {
    print("❌ Failed to create quad buffer")
    exit(1)
}

// 创建纹理缓冲区（如果有）
let textureBuffer: MTLBuffer?
if gpuTextures.isEmpty {
    // 即使没有纹理，也需要创建一个空缓冲区避免 Metal 错误
    textureBuffer = context.device.makeBuffer(length: MemoryLayout<GPUTexture>.stride, options: [])
} else {
    textureBuffer = context.makeBuffer(array: gpuTextures)
}

guard textureBuffer != nil else {
    print("❌ Failed to create texture buffer")
    exit(1)
}

// 创建变换缓冲区（如果有）
let transformBuffer: MTLBuffer?
if gpuTransforms.isEmpty {
    // 即使没有变换，也需要创建一个空缓冲区避免 Metal 错误
    transformBuffer = context.device.makeBuffer(length: MemoryLayout<GPUTransform>.stride, options: [])
} else {
    transformBuffer = context.makeBuffer(array: gpuTransforms)
}

guard transformBuffer != nil else {
    print("❌ Failed to create transform buffer")
    exit(1)
}

// 创建体积雾缓冲区（如果有）
let constantMediumBuffer: MTLBuffer?
if gpuConstantMediums.isEmpty {
    // 即使没有体积雾，也需要创建一个空缓冲区避免 Metal 错误
    constantMediumBuffer = context.device.makeBuffer(length: MemoryLayout<GPUConstantMedium>.stride, options: [])
} else {
    constantMediumBuffer = context.makeBuffer(array: gpuConstantMediums)
}

guard constantMediumBuffer != nil else {
    print("❌ Failed to create constant medium buffer")
    exit(1)
}

// 6. 设置相机（从 CameraConfig 读取）
let aspectRatio = scene.camera.aspectRatio
let cameraOrigin = scene.camera.lookFrom
let lookAt = scene.camera.lookAt
let vup = scene.camera.vup
let vfov = scene.camera.vfov

// 计算图像尺寸（需要先定义，因为后面会用到）
let width = scene.camera.imageWidth
let height = Int(Float(width) / aspectRatio)

// 计算相机参数（与 CPU 版本完全一致）
let theta = vfov * Float.pi / 180.0
let h = tan(theta / 2.0)
let focusDistance: Float = scene.camera.focusDist  // 使用配置的 focus_dist
let viewportHeight = 2.0 * h * focusDistance
let viewportWidth = aspectRatio * viewportHeight

// 相机基向量（右手坐标系，与 CPU 版本一致）
let w = normalize(cameraOrigin - lookAt)  // 相机看向的反方向
let u = normalize(simd_cross(vup, w))      // 右方向
let v = simd_cross(w, u)                        // 上方向

// 视口向量（与 CPU 版本一致）
let viewportU = viewportWidth * u          // 水平方向（右）
let viewportV = -viewportHeight * v        // 垂直方向（下）

// 计算每个像素的增量（与 CPU 版本一致）
let pixelDeltaU = viewportU / Float(width)
let pixelDeltaV = viewportV / Float(height)

// 视口左上角
let viewportUpperLeft = cameraOrigin - focusDistance * w - viewportU/2 - viewportV/2

// pixel00 位置：视口左上角 + 半个像素的偏移（与 CPU 版本一致）
let pixel00Loc = viewportUpperLeft + (pixelDeltaU + pixelDeltaV) * 0.5

// 传给 shader 的参数
let lowerLeftCorner = pixel00Loc  // 第一个像素的中心位置
let horizontal = pixelDeltaU       // 每个像素的 X 增量
let vertical = pixelDeltaV         // 每个像素的 Y 增量

var cameraParams = GPUCameraParams(
    origin: cameraOrigin,
    lowerLeftCorner: lowerLeftCorner,
    horizontal: horizontal,
    vertical: vertical
)

// 7. 渲染参数（从 CameraConfig 读取）
let samplesPerPixel = scene.camera.samplesPerPixel
let maxDepth = scene.camera.maxDepth
let useBackground: UInt32 = scene.camera.useBackground ? 1 : 0

var renderParams = GPURenderParams(
    width: UInt32(width),
    height: UInt32(height),
    samplesPerPixel: samplesPerPixel,
    maxDepth: maxDepth,
    sphereCount: UInt32(gpuSpheres.count),
    quadCount: UInt32(gpuQuads.count),
    constantMediumCount: UInt32(gpuConstantMediums.count),
    useBackground: useBackground,
    sampleOffset: 0  // 初始偏移量为0，每个batch会更新
)

print("[Render] Resolution: \(width)×\(height)")
print("[Render] Samples: \(samplesPerPixel) spp")
print("[Render] Max depth: \(maxDepth)")

// 8. 创建输出纹理
guard let outputTexture = context.makeTexture(width: width, height: height) else {
    print("❌ Failed to create output texture")
    exit(1)
}

// 9. 执行渐进式渲染（避免 GPU 超时）
print("[Render] Starting progressive GPU rendering...")

let startTime = Date()

// 将采样分批处理，每批处理少量采样（避免 GPU 超时）
let samplesPerBatch: UInt32 = UInt32(cmdArgs.batchSize)
let batchCount = (samplesPerPixel + samplesPerBatch - 1) / samplesPerBatch

print("[Render] Total batches: \(batchCount) × \(samplesPerBatch) spp")

for batch in 0..<batchCount {
    let currentBatchSamples = min(samplesPerBatch, samplesPerPixel - batch * samplesPerBatch)

    var batchParams = renderParams
    batchParams.samplesPerPixel = currentBatchSamples
    batchParams.sampleOffset = batch * samplesPerBatch  // 设置当前batch的样本偏移量

    guard let commandBuffer = context.makeCommandBuffer() else {
        print("❌ Failed to create command buffer")
        exit(1)
    }

    guard let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
        print("❌ Failed to create compute encoder")
        exit(1)
    }

    computeEncoder.setComputePipelineState(pipeline)
    computeEncoder.setTexture(outputTexture, index: 0)

    // 设置图片纹理（如果有）
    if !scene.imageTextures.isEmpty {
        computeEncoder.setTexture(scene.imageTextures[0], index: 1)
    }

    computeEncoder.setBuffer(sphereBuffer, offset: 0, index: 0)
    computeEncoder.setBuffer(materialBuffer, offset: 0, index: 1)
    computeEncoder.setBytes(&cameraParams, length: MemoryLayout<GPUCameraParams>.size, index: 2)
    computeEncoder.setBytes(&batchParams, length: MemoryLayout<GPURenderParams>.size, index: 3)
    computeEncoder.setBuffer(quadBuffer, offset: 0, index: 4)
    computeEncoder.setBuffer(textureBuffer, offset: 0, index: 5)
    computeEncoder.setBuffer(transformBuffer, offset: 0, index: 6)
    computeEncoder.setBuffer(constantMediumBuffer, offset: 0, index: 7)

    // 设置线程组大小
    let threadsPerGrid = MTLSize(width: width, height: height, depth: 1)
    let threadsPerThreadgroup = MTLSize(width: 16, height: 16, depth: 1)
    computeEncoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)

    computeEncoder.endEncoding()
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()

    if (batch + 1) % 10 == 0 || batch == batchCount - 1 {
        let progress = Float(batch + 1) / Float(batchCount) * 100
        print("[Render] Progress: \(String(format: "%.1f", progress))% (\(batch + 1)/\(batchCount) batches)")
    }
}

let renderTime = Date().timeIntervalSince(startTime)
print("[Render] ✓ Completed in \(String(format: "%.2f", renderTime * 1000)) ms")

// 10. 读取结果并保存
print("[Output] Reading texture data...")

let bytesPerPixel = 4 * MemoryLayout<Float>.size
let bytesPerRow = width * bytesPerPixel
var pixelData = [Float](repeating: 0, count: width * height * 4)

let region = MTLRegionMake2D(0, 0, width, height)
outputTexture.getBytes(&pixelData, bytesPerRow: bytesPerRow, from: region, mipmapLevel: 0)

// 对累积的颜色进行平均
let totalSamples = Float(samplesPerPixel)
for i in 0..<(width * height * 4) {
    pixelData[i] /= totalSamples
}

savePPM(pixels: pixelData, width: width, height: height, filename: cmdArgs.outputFile)

// 11. 统计信息
let totalPixels = width * height
let totalRays = totalPixels * Int(samplesPerPixel)
let raysPerSecond = Double(totalRays) / renderTime

print("\n=== Statistics ===")
print("Total pixels: \(totalPixels)")
print("Total rays: \(totalRays)")
print("Rays/second: \(String(format: "%.2f", raysPerSecond / 1_000_000)) M")
print("Time per pixel: \(String(format: "%.2f", renderTime * 1000000 / Double(totalPixels))) μs")

print("\n✅ Rendering Completed!")
print("Output: \(cmdArgs.outputFile)")
