// Renderer.swift
// GPU 渲染器，负责执行渲染任务

import Foundation
import Metal
import MetalKit

/// GPU 渲染器
class Renderer {
    let context: MetalContext
    let pipeline: MTLComputePipelineState
    let perlinData: PerlinData  // Perlin 噪声数据（固定种子42，与CPU版本一致）

    init(context: MetalContext, pipeline: MTLComputePipelineState) {
        self.context = context
        self.pipeline = pipeline

        // 生成 Perlin 数据（使用固定种子42，与CPU版本完全一致）
        self.perlinData = PerlinData(seed: 42)
    }

    /// 渲染场景到纹理（用于实时模式）
    /// - Parameters:
    ///   - scene: 场景
    ///   - camera: 相机
    ///   - bvh: BVH 加速结构
    ///   - buffers: 预创建的 GPU 缓冲区
    ///   - batchSize: 每批次的采样数（实时模式建议使用 1）
    /// - Returns: 渲染后的 Metal 纹理（RGBA32Float 格式）
    func renderToTexture(
        scene: Scene,
        camera: Camera,
        bvh: FlatBVH,
        buffers: GPUBuffers,
        sphereCount: Int,
        quadCount: Int,
        batchSize: Int = 1,
        sampleOffset: UInt32 = 0,
        filterType: FilterType = .box,
        useBlueNoise: Bool = false,
        pixelMask: MTLBuffer? = nil  // 可选：像素掩码（1=渲染，0=跳过）
    ) -> MTLTexture? {
        // 创建输出纹理
        guard let outputTexture = context.makeTexture(width: camera.imageWidth, height: camera.imageHeight) else {
            return nil
        }

        // 渲染参数（使用传入的计数，而不是重新调用 scene.toGPU()）
        let samplesPerPixel = UInt32(batchSize)
        let maxDepth = scene.camera.maxDepth
        let useBackground: UInt32 = scene.camera.useBackground ? 1 : 0

        // 计算分层采样参数
        let sqrtSpp = UInt32(sqrt(Double(samplesPerPixel)))
        let recipSqrtSpp = Float(1.0) / Float(sqrtSpp)
        let actualSamplesPerPixel = sqrtSpp * sqrtSpp  // 实际采样数（完全平方数）

        var renderParams = GPURenderParams(
            width: UInt32(camera.imageWidth),
            height: UInt32(camera.imageHeight),
            samplesPerPixel: actualSamplesPerPixel,
            maxDepth: maxDepth,
            sphereCount: UInt32(sphereCount),
            quadCount: UInt32(quadCount),
            useBackground: useBackground,
            sampleOffset: sampleOffset,
            useBVH: 1,
            bvhNodeCount: UInt32(bvh.nodes.count),
            lightsCount: UInt32(scene.lights.count),
            useMIS: 1,
            sqrtSpp: sqrtSpp,
            filterType: filterType.gpuValue,
            useBlueNoise: useBlueNoise ? 1 : 0,
            recipSqrtSpp: recipSqrtSpp,
            padding2: SIMD2<Float>(0, 0)
        )

        var cameraParams = camera.gpuParams

        // 执行渲染（单批次，不输出日志）
        guard let commandBuffer = context.commandQueue.makeCommandBuffer(),
              let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
            return nil
        }

        computeEncoder.setComputePipelineState(pipeline)
        computeEncoder.setTexture(outputTexture, index: 0)

        // 设置图片纹理（如果有）
        if !scene.imageTextures.isEmpty {
            computeEncoder.setTexture(scene.imageTextures[0], index: 1)
        }

