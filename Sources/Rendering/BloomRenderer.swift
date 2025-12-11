// BloomRenderer.swift
// Bloom 后处理渲染器
//
// Phase 7 - Post-Processing
//
// 流程：
// 1. Bright Pass - 提取高亮像素
// 2. Downsample - 多级降采样（3-4级）
// 3. Upsample - 上采样并混合
// 4. Final Blend - 与原图混合

import Metal
import MetalKit

class BloomRenderer {
    // MARK: - Pipelines
    let brightPassPipeline: MTLComputePipelineState
    let downsamplePipeline: MTLComputePipelineState
    let upsamplePipeline: MTLComputePipelineState
    let blendBloomPipeline: MTLComputePipelineState

    // MARK: - Textures (Mipmap Chain)
    var brightTexture: MTLTexture!  // 亮度提取后的纹理（原始分辨率）
    var downsampledTextures: [MTLTexture] = []  // 降采样链 [1/2, 1/4, 1/8]
    var upsampledTextures: [MTLTexture] = []    // 上采样链（复用）

    // MARK: - Device
    let device: MTLDevice
    let commandQueue: MTLCommandQueue

    // MARK: - Configuration
    var bloomThreshold: Float
    var bloomStrength: Float
    let mipLevels: Int = 4  // 降采样级数（4 = 1/2, 1/4, 1/8, 1/16）

    init?(device: MTLDevice, library: MTLLibrary, bloomThreshold: Float = 1.0, bloomStrength: Float = 0.2) {
        self.device = device
        self.bloomThreshold = bloomThreshold
        self.bloomStrength = bloomStrength

        guard let commandQueue = device.makeCommandQueue() else {
            print("[BloomRenderer] ❌ Failed to create command queue")
            return nil
        }
        self.commandQueue = commandQueue

        // 创建 Pipelines
        guard let brightPass = library.makeFunction(name: "bright_pass"),
              let downsample = library.makeFunction(name: "downsample"),
              let upsample = library.makeFunction(name: "upsample"),
              let blendBloom = library.makeFunction(name: "blend_bloom") else {
            print("[BloomRenderer] ❌ Failed to find Bloom shader functions")
            return nil
        }

        do {
            self.brightPassPipeline = try device.makeComputePipelineState(function: brightPass)
            self.downsamplePipeline = try device.makeComputePipelineState(function: downsample)
            self.upsamplePipeline = try device.makeComputePipelineState(function: upsample)
            self.blendBloomPipeline = try device.makeComputePipelineState(function: blendBloom)
            print("[BloomRenderer] ✓ Pipelines created")
        } catch {
            print("[BloomRenderer] ❌ Failed to create pipelines: \(error)")
            return nil
        }
    }

    /// 初始化 Bloom 纹理链（根据渲染分辨率）
    func setupTextures(width: Int, height: Int) {
        // 清理旧纹理
        downsampledTextures.removeAll()
        upsampledTextures.removeAll()

        // 创建 Bright Pass 纹理（原始分辨率）
        brightTexture = createTexture(width: width, height: height)

        // 创建降采样链 [1/2, 1/4, 1/8, 1/16]
        var currentWidth = width
        var currentHeight = height
        for _ in 0..<mipLevels {
            currentWidth = max(currentWidth / 2, 1)
            currentHeight = max(currentHeight / 2, 1)
            let texture = createTexture(width: currentWidth, height: currentHeight)
            downsampledTextures.append(texture)
        }

        // 上采样纹理（从小到大：1/4, 1/2, 1/1）
        // upsample[0] = 1/4 分辨率 (downsample[1] 的大小)
        // upsample[1] = 1/2 分辨率 (downsample[0] 的大小)
        // upsample[2] = 原始分辨率 (brightTexture 的大小)
        for i in 0..<mipLevels {
            let textureWidth: Int
            let textureHeight: Int

            if i < mipLevels - 1 {
                // 前面的上采样纹理对应降采样纹理的大小
                textureWidth = downsampledTextures[mipLevels - 2 - i].width
                textureHeight = downsampledTextures[mipLevels - 2 - i].height
            } else {
                // 最后一个上采样纹理是原始分辨率
                textureWidth = width
                textureHeight = height
            }

            let texture = createTexture(width: textureWidth, height: textureHeight)
            upsampledTextures.append(texture)
        }

        print("[BloomRenderer] ✓ Textures created: \(width)×\(height), \(mipLevels) mip levels")
        print("  Bright: \(brightTexture.width)×\(brightTexture.height)")
        for (i, tex) in downsampledTextures.enumerated() {
            print("  Down[\(i)]: \(tex.width)×\(tex.height)")
        }
        for (i, tex) in upsampledTextures.enumerated() {
            print("  Up[\(i)]: \(tex.width)×\(tex.height)")
        }
    }

    /// 创建纹理辅助函数
    private func createTexture(width: Int, height: Int) -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private  // GPU-only (更快)

