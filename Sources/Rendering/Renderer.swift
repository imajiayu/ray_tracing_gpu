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
        print("[Renderer] ✓ Perlin data generated (seed: 42)")
    }

    /// 渲染场景到纹理
    /// - Parameters:
    ///   - scene: 场景
    ///   - camera: 相机
    ///   - bvh: BVH 加速结构
    ///   - batchSize: 每批次的采样数
    /// - Returns: 渲染后的像素数据
    func render(
        scene: Scene,
        camera: Camera,
        bvh: FlatBVH,
        batchSize: Int
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
            bvh: bvh
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

        // 启用 BVH（场景几何体数量 >= 10 时启用）
        // 强制启用 BVH 测试
        let useBVH: UInt32 = 1  // (gpuSpheres.count + gpuQuads.count >= 10) ? 1 : 0

        var renderParams = GPURenderParams(
            width: UInt32(camera.imageWidth),
            height: UInt32(camera.imageHeight),
            samplesPerPixel: samplesPerPixel,
            maxDepth: maxDepth,
            sphereCount: UInt32(gpuSpheres.count),
            quadCount: UInt32(gpuQuads.count),
            useBackground: useBackground,
            sampleOffset: 0,
            useBVH: useBVH,
            bvhNodeCount: UInt32(bvh.nodes.count),
            padding: 0
        )

        print("[Render] Resolution: \(camera.imageWidth)×\(camera.imageHeight)")
        print("[Render] Samples: \(samplesPerPixel) spp")
        print("[Render] Max depth: \(maxDepth)")
        print("[Render] BVH: \(useBVH == 1 ? "Enabled" : "Disabled")")

        // 执行渐进式渲染
        print("[Render] Starting progressive GPU rendering...")

        let startTime = Date()

        let samplesPerBatch: UInt32 = UInt32(batchSize)
        let batchCount = (samplesPerPixel + samplesPerBatch - 1) / samplesPerBatch

        print("[Render] Total batches: \(batchCount) × \(samplesPerBatch) spp")

        var cameraParams = camera.gpuParams

        for batch in 0..<batchCount {
            let currentBatchSamples = min(samplesPerBatch, samplesPerPixel - batch * samplesPerBatch)

            var batchParams = renderParams
            batchParams.samplesPerPixel = currentBatchSamples
            batchParams.sampleOffset = batch * samplesPerBatch

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

            // 设置线程组大小
            let threadsPerGrid = MTLSize(width: camera.imageWidth, height: camera.imageHeight, depth: 1)
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

        // 读取结果
        print("[Output] Reading texture data...")

        let bytesPerPixel = 4 * MemoryLayout<Float>.size
        let bytesPerRow = camera.imageWidth * bytesPerPixel
        var pixelData = [Float](repeating: 0, count: camera.imageWidth * camera.imageHeight * 4)

        let region = MTLRegionMake2D(0, 0, camera.imageWidth, camera.imageHeight)
        outputTexture.getBytes(&pixelData, bytesPerRow: bytesPerRow, from: region, mipmapLevel: 0)

        return (pixelData, renderTime)
    }

    // MARK: - 私有方法

    private struct GPUBuffers {
        let sphereBuffer: MTLBuffer
        let materialBuffer: MTLBuffer
        let quadBuffer: MTLBuffer
        let textureBuffer: MTLBuffer
        let transformBuffer: MTLBuffer
        let bvhNodeBuffer: MTLBuffer
        let geometryIndexBuffer: MTLBuffer
        // Perlin 噪声数据 buffers
        let perlinRandvecBuffer: MTLBuffer
        let perlinPermXBuffer: MTLBuffer
        let perlinPermYBuffer: MTLBuffer
        let perlinPermZBuffer: MTLBuffer
    }

    private func createBuffers(
        spheres: [GPUSphere],
        quads: [GPUQuad],
        materials: [GPUMaterial],
        textures: [GPUTexture],
        transforms: [GPUTransform],
        bvh: FlatBVH
    ) -> GPUBuffers? {
        guard let sphereBuffer = context.makeBuffer(array: spheres),
              let materialBuffer = context.makeBuffer(array: materials) else {
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
            perlinRandvecBuffer: perlinRandvecBuffer,
            perlinPermXBuffer: perlinPermXBuffer,
            perlinPermYBuffer: perlinPermYBuffer,
            perlinPermZBuffer: perlinPermZBuffer
        )
    }
}