        computeEncoder.setBuffer(buffers.sphereBuffer, offset: 0, index: 0)
        computeEncoder.setBuffer(buffers.materialBuffer, offset: 0, index: 1)
        computeEncoder.setBytes(&cameraParams, length: MemoryLayout<GPUCameraParams>.size, index: 2)
        computeEncoder.setBytes(&renderParams, length: MemoryLayout<GPURenderParams>.size, index: 3)
        computeEncoder.setBuffer(buffers.quadBuffer, offset: 0, index: 4)
        computeEncoder.setBuffer(buffers.textureBuffer, offset: 0, index: 5)
        computeEncoder.setBuffer(buffers.transformBuffer, offset: 0, index: 6)
        computeEncoder.setBuffer(buffers.bvhNodeBuffer, offset: 0, index: 7)
        computeEncoder.setBuffer(buffers.geometryIndexBuffer, offset: 0, index: 8)
        computeEncoder.setBuffer(buffers.perlinRandvecBuffer, offset: 0, index: 9)
        computeEncoder.setBuffer(buffers.perlinPermXBuffer, offset: 0, index: 10)
        computeEncoder.setBuffer(buffers.perlinPermYBuffer, offset: 0, index: 11)
        computeEncoder.setBuffer(buffers.perlinPermZBuffer, offset: 0, index: 12)
        computeEncoder.setBuffer(buffers.lightIndexBuffer, offset: 0, index: 13)
        if let mask = pixelMask {
            computeEncoder.setBuffer(mask, offset: 0, index: 14)
        } else {
            computeEncoder.setBuffer(nil, offset: 0, index: 14)
        }

