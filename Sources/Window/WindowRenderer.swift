// WindowRenderer.swift
// Progressive accumulation renderer with real-time display
// 累积渲染窗口 - 实时显示逐步提升质量的图像

import AppKit
import Metal
import MetalKit

class WindowRenderer: NSObject, MTKViewDelegate {
    private let context: MetalContext
    private let scene: Scene
    private let camera: Camera
    private let bvh: FlatBVH

    // Pipelines
    private let rayTracingPipeline: MTLComputePipelineState
    private let conversionPipeline: MTLComputePipelineState

    // GPU buffers (created once)
    private let buffers: GPUBuffers
    private let cameraParams: GPUCameraParams

    // GPU data counts
    private let sphereCount: Int
    private let quadCount: Int
    private let constantMediumCount: Int

    // Accumulation state
    private var accumulationTexture: MTLTexture?
    private var displayTexture: MTLTexture?
    private var currentSample: UInt32 = 0
    private let samplesPerFrame: UInt32

    // Performance tracking
    private var frameCount: Int = 0
    private var lastFPSUpdate: CFAbsoluteTime = 0

    init?(context: MetalContext,
          scene: Scene,
          camera: Camera,
          bvh: FlatBVH,
          samplesPerFrame: UInt32 = 1) {
        self.context = context
        self.scene = scene
        self.camera = camera
        self.bvh = bvh
        self.samplesPerFrame = samplesPerFrame
        self.cameraParams = camera.gpuParams

        // Load Metal library
        let metalLibPath = "Resources/default.metallib"
        guard let library = try? context.device.makeLibrary(URL: URL(fileURLWithPath: metalLibPath)) else {
            print("[WindowRenderer] Failed to load Metal library")
            return nil
        }

        // Create ray tracing pipeline
        guard let rtFunction = library.makeFunction(name: "simple_raytrace"),
              let rtPipeline = try? context.device.makeComputePipelineState(function: rtFunction) else {
            print("[WindowRenderer] Failed to create ray tracing pipeline")
            return nil
        }
        self.rayTracingPipeline = rtPipeline

        // Create conversion pipeline
        guard let convFunction = library.makeFunction(name: "rgb_to_bgra8"),
              let convPipeline = try? context.device.makeComputePipelineState(function: convFunction) else {
            print("[WindowRenderer] Failed to create conversion pipeline")
            return nil
        }
        self.conversionPipeline = convPipeline

        // Create GPU buffers
        let (gpuSpheres, gpuQuads, gpuConstantMediums, gpuMaterials, gpuTextures, gpuTransforms) = scene.toGPU()

        guard let buffers = Self.createBuffers(
            context: context,
            spheres: gpuSpheres,
            quads: gpuQuads,
            constantMediums: gpuConstantMediums,
            materials: gpuMaterials,
            textures: gpuTextures,
            transforms: gpuTransforms,
            bvh: bvh
        ) else {
            print("[WindowRenderer] Failed to create GPU buffers")
            return nil
        }
        self.buffers = buffers

        // 保存 GPU 数据数量
        self.sphereCount = gpuSpheres.count
        self.quadCount = gpuQuads.count
        self.constantMediumCount = gpuConstantMediums.count

        super.init()

        self.lastFPSUpdate = CFAbsoluteTimeGetCurrent()

        print("[WindowRenderer] Initialized")
        print("[WindowRenderer] Target: \(samplesPerFrame) sample(s) per frame")
        print("[WindowRenderer] Geometry: \(sphereCount) spheres, \(quadCount) quads")
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // Reset accumulation when window is resized
        resetAccumulation()
    }

    func draw(in view: MTKView) {
        // Create textures if needed
        if accumulationTexture == nil {
            setupTextures(width: camera.imageWidth, height: camera.imageHeight)
        }

        guard let accTex = accumulationTexture,
              let dispTex = displayTexture,
              let drawable = view.currentDrawable else {
            return
        }

        // 检查是否已达到目标采样数
        let targetSamples = scene.camera.samplesPerPixel
        let shouldRender = currentSample < targetSamples

        if shouldRender {
            // Step 1: Render samples and accumulate
            renderSamples(to: accTex)
            currentSample += samplesPerFrame

            // Step 2: Convert accumulation texture to display format
            convertToDisplay(from: accTex, to: dispTex)

            // 如果刚好达到目标，打印完成信息
            if currentSample >= targetSamples {
                print("\n[WindowRenderer] ✓ Target reached: \(currentSample) / \(targetSamples) spp")
                print("[WindowRenderer] Rendering complete. Window will continue displaying the result.")
            }
        }
        // 如果已达到目标，不再渲染，只显示现有结果（dispTex 保持不变）

        // Step 3: Blit to screen
        guard let commandBuffer = context.commandQueue.makeCommandBuffer(),
              let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
            return
        }