        return device.makeTexture(descriptor: descriptor)!
    }

    /// 应用 Bloom 效果
    /// - Parameters:
    ///   - inputTexture: 输入纹理（原始渲染结果，HDR）
    ///   - outputTexture: 输出纹理（带 Bloom 的结果）
    ///   - commandBuffer: 命令缓冲区
    func applyBloom(inputTexture: MTLTexture, outputTexture: MTLTexture, commandBuffer: MTLCommandBuffer) {
        // 检查纹理是否初始化
        if brightTexture == nil || brightTexture.width != inputTexture.width {
            setupTextures(width: inputTexture.width, height: inputTexture.height)
        }

        // Step 1: Bright Pass（提取高亮）
        brightPass(inputTexture: inputTexture, commandBuffer: commandBuffer)

        // Step 2: Downsample Chain（多级降采样）
        downsampleChain(commandBuffer: commandBuffer)

        // Step 3: Upsample Chain（上采样 + 混合）
        upsampleChain(commandBuffer: commandBuffer)

        // Step 4: Final Blend（与原图混合）
        // 使用最后一个上采样纹理（原始分辨率）
        finalBlend(originalTexture: inputTexture, bloomTexture: upsampledTextures[mipLevels - 1], outputTexture: outputTexture, commandBuffer: commandBuffer)
    }

    // MARK: - Bloom Passes

    private func brightPass(inputTexture: MTLTexture, commandBuffer: MTLCommandBuffer) {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.setComputePipelineState(brightPassPipeline)
        encoder.setTexture(inputTexture, index: 0)
        encoder.setTexture(brightTexture, index: 1)
        encoder.setBytes(&bloomThreshold, length: MemoryLayout<Float>.size, index: 0)

        let threadgroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadgroups = MTLSize(
            width: (brightTexture.width + 15) / 16,
            height: (brightTexture.height + 15) / 16,
            depth: 1
        )
        encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadgroupSize)
        encoder.endEncoding()
    }

    private func downsampleChain(commandBuffer: MTLCommandBuffer) {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.setComputePipelineState(downsamplePipeline)

        // 第一级：bright texture → downsample[0]
        encoder.setTexture(brightTexture, index: 0)
        encoder.setTexture(downsampledTextures[0], index: 1)
        dispatchDownsample(encoder: encoder, outputTexture: downsampledTextures[0])

        // 后续级别：downsample[i-1] → downsample[i]
        for i in 1..<mipLevels {
            encoder.setTexture(downsampledTextures[i - 1], index: 0)
            encoder.setTexture(downsampledTextures[i], index: 1)
            dispatchDownsample(encoder: encoder, outputTexture: downsampledTextures[i])
        }

        encoder.endEncoding()
    }

    private func dispatchDownsample(encoder: MTLComputeCommandEncoder, outputTexture: MTLTexture) {
        let threadgroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadgroups = MTLSize(
            width: (outputTexture.width + 15) / 16,
            height: (outputTexture.height + 15) / 16,
            depth: 1
        )
        encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadgroupSize)
    }

    private func upsampleChain(commandBuffer: MTLCommandBuffer) {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.setComputePipelineState(upsamplePipeline)

        // Upsample 链：从最小分辨率开始，逐步放大
        // Step 0: low=down[2](1/8), high=down[1](1/4), out=up[0](1/4)
        // Step 1: low=up[0](1/4), high=down[0](1/2), out=up[1](1/2)
        // Step 2: low=up[1](1/2), high=bright(原始), out=up[2](原始)

        for i in 0..<mipLevels {
            let lowResTexture: MTLTexture
            let highResTexture: MTLTexture
            let outputTexture = upsampledTextures[i]

            if i == 0 {
                // 第一步：从最小的 downsample 开始
                lowResTexture = downsampledTextures[mipLevels - 1]  // down[2] = 1/8
                highResTexture = downsampledTextures[mipLevels - 2]  // down[1] = 1/4
            } else if i < mipLevels - 1 {
                // 中间步骤：上一个 upsample + 对应分辨率的 downsample
                lowResTexture = upsampledTextures[i - 1]
                highResTexture = downsampledTextures[mipLevels - 2 - i]
            } else {
                // 最后一步：upsample 到原始分辨率，使用 brightTexture
                lowResTexture = upsampledTextures[i - 1]
                highResTexture = brightTexture
            }

            encoder.setTexture(lowResTexture, index: 0)
            encoder.setTexture(highResTexture, index: 1)
            encoder.setTexture(outputTexture, index: 2)

            let threadgroupSize = MTLSize(width: 16, height: 16, depth: 1)
            let threadgroups = MTLSize(
                width: (outputTexture.width + 15) / 16,
                height: (outputTexture.height + 15) / 16,
                depth: 1
            )
            encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadgroupSize)
        }

        encoder.endEncoding()
    }

    private func finalBlend(originalTexture: MTLTexture, bloomTexture: MTLTexture, outputTexture: MTLTexture, commandBuffer: MTLCommandBuffer) {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.setComputePipelineState(blendBloomPipeline)
        encoder.setTexture(originalTexture, index: 0)
        encoder.setTexture(bloomTexture, index: 1)
        encoder.setTexture(outputTexture, index: 2)
        encoder.setBytes(&bloomStrength, length: MemoryLayout<Float>.size, index: 0)

        let threadgroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadgroups = MTLSize(
            width: (outputTexture.width + 15) / 16,
            height: (outputTexture.height + 15) / 16,
            depth: 1
        )
        encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadgroupSize)
        encoder.endEncoding()
    }
}