        // 设置线程组大小
        let threadsPerGrid = MTLSize(width: camera.imageWidth, height: camera.imageHeight, depth: 1)
        let threadsPerThreadgroup = MTLSize(width: 16, height: 16, depth: 1)
        computeEncoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)

        computeEncoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        return outputTexture
    }

    /// 渲染场景到 5 个 AOV 通道纹理（用于 AOV 自适应采样）
    /// 返回顺序与 accumulate_samples_aov 的纹理槽位一致：beauty/diffuse/specular/transmission/emission
    /// - Parameter aovPipeline: raytrace_aov 计算管线（由 AdaptiveRenderer 持有并传入）
    func renderToTexturesAOV(
        scene: Scene,
        camera: Camera,
        bvh: FlatBVH,
        buffers: GPUBuffers,
        sphereCount: Int,
        quadCount: Int,
        aovPipeline: MTLComputePipelineState,
        batchSize: Int = 1,
        sampleOffset: UInt32 = 0,
        filterType: FilterType = .box,
        useBlueNoise: Bool = false,
        pixelMask: MTLBuffer? = nil
    ) -> (beauty: MTLTexture, diffuse: MTLTexture, specular: MTLTexture, transmission: MTLTexture, emission: MTLTexture)? {
        // 创建 5 个 AOV 输出纹理（RGBA32Float，初始为 0）
        guard let beauty = context.makeTexture(width: camera.imageWidth, height: camera.imageHeight),
              let diffuse = context.makeTexture(width: camera.imageWidth, height: camera.imageHeight),
              let specular = context.makeTexture(width: camera.imageWidth, height: camera.imageHeight),
              let transmission = context.makeTexture(width: camera.imageWidth, height: camera.imageHeight),
              let emission = context.makeTexture(width: camera.imageWidth, height: camera.imageHeight) else {
            return nil
        }

        let samplesPerPixel = UInt32(batchSize)
        let maxDepth = scene.camera.maxDepth
        let useBackground: UInt32 = scene.camera.useBackground ? 1 : 0

        let sqrtSpp = UInt32(sqrt(Double(samplesPerPixel)))
        let recipSqrtSpp = Float(1.0) / Float(sqrtSpp)
        let actualSamplesPerPixel = sqrtSpp * sqrtSpp

        var renderParams = GPURenderParams(
            width: UInt32(camera.imageWidth),
            height: UInt32(camera.imageHeight),
            samplesPerPixel: actualSamplesPerPixel,
            maxDepth: maxDepth,
            sphereCount: UInt32(sphereCount),
            quadCount: UInt32(quadCount),
            useBackground: useBackground,
            sampleOffset: sampleOffset,
            useBVH: 1,
            bvhNodeCount: UInt32(bvh.nodes.count),
            lightsCount: UInt32(scene.lights.count),
            useMIS: 1,
            sqrtSpp: sqrtSpp,
            filterType: filterType.gpuValue,
            useBlueNoise: useBlueNoise ? 1 : 0,
            recipSqrtSpp: recipSqrtSpp,
            padding2: SIMD2<Float>(0, 0)
        )

        var cameraParams = camera.gpuParams

        guard let commandBuffer = context.commandQueue.makeCommandBuffer(),
              let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
            return nil
        }

        computeEncoder.setComputePipelineState(aovPipeline)
        // 5 个 AOV 输出纹理（texture 0-4）+ 图片纹理（texture 5）
        computeEncoder.setTexture(beauty, index: 0)
        computeEncoder.setTexture(diffuse, index: 1)
        computeEncoder.setTexture(specular, index: 2)
        computeEncoder.setTexture(transmission, index: 3)
        computeEncoder.setTexture(emission, index: 4)
        if !scene.imageTextures.isEmpty {
            computeEncoder.setTexture(scene.imageTextures[0], index: 5)
        }

        computeEncoder.setBuffer(buffers.sphereBuffer, offset: 0, index: 0)
        computeEncoder.setBuffer(buffers.materialBuffer, offset: 0, index: 1)
        computeEncoder.setBytes(&cameraParams, length: MemoryLayout<GPUCameraParams>.size, index: 2)
        computeEncoder.setBytes(&renderParams, length: MemoryLayout<GPURenderParams>.size, index: 3)
        computeEncoder.setBuffer(buffers.quadBuffer, offset: 0, index: 4)
        computeEncoder.setBuffer(buffers.textureBuffer, offset: 0, index: 5)
        computeEncoder.setBuffer(buffers.transformBuffer, offset: 0, index: 6)
        computeEncoder.setBuffer(buffers.bvhNodeBuffer, offset: 0, index: 7)
        computeEncoder.setBuffer(buffers.geometryIndexBuffer, offset: 0, index: 8)
        computeEncoder.setBuffer(buffers.perlinRandvecBuffer, offset: 0, index: 9)
        computeEncoder.setBuffer(buffers.perlinPermXBuffer, offset: 0, index: 10)
        computeEncoder.setBuffer(buffers.perlinPermYBuffer, offset: 0, index: 11)
        computeEncoder.setBuffer(buffers.perlinPermZBuffer, offset: 0, index: 12)
        computeEncoder.setBuffer(buffers.lightIndexBuffer, offset: 0, index: 13)
        if let mask = pixelMask {
            computeEncoder.setBuffer(mask, offset: 0, index: 14)
        } else {
            computeEncoder.setBuffer(nil, offset: 0, index: 14)
        }

        let threadsPerGrid = MTLSize(width: camera.imageWidth, height: camera.imageHeight, depth: 1)
        let threadsPerThreadgroup = MTLSize(width: 16, height: 16, depth: 1)
        computeEncoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)

        computeEncoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        return (beauty, diffuse, specular, transmission, emission)
    }

    /// 渲染场景到像素数据（用于离线模式）
    /// - Parameters:
    ///   - scene: 场景
    ///   - camera: 相机
    ///   - bvh: BVH 加速结构
    ///   - batchSize: 每批次的采样数
    ///   - filterType: 像素重建滤波器类型
    ///   - progressCallback: 进度回调（batch index）
    /// - Returns: 渲染后的像素数据
    func render(
        scene: Scene,
        camera: Camera,
        bvh: FlatBVH,
        batchSize: Int,
        filterType: FilterType = .box,
        useBlueNoise: Bool = false,
        progressCallback: ((Int) -> Void)? = nil
    ) -> (pixels: [Float], renderTime: TimeInterval) {
        // 转换为 GPU 数据
        let (gpuSpheres, gpuQuads, gpuMaterials, gpuTextures, gpuTransforms) = scene.toGPU()

        // 创建 GPU 缓冲区
        guard let buffers = createBuffers(
            spheres: gpuSpheres,
            quads: gpuQuads,
            materials: gpuMaterials,
            textures: gpuTextures,
            transforms: gpuTransforms,
            bvh: bvh,
            lights: scene.lights
        ) else {
            fatalError("Failed to create GPU buffers")
        }

        // 创建输出纹理
        guard let outputTexture = context.makeTexture(width: camera.imageWidth, height: camera.imageHeight) else {
            fatalError("Failed to create output texture")
        }

        // 渲染参数
        let samplesPerPixel = scene.camera.samplesPerPixel
        let maxDepth = scene.camera.maxDepth
        let useBackground: UInt32 = scene.camera.useBackground ? 1 : 0

        // 计算分层采样参数（注意：这是总采样数，会在批次循环中重新计算）
        let sqrtSppTotal = UInt32(sqrt(Double(samplesPerPixel)))
        let recipSqrtSppTotal = Float(1.0) / Float(sqrtSppTotal)
        let actualSamplesPerPixel = sqrtSppTotal * sqrtSppTotal  // 实际采样数（完全平方数）

        let renderParams = GPURenderParams(
            width: UInt32(camera.imageWidth),
            height: UInt32(camera.imageHeight),
            samplesPerPixel: actualSamplesPerPixel,
            maxDepth: maxDepth,
            sphereCount: UInt32(gpuSpheres.count),
            quadCount: UInt32(gpuQuads.count),
            useBackground: useBackground,
            sampleOffset: 0,
            useBVH: 1,  // Always enabled
            bvhNodeCount: UInt32(bvh.nodes.count),
            lightsCount: UInt32(scene.lights.count),
            useMIS: 1,  // Always enabled
            sqrtSpp: sqrtSppTotal,
            filterType: filterType.gpuValue,
            useBlueNoise: useBlueNoise ? 1 : 0,
            recipSqrtSpp: recipSqrtSppTotal,
            padding2: SIMD2<Float>(0, 0)
        )

        // 执行渐进式渲染（移除所有 debug 打印）
        let startTime = Date()

        let samplesPerBatch: UInt32 = UInt32(batchSize)
        let batchCount = (samplesPerPixel + samplesPerBatch - 1) / samplesPerBatch

        var cameraParams = camera.gpuParams

        for batch in 0..<batchCount {
            let currentBatchSamples = min(samplesPerBatch, samplesPerPixel - batch * samplesPerBatch)

            var batchParams = renderParams

            // 重新计算当前批次的分层采样参数
            let batchSqrtSpp = UInt32(sqrt(Double(currentBatchSamples)))
            let actualBatchSamples = batchSqrtSpp * batchSqrtSpp  // 实际采样数

            batchParams.samplesPerPixel = actualBatchSamples
            batchParams.sampleOffset = batch * samplesPerBatch
            batchParams.sqrtSpp = batchSqrtSpp
            batchParams.recipSqrtSpp = Float(1.0) / Float(batchSqrtSpp)

            guard let commandBuffer = context.commandQueue.makeCommandBuffer() else {
                fatalError("Failed to create command buffer")
            }

            guard let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
                fatalError("Failed to create compute encoder")
            }

            computeEncoder.setComputePipelineState(pipeline)
            computeEncoder.setTexture(outputTexture, index: 0)

            // 设置图片纹理（如果有）
            if !scene.imageTextures.isEmpty {
                computeEncoder.setTexture(scene.imageTextures[0], index: 1)
            }

            computeEncoder.setBuffer(buffers.sphereBuffer, offset: 0, index: 0)
            computeEncoder.setBuffer(buffers.materialBuffer, offset: 0, index: 1)
            computeEncoder.setBytes(&cameraParams, length: MemoryLayout<GPUCameraParams>.size, index: 2)
            computeEncoder.setBytes(&batchParams, length: MemoryLayout<GPURenderParams>.size, index: 3)
            computeEncoder.setBuffer(buffers.quadBuffer, offset: 0, index: 4)
            computeEncoder.setBuffer(buffers.textureBuffer, offset: 0, index: 5)
            computeEncoder.setBuffer(buffers.transformBuffer, offset: 0, index: 6)
            computeEncoder.setBuffer(buffers.bvhNodeBuffer, offset: 0, index: 7)
            computeEncoder.setBuffer(buffers.geometryIndexBuffer, offset: 0, index: 8)
            // Perlin 噪声数据（与 CPU 版本完全一致，种子42）
            computeEncoder.setBuffer(buffers.perlinRandvecBuffer, offset: 0, index: 9)
            computeEncoder.setBuffer(buffers.perlinPermXBuffer, offset: 0, index: 10)
            computeEncoder.setBuffer(buffers.perlinPermYBuffer, offset: 0, index: 11)
            computeEncoder.setBuffer(buffers.perlinPermZBuffer, offset: 0, index: 12)
            // 光源索引缓冲区（用于 MIS）
            computeEncoder.setBuffer(buffers.lightIndexBuffer, offset: 0, index: 13)

            // 设置线程组大小
            let threadsPerGrid = MTLSize(width: camera.imageWidth, height: camera.imageHeight, depth: 1)
            let threadsPerThreadgroup = MTLSize(width: 16, height: 16, depth: 1)
            computeEncoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)

            computeEncoder.endEncoding()
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()

            // 调用进度回调
            progressCallback?(Int(batch))
        }

        let renderTime = Date().timeIntervalSince(startTime)

        // 读取结果（不输出日志）

        let bytesPerPixel = 4 * MemoryLayout<Float>.size
        let bytesPerRow = camera.imageWidth * bytesPerPixel
        var pixelData = [Float](repeating: 0, count: camera.imageWidth * camera.imageHeight * 4)

        let region = MTLRegionMake2D(0, 0, camera.imageWidth, camera.imageHeight)
        outputTexture.getBytes(&pixelData, bytesPerRow: bytesPerRow, from: region, mipmapLevel: 0)

        return (pixelData, renderTime)
    }

    // MARK: - 私有方法

    struct GPUBuffers {
        let sphereBuffer: MTLBuffer
        let materialBuffer: MTLBuffer
        let quadBuffer: MTLBuffer
        let textureBuffer: MTLBuffer
        let transformBuffer: MTLBuffer
        let bvhNodeBuffer: MTLBuffer
        let geometryIndexBuffer: MTLBuffer
        let lightIndexBuffer: MTLBuffer  // 光源索引缓冲区（用于 MIS）
        // Perlin 噪声数据 buffers
        let perlinRandvecBuffer: MTLBuffer
        let perlinPermXBuffer: MTLBuffer
        let perlinPermYBuffer: MTLBuffer
        let perlinPermZBuffer: MTLBuffer
    }

    func createBuffers(
        spheres: [GPUSphere],
        quads: [GPUQuad],
        materials: [GPUMaterial],
        textures: [GPUTexture],
        transforms: [GPUTransform],
        bvh: FlatBVH,
        lights: [GPULightInfo]
    ) -> GPUBuffers? {
        // 创建 Sphere 缓冲区（如果有）
        let sphereBuffer: MTLBuffer
        if spheres.isEmpty {
            guard let buffer = context.device.makeBuffer(length: MemoryLayout<GPUSphere>.stride, options: []) else {
                return nil
            }
            sphereBuffer = buffer
        } else {
            guard let buffer = context.makeBuffer(array: spheres) else {
                return nil
            }
            sphereBuffer = buffer
        }

        // 创建材质缓冲区
        guard let materialBuffer = context.makeBuffer(array: materials) else {
            return nil
        }

        // 创建 Quad 缓冲区（如果有）
        let quadBuffer: MTLBuffer
        if quads.isEmpty {
            guard let buffer = context.device.makeBuffer(length: MemoryLayout<GPUQuad>.stride, options: []) else {
                return nil
            }
            quadBuffer = buffer
        } else {
            guard let buffer = context.makeBuffer(array: quads) else {
                return nil
            }
            quadBuffer = buffer
        }

        // 创建纹理缓冲区（如果有）
        let textureBuffer: MTLBuffer
        if textures.isEmpty {
            guard let buffer = context.device.makeBuffer(length: MemoryLayout<GPUTexture>.stride, options: []) else {
                return nil
            }
            textureBuffer = buffer
        } else {
            guard let buffer = context.makeBuffer(array: textures) else {
                return nil
            }
            textureBuffer = buffer
        }

        // 创建变换缓冲区（如果有）
        let transformBuffer: MTLBuffer
        if transforms.isEmpty {
            guard let buffer = context.device.makeBuffer(length: MemoryLayout<GPUTransform>.stride, options: []) else {
                return nil
            }
            transformBuffer = buffer
        } else {
            guard let buffer = context.makeBuffer(array: transforms) else {
                return nil
            }
            transformBuffer = buffer
        }

        // 创建 BVH 缓冲区
        let bvhNodeBuffer: MTLBuffer
        if bvh.nodes.isEmpty {
            guard let buffer = context.device.makeBuffer(length: MemoryLayout<GPUBVHNode>.stride, options: []) else {
                return nil
            }
            bvhNodeBuffer = buffer
        } else {
            guard let buffer = context.makeBuffer(array: bvh.nodes) else {
                return nil
            }
            bvhNodeBuffer = buffer
        }

        // 创建几何体索引缓冲区
        let geometryIndexBuffer: MTLBuffer
        if bvh.geometryIndices.isEmpty {
            guard let buffer = context.device.makeBuffer(length: MemoryLayout<UInt32>.stride, options: []) else {
                return nil
            }
            geometryIndexBuffer = buffer
        } else {
            guard let buffer = context.makeBuffer(array: bvh.geometryIndices) else {
                return nil
            }
            geometryIndexBuffer = buffer
        }

        // 创建光源索引缓冲区（用于 MIS）
        // 将 GPULightInfo 中的 geometryIndex 提取为 UInt32 数组
        let lightIndices = lights.map { $0.geometryIndex }
        let lightIndexBuffer: MTLBuffer
        if lightIndices.isEmpty {
            guard let buffer = context.device.makeBuffer(length: MemoryLayout<UInt32>.stride, options: []) else {
                return nil
            }
            lightIndexBuffer = buffer
        } else {
            guard let buffer = context.makeBuffer(array: lightIndices) else {
                return nil
            }
            lightIndexBuffer = buffer
        }

        // 创建 Perlin 噪声数据缓冲区
        guard let perlinRandvecBuffer = context.makeBuffer(array: perlinData.randvec),
              let perlinPermXBuffer = context.makeBuffer(array: perlinData.permX),
              let perlinPermYBuffer = context.makeBuffer(array: perlinData.permY),
              let perlinPermZBuffer = context.makeBuffer(array: perlinData.permZ) else {
            return nil
        }

        return GPUBuffers(
            sphereBuffer: sphereBuffer,
            materialBuffer: materialBuffer,
            quadBuffer: quadBuffer,
            textureBuffer: textureBuffer,
            transformBuffer: transformBuffer,
            bvhNodeBuffer: bvhNodeBuffer,
            geometryIndexBuffer: geometryIndexBuffer,
            lightIndexBuffer: lightIndexBuffer,
            perlinRandvecBuffer: perlinRandvecBuffer,
            perlinPermXBuffer: perlinPermXBuffer,
            perlinPermYBuffer: perlinPermYBuffer,
            perlinPermZBuffer: perlinPermZBuffer
        )
    }
}