        blitEncoder.copy(
            from: dispTex,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: dispTex.width, height: dispTex.height, depth: 1),
            to: drawable.texture,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )

        blitEncoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()

        // Update statistics
        frameCount += 1
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastFPSUpdate >= 1.0 {
            let fps = Float(frameCount) / Float(now - lastFPSUpdate)
            print("[WindowRenderer] \(currentSample) spp | \(String(format: "%.1f", fps)) FPS")
            frameCount = 0
            lastFPSUpdate = now
        }
    }

    // MARK: - Texture Setup

    private func setupTextures(width: Int, height: Int) {
        // Use the same method as Renderer to create accumulation texture
        guard let accTex = context.makeTexture(width: width, height: height) else {
            print("[WindowRenderer] Failed to create accumulation texture")
            return
        }
        accumulationTexture = accTex

        // IMPORTANT: Clear the texture to zero (Metal textures contain undefined data when created)
        clearTexture(accTex)

        // Display texture (BGRA8)
        let dispDesc = MTLTextureDescriptor()
        dispDesc.width = width
        dispDesc.height = height
        dispDesc.pixelFormat = .bgra8Unorm
        dispDesc.usage = [.shaderRead, .shaderWrite]
        dispDesc.storageMode = .shared

        displayTexture = context.device.makeTexture(descriptor: dispDesc)

        print("[WindowRenderer] Textures created and cleared: \(width)×\(height)")
    }

    private func clearTexture(_ texture: MTLTexture) {
        guard let commandBuffer = context.commandQueue.makeCommandBuffer(),
              let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
            return
        }

        // Use fillBuffer approach: create temp buffer, fill with zeros, copy to texture
        let pixelCount = texture.width * texture.height
        let bufferSize = pixelCount * 4 * MemoryLayout<Float>.stride

        guard let zeroBuffer = context.device.makeBuffer(length: bufferSize, options: .storageModeShared) else {
            return
        }

        // Buffer is already zeroed by default
        zeroBuffer.contents().initializeMemory(as: Float.self, repeating: 0.0, count: pixelCount * 4)

        blitEncoder.copy(
            from: zeroBuffer,
            sourceOffset: 0,
            sourceBytesPerRow: texture.width * 4 * MemoryLayout<Float>.stride,
            sourceBytesPerImage: bufferSize,
            sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
            to: texture,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )

        blitEncoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    // MARK: - Rendering

    private func renderSamples(to texture: MTLTexture) {
        // 直接调用 GPU kernel，让它在纹理上自动累积
        // GPU kernel 会自动 read → add → write

        guard let commandBuffer = context.commandQueue.makeCommandBuffer(),
              let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
            print("[WindowRenderer] Failed to create command buffer/encoder")
            return
        }

        // 设置渲染参数
        var renderParams = GPURenderParams(
            width: UInt32(camera.imageWidth),
            height: UInt32(camera.imageHeight),
            samplesPerPixel: samplesPerFrame,  // 每帧渲染的样本数
            maxDepth: scene.camera.maxDepth,
            sphereCount: UInt32(sphereCount),  // 使用保存的数量
            quadCount: UInt32(quadCount),
            constantMediumCount: UInt32(constantMediumCount),
            useBackground: scene.camera.useBackground ? 1 : 0,
            sampleOffset: currentSample,  // 重要：传递当前累积的样本数作为偏移
            useBVH: 1,
            bvhNodeCount: UInt32(bvh.nodes.count),
            padding: 0
        )

        // 设置 pipeline 和参数
        computeEncoder.setComputePipelineState(rayTracingPipeline)
        computeEncoder.setTexture(texture, index: 0)

        // 设置图片纹理（如果有）
        if !scene.imageTextures.isEmpty {
            computeEncoder.setTexture(scene.imageTextures[0], index: 1)
        }

        var cameraParams = camera.gpuParams
        computeEncoder.setBuffer(buffers.sphereBuffer, offset: 0, index: 0)
        computeEncoder.setBuffer(buffers.materialBuffer, offset: 0, index: 1)
        computeEncoder.setBytes(&cameraParams, length: MemoryLayout<GPUCameraParams>.size, index: 2)
        computeEncoder.setBytes(&renderParams, length: MemoryLayout<GPURenderParams>.size, index: 3)
        computeEncoder.setBuffer(buffers.quadBuffer, offset: 0, index: 4)
        computeEncoder.setBuffer(buffers.textureBuffer, offset: 0, index: 5)
        computeEncoder.setBuffer(buffers.transformBuffer, offset: 0, index: 6)
        computeEncoder.setBuffer(buffers.constantMediumBuffer, offset: 0, index: 7)
        computeEncoder.setBuffer(buffers.bvhNodeBuffer, offset: 0, index: 8)
        computeEncoder.setBuffer(buffers.geometryIndexBuffer, offset: 0, index: 9)

        // 调度线程
        let threadsPerGrid = MTLSize(width: camera.imageWidth, height: camera.imageHeight, depth: 1)
        let threadsPerThreadgroup = MTLSize(width: 16, height: 16, depth: 1)
        computeEncoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)

        computeEncoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        // Debug: Check if GPU actually rendered to the texture
        if currentSample < 3 {
            let pixelCount = texture.width * texture.height
            let bufferSize = pixelCount * 4 * MemoryLayout<Float>.stride
            guard let debugBuffer = context.device.makeBuffer(length: bufferSize, options: .storageModeShared),
                  let debugCmd = context.commandQueue.makeCommandBuffer(),
                  let debugBlit = debugCmd.makeBlitCommandEncoder() else {
                print("[Debug renderSamples] Failed to create debug buffer")
                return
            }

            debugBlit.copy(
                from: texture,
                sourceSlice: 0,
                sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
                to: debugBuffer,
                destinationOffset: 0,
                destinationBytesPerRow: texture.width * 4 * MemoryLayout<Float>.stride,
                destinationBytesPerImage: bufferSize
            )
            debugBlit.endEncoding()
            debugCmd.commit()
            debugCmd.waitUntilCompleted()

            let ptr = debugBuffer.contents().assumingMemoryBound(to: Float.self)
            var foundColor = false
            for i in 0..<min(100, pixelCount) {
                let r = ptr[i * 4 + 0]
                let g = ptr[i * 4 + 1]
                let b = ptr[i * 4 + 2]
                if r > 0.0 || g > 0.0 || b > 0.0 {
                    print("[Debug renderSamples] Pixel[\(i)] RGB=(\(r), \(g), \(b)) ✓ GPU rendered!")
                    foundColor = true
                    break
                }
            }
            if !foundColor {
                print("[Debug renderSamples] ⚠️  Texture is BLACK after GPU rendering!")
                print("[Debug renderSamples] Render params: spp=\(samplesPerFrame), offset=\(currentSample), spheres=\(sphereCount), quads=\(quadCount)")
            }
        }
    }

    private func convertToDisplay(from source: MTLTexture, to destination: MTLTexture) {
        // Copy texture to CPU buffer
        let pixelCount = source.width * source.height
        let bufferSize = pixelCount * 4 * MemoryLayout<Float>.stride

        guard let rgbaBuffer = context.device.makeBuffer(length: bufferSize, options: .storageModeShared) else {
            print("[WindowRenderer] Failed to create RGBA buffer")
            return
        }

        // Copy from texture to buffer
        guard let blitCommandBuffer = context.commandQueue.makeCommandBuffer(),
              let blitEncoder = blitCommandBuffer.makeBlitCommandEncoder() else {
            return
        }

        blitEncoder.copy(
            from: source,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: source.width, height: source.height, depth: 1),
            to: rgbaBuffer,
            destinationOffset: 0,
            destinationBytesPerRow: source.width * 4 * MemoryLayout<Float>.stride,
            destinationBytesPerImage: bufferSize
        )

        blitEncoder.endEncoding()
        blitCommandBuffer.commit()
        blitCommandBuffer.waitUntilCompleted()

        // Debug: Check buffer content on first few frames
        if currentSample < 5 {
            let bufferPointer = rgbaBuffer.contents().assumingMemoryBound(to: Float.self)
            var hasNonZero = false
            for i in 0..<min(100, pixelCount * 4) {
                if bufferPointer[i] != 0.0 {
                    hasNonZero = true
                    if i < 20 {
                        print("[Debug] Buffer[\(i)] = \(bufferPointer[i])")
                    }
                    break
                }
            }
            if !hasNonZero {
                print("[Debug] WARNING: RGBA buffer is all zeros after copy!")
            }
        }

        // Run conversion kernel
        guard let commandBuffer = context.commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return
        }

        encoder.setComputePipelineState(conversionPipeline)
        encoder.setBuffer(rgbaBuffer, offset: 0, index: 0)

        var totalSamples = currentSample + samplesPerFrame
        encoder.setBytes(&totalSamples, length: MemoryLayout<UInt32>.stride, index: 1)
        encoder.setTexture(destination, index: 0)

        let threadgroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadgroups = MTLSize(
            width: (destination.width + 15) / 16,
            height: (destination.height + 15) / 16,
            depth: 1
        )

        encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadgroupSize)
        encoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    private func resetAccumulation() {
        currentSample = 0
        accumulationTexture = nil
        displayTexture = nil
        print("[WindowRenderer] Accumulation reset")
    }

    // MARK: - Buffer Creation

    struct GPUBuffers {
        let sphereBuffer: MTLBuffer
        let quadBuffer: MTLBuffer
        let constantMediumBuffer: MTLBuffer
        let materialBuffer: MTLBuffer
        let textureBuffer: MTLBuffer
        let transformBuffer: MTLBuffer
        let bvhNodeBuffer: MTLBuffer
        let geometryIndexBuffer: MTLBuffer
    }

    private static func createBuffers(
        context: MetalContext,
        spheres: [GPUSphere],
        quads: [GPUQuad],
        constantMediums: [GPUConstantMedium],
        materials: [GPUMaterial],
        textures: [GPUTexture],
        transforms: [GPUTransform],
        bvh: FlatBVH
    ) -> GPUBuffers? {
        let sphereSize = max(1, spheres.count) * MemoryLayout<GPUSphere>.stride
        let quadSize = max(1, quads.count) * MemoryLayout<GPUQuad>.stride
        let mediumSize = max(1, constantMediums.count) * MemoryLayout<GPUConstantMedium>.stride
        let materialSize = materials.count * MemoryLayout<GPUMaterial>.stride
        let textureSize = max(1, textures.count) * MemoryLayout<GPUTexture>.stride
        let transformSize = max(1, transforms.count) * MemoryLayout<GPUTransform>.stride
        let bvhNodeSize = bvh.nodes.count * MemoryLayout<BVHNode>.stride
        let geometryIndexSize = bvh.geometryIndices.count * MemoryLayout<UInt32>.stride

        let dummySphere = GPUSphere(center: SIMD3<Float>(0,0,0), radius: 0, materialIndex: 0, transformIndex: -1, padding: SIMD2<Float>(0,0))
        let dummyQuad = GPUQuad(corner: SIMD3<Float>(0,0,0), padding1: 0, sideA: SIMD3<Float>(0,0,0), padding2: 0, sideB: SIMD3<Float>(0,0,0), padding3: 0, normal: SIMD3<Float>(0,0,0), D: 0, w: SIMD3<Float>(0,0,0), materialIndex: 0, transformIndex: -1, padding4: SIMD2<Float>(0,0))
        let dummyMedium = GPUConstantMedium(boundaryType: 0, boundaryIndex: 0, negInvDensity: 0, materialIndex: 0, padding: SIMD3<Float>(0,0,0))
        let dummyTexture = GPUTexture(type: 0, padding1: SIMD3<UInt32>(0,0,0), albedo: SIMD3<Float>(0,0,0), invScale: 0, scale: 0, oddColor: SIMD3<Float>(0,0,0), imageIndex: -1, padding2: SIMD3<Float>(0,0,0))
        let dummyTransform = GPUTransform(translation: SIMD3<Float>(0,0,0), hasRotation: 0, rotationRow0: SIMD3<Float>(0,0,0), padding0: 0, rotationRow1: SIMD3<Float>(0,0,0), padding1: 0, rotationRow2: SIMD3<Float>(0,0,0), padding2: 0)

        guard let sphereBuffer = context.device.makeBuffer(bytes: spheres.isEmpty ? [dummySphere] : spheres, length: sphereSize, options: .storageModeShared),
              let quadBuffer = context.device.makeBuffer(bytes: quads.isEmpty ? [dummyQuad] : quads, length: quadSize, options: .storageModeShared),
              let mediumBuffer = context.device.makeBuffer(bytes: constantMediums.isEmpty ? [dummyMedium] : constantMediums, length: mediumSize, options: .storageModeShared),
              let materialBuffer = context.device.makeBuffer(bytes: materials, length: materialSize, options: .storageModeShared),
              let textureBuffer = context.device.makeBuffer(bytes: textures.isEmpty ? [dummyTexture] : textures, length: textureSize, options: .storageModeShared),
              let transformBuffer = context.device.makeBuffer(bytes: transforms.isEmpty ? [dummyTransform] : transforms, length: transformSize, options: .storageModeShared),
              let bvhNodeBuffer = context.device.makeBuffer(bytes: bvh.nodes, length: bvhNodeSize, options: .storageModeShared),
              let geometryIndexBuffer = context.device.makeBuffer(bytes: bvh.geometryIndices, length: geometryIndexSize, options: .storageModeShared) else {
            return nil
        }

        return GPUBuffers(
            sphereBuffer: sphereBuffer,
            quadBuffer: quadBuffer,
            constantMediumBuffer: mediumBuffer,
            materialBuffer: materialBuffer,
            textureBuffer: textureBuffer,
            transformBuffer: transformBuffer,
            bvhNodeBuffer: bvhNodeBuffer,
            geometryIndexBuffer: geometryIndexBuffer
        )
    }
}

class RenderWindow: NSWindow {
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {  // ESC
            close()
        }
    }
}
