// AdaptiveRenderer.swift
// 自适应采样渲染器（仅用于离线图片模式）

import Foundation
import Metal
import MetalKit

/// 自适应采样进度信息
struct AdaptiveProgress {
    var iteration: Int
    var convergedPixels: Int
    var totalPixels: Int
    var averageSpp: Float
    var averageVariance: Float
}

/// 自适应采样统计信息
struct AdaptiveStats {
    var totalRenderTime: TimeInterval
    var averageSpp: Float
    var minSpp: UInt32
    var maxSpp: UInt32
    var percentile25Spp: UInt32
    var percentile50Spp: UInt32
    var percentile75Spp: UInt32
    var samplesSavedPercent: Float
    var iterationCount: Int
}

/// 自适应采样配置（多阶段策略）
struct AdaptiveConfig {
    // 用户参数
    let minSpp: Int              // 最小保证采样（用户指定）
    let targetSpp: Int           // 总预算
    let varianceThreshold: Float // 方差阈值
    let relativeThreshold: Float // 相对误差阈值
    let batchSize: Int           // GPU 批次大小

    // 自动计算的阶段参数
    var warmupSpp: Int {
        // 确保至少 16 个样本才能可靠计算方差
        max(minSpp, 16)
    }

    var stage1End: Int {
        // Stage 1 结束于 warmup*4 或 70% 预算（取较小值）
        min(warmupSpp * 4, targetSpp * 7 / 10)
    }

    var stage2End: Int {
        // Stage 2 结束于 80% 预算
        targetSpp * 8 / 10
    }

    // 检查点生成
    func getCheckpoints(stage: Int, currentSpp: Int) -> [Int] {
        switch stage {
        case 0:
            // Stage 0: Warmup - 不检查方差
            return []

        case 1:
            // Stage 1: Early Rejection - 指数增长检查点
            // 在 warmup*2, warmup*4 时检查
            var checkpoints: [Int] = []
            var checkpoint = warmupSpp * 2
            while checkpoint <= stage1End {
                if checkpoint > currentSpp {
                    checkpoints.append(checkpoint)
                }
                checkpoint *= 2
            }
            return checkpoints

        case 2:
            // Stage 2: Adaptive - 线性间隔检查点
            let range = stage2End - stage1End
            let interval = range > 50 ? 16 : 8
            return stride(from: stage1End + interval, through: stage2End, by: interval)
                .filter { $0 > currentSpp }
                .map { $0 }

        case 3:
            // Stage 3: Final - 密集检查点
            return stride(from: stage2End + 4, through: targetSpp, by: 4)
                .filter { $0 > currentSpp }
                .map { $0 }

        default:
            return []
        }
    }

    // 获取阶段的方差阈值倍数
    func getThresholdMultiplier(stage: Int, progress: Float = 0.5) -> Float {
        switch stage {
        case 1:
            return 10.0  // Stage 1: 保守阈值（避免误判）
        case 2:
            // Stage 2: 渐进式阈值 (2.0 → 1.0)
            return 2.0 - progress
        case 3:
            return 1.0  // Stage 3: 严格阈值
        default:
            return 1.0
        }
    }

    // 获取阶段名称
    func getStageName(_ stage: Int) -> String {
        switch stage {
        case 0: return "Warmup"
        case 1: return "Early Rejection"
        case 2: return "Adaptive"
        case 3: return "Final Refinement"
        default: return "Unknown"
        }
    }
}

/// 自适应采样渲染器
class AdaptiveRenderer {
    let context: MetalContext
    let baseRenderer: Renderer

    // Compute Pipeline States
    var computeVariancePipeline: MTLComputePipelineState
    var computeVarianceWeightedPipeline: MTLComputePipelineState  // 材质加权方差
    var accumulateSamplesPipeline: MTLComputePipelineState
    var compactUnconvergedPipeline: MTLComputePipelineState
    var readFinalPixelsPipeline: MTLComputePipelineState
    var createPixelMaskPipeline: MTLComputePipelineState
    var resetPixelMaskPipeline: MTLComputePipelineState
    var initializeBuffersPipeline: MTLComputePipelineState

    init(context: MetalContext, baseRenderer: Renderer, library: MTLLibrary) {
        self.context = context
        self.baseRenderer = baseRenderer

        // 创建 compute pipelines
        guard let varianceFunc = library.makeFunction(name: "compute_variance"),
              let varianceWeightedFunc = library.makeFunction(name: "compute_variance_weighted"),
              let accumulateFunc = library.makeFunction(name: "accumulate_samples"),
              let compactFunc = library.makeFunction(name: "compact_unconverged_pixels"),
              let readFunc = library.makeFunction(name: "read_final_pixels"),
              let maskFunc = library.makeFunction(name: "create_pixel_mask"),
              let resetMaskFunc = library.makeFunction(name: "reset_pixel_mask"),
              let initBuffersFunc = library.makeFunction(name: "initialize_buffers") else {
            fatalError("Failed to find adaptive sampling functions in library")
        }

        self.computeVariancePipeline = try! context.device.makeComputePipelineState(function: varianceFunc)
        self.computeVarianceWeightedPipeline = try! context.device.makeComputePipelineState(function: varianceWeightedFunc)
        self.accumulateSamplesPipeline = try! context.device.makeComputePipelineState(function: accumulateFunc)
        self.compactUnconvergedPipeline = try! context.device.makeComputePipelineState(function: compactFunc)
        self.readFinalPixelsPipeline = try! context.device.makeComputePipelineState(function: readFunc)
        self.createPixelMaskPipeline = try! context.device.makeComputePipelineState(function: maskFunc)
        self.resetPixelMaskPipeline = try! context.device.makeComputePipelineState(function: resetMaskFunc)
        self.initializeBuffersPipeline = try! context.device.makeComputePipelineState(function: initBuffersFunc)
    }

    /// 自适应渲染主函数
    /// - Parameters:
    ///   - sceneName: 场景名称（用于进度显示）
    ///   - minSamples: 每个像素的最小采样数（即使方差已满足也必须采样）
    ///   - targetSpp: 总采样预算（总采样数 = width × height × targetSpp）
    ///   - batchSize: 每批 GPU 渲染的采样数（避免超时）
    func renderAdaptive(
        scene: Scene,
        camera: Camera,
        bvh: FlatBVH,
        sceneName: String,
        minSamples: Int = 16,
        targetSpp: Int,
        varianceThreshold: Float = 0.0001,
        relativeThreshold: Float = 0.01,
        batchSize: Int = 8,
        filterType: FilterType = .box,
        useBlueNoise: Bool = false,
        useWeightedVariance: Bool = false,
        progressCallback: ((AdaptiveProgress) -> Void)? = nil
    ) -> (pixels: [Float], renderTime: TimeInterval, stats: AdaptiveStats) {

        let startTime = Date()

        let width = camera.imageWidth
        let height = camera.imageHeight
        let totalPixels = width * height

        // 计算总采样预算
        let totalBudget = UInt64(width) * UInt64(height) * UInt64(targetSpp)
        var usedBudget: UInt64 = 0

        // 转换场景为 GPU 数据
        let (gpuSpheres, gpuQuads, gpuMaterials, gpuTextures, gpuTransforms) = scene.toGPU()

        // 创建 GPU 缓冲区
        guard let gpuBuffers = baseRenderer.createBuffers(
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

        // 1. 创建自适应采样缓冲区
        // 优化：使用 storageModePrivate 对于不需要 CPU 访问的缓冲区（GPU 更快）
        // 使用 storageModeShared 对于需要 CPU 读取的缓冲区
        
        // GPU-only 缓冲区（使用 Private 模式，性能更好）
        guard let colorSumBuffer = context.device.makeBuffer(
            length: totalPixels * MemoryLayout<SIMD4<Float>>.stride,
            options: .storageModePrivate
        ),
        let colorSumSquaredBuffer = context.device.makeBuffer(
            length: totalPixels * MemoryLayout<SIMD4<Float>>.stride,
            options: .storageModePrivate
        ),
        let pixelMaskBuffer = context.device.makeBuffer(
            length: totalPixels * MemoryLayout<UInt32>.stride,
            options: .storageModePrivate
        ) else {
            fatalError("Failed to allocate GPU-only adaptive sampling buffers")
        }
        
        // CPU-accessible 缓冲区（需要读取统计数据）
        guard let sampleCountBuffer = context.device.makeBuffer(
            length: totalPixels * MemoryLayout<UInt32>.stride,
            options: .storageModeShared
        ),
        let varianceBuffer = context.device.makeBuffer(
            length: totalPixels * MemoryLayout<Float>.stride,
            options: .storageModeShared
        ),
        let convergedFlagBuffer = context.device.makeBuffer(
            length: totalPixels * MemoryLayout<UInt32>.stride,
            options: .storageModeShared
        ),
        let unconvergedListBuffer = context.device.makeBuffer(
            length: totalPixels * MemoryLayout<UInt32>.stride,
            options: .storageModeShared
        ) else {
            fatalError("Failed to allocate CPU-accessible adaptive sampling buffers")
        }

        // 初始化 CPU-accessible 缓冲区为0
        memset(sampleCountBuffer.contents(), 0, sampleCountBuffer.length)
        memset(varianceBuffer.contents(), 0, varianceBuffer.length)
        memset(convergedFlagBuffer.contents(), 0, convergedFlagBuffer.length)
        
        // 初始化 GPU-only 缓冲区（使用 GPU kernel，比 CPU memset 更快）
        initializeGPUBuffers(
            colorSumBuffer: colorSumBuffer,
            colorSumSquaredBuffer: colorSumSquaredBuffer,
            sampleCountBuffer: sampleCountBuffer,
            totalPixels: totalPixels
        )

        // 创建自适应采样配置
        let config = AdaptiveConfig(
            minSpp: minSamples,
            targetSpp: targetSpp,
            varianceThreshold: varianceThreshold,
            relativeThreshold: relativeThreshold,
            batchSize: batchSize
        )

        // 创建进度统计对象
        let progressStats = AdaptiveRenderStats(
            sceneName: sceneName,
            width: width,
            height: height,
            minSpp: config.warmupSpp,
            targetSpp: targetSpp,
            maxDepth: Int(scene.camera.maxDepth),
            totalBudget: totalBudget,
            cameraConfig: scene.camera,
            filterType: filterType,
            useBlueNoise: useBlueNoise,
            tonemapMode: .none,
            bloomStrength: 0.0,
            bloomThreshold: 1.0
        )

        // 打印阶段规划
        ThreadSafeLogger.shared.logln("")
        ThreadSafeLogger.shared.logln("╔══════════════════════════════════════════════════════════╗")
        ThreadSafeLogger.shared.logln("║        Multi-Stage Adaptive Sampling Strategy           ║")
        ThreadSafeLogger.shared.logln("╚══════════════════════════════════════════════════════════╝")
        ThreadSafeLogger.shared.logln("  Stage 0 (Warmup)          : 0 → \(config.warmupSpp) spp")
        ThreadSafeLogger.shared.logln("  Stage 1 (Early Rejection) : \(config.warmupSpp) → \(config.stage1End) spp")
        ThreadSafeLogger.shared.logln("  Stage 2 (Adaptive)        : \(config.stage1End) → \(config.stage2End) spp")
        ThreadSafeLogger.shared.logln("  Stage 3 (Final Refinement): \(config.stage2End) → \(targetSpp) spp")
        ThreadSafeLogger.shared.logln("")

        var currentSpp = 0
        var currentSampleOffset = 0
        var checkpointCount = 0

        // ========== Stage 0: Warmup ==========
        // 所有像素渲染到 warmupSpp，建立方差基线
        ThreadSafeLogger.shared.logln("→ Stage 0: Warmup (\(config.warmupSpp) spp)")

        while currentSpp < config.warmupSpp {
            let samplesThisBatch = min(batchSize, config.warmupSpp - currentSpp)

            guard let batchTexture = baseRenderer.renderToTexture(
                scene: scene,
                camera: camera,
                bvh: bvh,
                buffers: gpuBuffers,
                sphereCount: gpuSpheres.count,
                quadCount: gpuQuads.count,
                batchSize: samplesThisBatch,
                sampleOffset: UInt32(currentSampleOffset),
                filterType: filterType,
                useBlueNoise: useBlueNoise,
                pixelMask: nil  // Phase1 渲染所有像素
            ) else {
                fatalError("Failed to render batch at offset \(currentSampleOffset)")
            }

            // 累积到自适应缓冲区（所有像素）
            accumulateToAdaptiveBuffers(
                texture: batchTexture,
                colorSumBuffer: colorSumBuffer,
                colorSumSquaredBuffer: colorSumSquaredBuffer,
                sampleCountBuffer: sampleCountBuffer,
                pixelMaskBuffer: nil,  // 所有像素
                spp: UInt32(samplesThisBatch),
                width: width,
                height: height
            )

            currentSpp += samplesThisBatch
            currentSampleOffset += samplesThisBatch
            usedBudget += UInt64(totalPixels) * UInt64(samplesThisBatch)
        }

        ThreadSafeLogger.shared.logln("  ✓ Warmup complete: \(currentSpp) spp")

        // 创建自适应参数结构
        var adaptiveParams = AdaptiveSamplingParams(
            minSamples: UInt32(config.warmupSpp),
            targetSpp: UInt32(targetSpp),
            varianceThreshold: varianceThreshold,
            adaptiveBatchSize: UInt32(batchSize),
            width: UInt32(width),
            height: UInt32(height),
            currentPass: 0,
            adaptiveRelativeThreshold: relativeThreshold,
            totalBudget: totalBudget,
            usedBudget: usedBudget
        )

        // ========== Stage 1, 2, 3: 多阶段自适应采样 ==========
        // 处理 Stage 1-3（Early Rejection → Adaptive → Final Refinement）
        for stage in 1...3 {
            // 跳过预算已用完或已达到目标的阶段
            let stageEnd: Int
            switch stage {
            case 1: stageEnd = config.stage1End
            case 2: stageEnd = config.stage2End
            case 3: stageEnd = targetSpp
            default: continue
            }

            if currentSpp >= stageEnd {
                continue  // 已经完成这个阶段
            }

            ThreadSafeLogger.shared.logln("")
            ThreadSafeLogger.shared.logln("→ Stage \(stage): \(config.getStageName(stage)) (\(currentSpp) → \(stageEnd) spp)")

            // 获取本阶段的检查点
            let checkpoints = config.getCheckpoints(stage: stage, currentSpp: currentSpp)

            if checkpoints.isEmpty {
                // 如果没有检查点，直接渲染到阶段结束
                while currentSpp < stageEnd && usedBudget < totalBudget {
                    let samplesThisBatch = min(batchSize, stageEnd - currentSpp)
                    let remainingBudget = Int64(totalBudget) - Int64(usedBudget)

                    if remainingBudget <= 0 {
                        ThreadSafeLogger.shared.logln("  Budget exhausted at \(currentSpp) spp")
                        break
                    }

                    // Stage 1: 所有像素  | Stage 2-3: 未收敛像素
                    let pixelMask = (stage == 1) ? nil : pixelMaskBuffer

                    guard let batchTexture = baseRenderer.renderToTexture(
                        scene: scene,
                        camera: camera,
                        bvh: bvh,
                        buffers: gpuBuffers,
                        sphereCount: gpuSpheres.count,
                        quadCount: gpuQuads.count,
                        batchSize: samplesThisBatch,
                        sampleOffset: UInt32(currentSampleOffset),
                        filterType: filterType,
                        useBlueNoise: useBlueNoise,
                        pixelMask: pixelMask
                    ) else {
                        fatalError("Failed to render batch")
                    }

                    accumulateToAdaptiveBuffers(
                        texture: batchTexture,
                        colorSumBuffer: colorSumBuffer,
                        colorSumSquaredBuffer: colorSumSquaredBuffer,
                        sampleCountBuffer: sampleCountBuffer,
                        pixelMaskBuffer: pixelMask,
                        spp: UInt32(samplesThisBatch),
                        width: width,
                        height: height
                    )

                    currentSpp += samplesThisBatch
                    currentSampleOffset += samplesThisBatch

                    let samplesUsed = (pixelMask == nil) ?
                        UInt64(totalPixels) * UInt64(samplesThisBatch) :
                        UInt64(getUnconvergedPixels(convergedFlagBuffer: convergedFlagBuffer,
                                                    unconvergedListBuffer: unconvergedListBuffer,
                                                    totalPixels: totalPixels).count) * UInt64(samplesThisBatch)
                    usedBudget += samplesUsed
                }
                continue
            }

            // 有检查点的阶段：渐进式淘汰
            for checkpoint in checkpoints {
                if usedBudget >= totalBudget {
                    ThreadSafeLogger.shared.logln("  Budget exhausted")
                    break
                }

                // 渲染到检查点
                while currentSpp < checkpoint && usedBudget < totalBudget {
                    // 获取未收敛像素（Stage 1开始就使用掩码）
                    let unconvergedPixels = (stage >= 1 && checkpointCount > 0) ?
                        getUnconvergedPixels(convergedFlagBuffer: convergedFlagBuffer,
                                           unconvergedListBuffer: unconvergedListBuffer,
                                           totalPixels: totalPixels) :
                        []

                    let usePixelMask = !unconvergedPixels.isEmpty
                    let activePixelCount = usePixelMask ? unconvergedPixels.count : totalPixels

                    if usePixelMask && unconvergedPixels.isEmpty {
                        ThreadSafeLogger.shared.logln("  All pixels converged!")
                        break
                    }

                    // 创建像素掩码
                    if usePixelMask {
                        resetPixelMask(buffer: pixelMaskBuffer, totalPixels: totalPixels)
                        createPixelMaskGPU(unconvergedList: unconvergedPixels,
                                          pixelMaskBuffer: pixelMaskBuffer,
                                          unconvergedCount: unconvergedPixels.count)
                    }

                    let samplesThisBatch = min(batchSize, checkpoint - currentSpp)
                    let remainingBudget = Int64(totalBudget) - Int64(usedBudget)
                    let maxAffordable = Int(remainingBudget) / max(activePixelCount, 1)

                    if maxAffordable <= 0 {
                        ThreadSafeLogger.shared.logln("  Budget exhausted")
                        break
                    }

                    let actualSamples = min(samplesThisBatch, maxAffordable, 32)

                    guard let batchTexture = baseRenderer.renderToTexture(
                        scene: scene,
                        camera: camera,
                        bvh: bvh,
                        buffers: gpuBuffers,
                        sphereCount: gpuSpheres.count,
                        quadCount: gpuQuads.count,
                        batchSize: actualSamples,
                        sampleOffset: UInt32(currentSampleOffset),
                        filterType: filterType,
                        useBlueNoise: useBlueNoise,
                        pixelMask: usePixelMask ? pixelMaskBuffer : nil
                    ) else {
                        fatalError("Failed to render batch")
                    }

                    accumulateToAdaptiveBuffers(
                        texture: batchTexture,
                        colorSumBuffer: colorSumBuffer,
                        colorSumSquaredBuffer: colorSumSquaredBuffer,
                        sampleCountBuffer: sampleCountBuffer,
                        pixelMaskBuffer: usePixelMask ? pixelMaskBuffer : nil,
                        spp: UInt32(actualSamples),
                        width: width,
                        height: height
                    )

                    currentSpp += actualSamples
                    currentSampleOffset += actualSamples
                    usedBudget += UInt64(activePixelCount) * UInt64(actualSamples)
                }

                // 到达检查点：计算方差并更新收敛状态
                checkpointCount += 1

                // 计算阶段进度
                let stageProgress = Float(currentSpp - (stage == 1 ? config.warmupSpp : (stage == 2 ? config.stage1End : config.stage2End))) /
                                   Float(stageEnd - (stage == 1 ? config.warmupSpp : (stage == 2 ? config.stage1End : config.stage2End)))

                // 获取阈值倍数
                let thresholdMultiplier = config.getThresholdMultiplier(stage: stage, progress: stageProgress)

                // 更新自适应参数
                adaptiveParams.varianceThreshold = varianceThreshold * thresholdMultiplier
                adaptiveParams.currentPass = UInt32(checkpointCount)
                adaptiveParams.usedBudget = usedBudget

                // 计算方差（使用材质加权或标准方差）
                computeVariance(
                    colorSumBuffer: colorSumBuffer,
                    colorSumSquaredBuffer: colorSumSquaredBuffer,
                    sampleCountBuffer: sampleCountBuffer,
                    varianceBuffer: varianceBuffer,
                    convergedFlagBuffer: convergedFlagBuffer,
                    params: &adaptiveParams,
                    width: width,
                    height: height,
                    pipelineState: useWeightedVariance ? computeVarianceWeightedPipeline : nil
                )

                // 统计收敛情况
                let convergedCount = readConvergedCount(buffer: convergedFlagBuffer, totalPixels: totalPixels)
                let convergedPercent = Float(convergedCount) / Float(totalPixels) * 100

                ThreadSafeLogger.shared.logln("  Checkpoint \(checkpoint) spp: \(convergedCount)/\(totalPixels) converged (\(String(format: "%.1f", convergedPercent))%), threshold=\(String(format: "%.2e", varianceThreshold * thresholdMultiplier))")

                // 检查是否全部收敛
                if convergedCount == totalPixels {
                    ThreadSafeLogger.shared.logln("  All pixels converged!")
                    break
                }
            }

            ThreadSafeLogger.shared.logln("  ✓ Stage \(stage) complete: \(currentSpp) spp")
        }

        let renderTime = Date().timeIntervalSince(startTime)

        // 5. 读取最终结果
        let pixels = readFinalPixels(
            colorSumBuffer: colorSumBuffer,
            sampleCountBuffer: sampleCountBuffer,
            width: width,
            height: height
        )

        // 6. 生成统计报告
        ThreadSafeLogger.shared.logln("")
        ThreadSafeLogger.shared.logln("✓ Adaptive sampling complete!")

        let sampleCounts = readSampleCounts(buffer: sampleCountBuffer, totalPixels: totalPixels)
        let stats = generateStats(
            sampleCounts: sampleCounts,
            renderTime: renderTime,
            targetSpp: targetSpp,
            iterationCount: checkpointCount,
            totalPixels: totalPixels,
            totalBudget: totalBudget,
            usedBudget: usedBudget
        )

        return (pixels, renderTime, stats)
    }

    // MARK: - 辅助方法

    /// 初始化GPU缓冲区（清零colorSum和colorSumSquared）
    private func initializeGPUBuffers(
        colorSumBuffer: MTLBuffer,
        colorSumSquaredBuffer: MTLBuffer,
        sampleCountBuffer: MTLBuffer,
        totalPixels: Int
    ) {
        guard let commandBuffer = context.commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return
        }

        encoder.setComputePipelineState(initializeBuffersPipeline)
        encoder.setBuffer(colorSumBuffer, offset: 0, index: 0)
        encoder.setBuffer(colorSumSquaredBuffer, offset: 0, index: 1)
        encoder.setBuffer(sampleCountBuffer, offset: 0, index: 2)
        var totalPixelsVar = UInt32(totalPixels)
        encoder.setBytes(&totalPixelsVar, length: MemoryLayout<UInt32>.stride, index: 3)

        let threadsPerGrid = MTLSize(width: totalPixels, height: 1, depth: 1)
        let threadsPerThreadgroup = MTLSize(width: 256, height: 1, depth: 1)
        encoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)

        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    private func accumulateToAdaptiveBuffers(
        texture: MTLTexture,
        colorSumBuffer: MTLBuffer,
        colorSumSquaredBuffer: MTLBuffer,
        sampleCountBuffer: MTLBuffer,
        pixelMaskBuffer: MTLBuffer?,
        spp: UInt32,
        width: Int,
        height: Int
    ) {
        guard let commandBuffer = context.commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return
        }

        encoder.setComputePipelineState(accumulateSamplesPipeline)
        encoder.setTexture(texture, index: 0)
        encoder.setBuffer(colorSumBuffer, offset: 0, index: 0)
        encoder.setBuffer(colorSumSquaredBuffer, offset: 0, index: 1)
        encoder.setBuffer(sampleCountBuffer, offset: 0, index: 2)
        if let mask = pixelMaskBuffer {
            encoder.setBuffer(mask, offset: 0, index: 3)
        }
        var sppValue = spp
        encoder.setBytes(&sppValue, length: MemoryLayout<UInt32>.stride, index: 4)

        let threadsPerGrid = MTLSize(width: width, height: height, depth: 1)
        let threadsPerThreadgroup = MTLSize(width: 16, height: 16, depth: 1)
        encoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)

        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    private func computeVariance(
        colorSumBuffer: MTLBuffer,
        colorSumSquaredBuffer: MTLBuffer,
        sampleCountBuffer: MTLBuffer,
        varianceBuffer: MTLBuffer,
        convergedFlagBuffer: MTLBuffer,
        params: inout AdaptiveSamplingParams,
        width: Int,
        height: Int,
        pipelineState: MTLComputePipelineState? = nil
    ) {
        guard let commandBuffer = context.commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return
        }

        encoder.setComputePipelineState(pipelineState ?? computeVariancePipeline)
        encoder.setBuffer(colorSumBuffer, offset: 0, index: 0)
        encoder.setBuffer(colorSumSquaredBuffer, offset: 0, index: 1)
        encoder.setBuffer(sampleCountBuffer, offset: 0, index: 2)
        encoder.setBuffer(varianceBuffer, offset: 0, index: 3)
        encoder.setBuffer(convergedFlagBuffer, offset: 0, index: 4)
        encoder.setBytes(&params, length: MemoryLayout<AdaptiveSamplingParams>.stride, index: 5)

        let threadsPerGrid = MTLSize(width: width, height: height, depth: 1)
        let threadsPerThreadgroup = MTLSize(width: 16, height: 16, depth: 1)
        encoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)

        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    private func getUnconvergedPixels(
        convergedFlagBuffer: MTLBuffer,
        unconvergedListBuffer: MTLBuffer,
        totalPixels: Int
    ) -> [UInt32] {
        // 重置计数器
        guard let counterBuffer = context.device.makeBuffer(
            length: MemoryLayout<UInt32>.stride,
            options: .storageModeShared
        ) else {
            return []
        }
        counterBuffer.contents().storeBytes(of: UInt32(0), as: UInt32.self)

        // 执行压缩
        guard let commandBuffer = context.commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return []
        }

        encoder.setComputePipelineState(compactUnconvergedPipeline)
        encoder.setBuffer(convergedFlagBuffer, offset: 0, index: 0)
        encoder.setBuffer(unconvergedListBuffer, offset: 0, index: 1)
        encoder.setBuffer(counterBuffer, offset: 0, index: 2)
        var totalPixelsVar = UInt32(totalPixels)
        encoder.setBytes(&totalPixelsVar, length: MemoryLayout<UInt32>.stride, index: 3)

        let threadsPerGrid = MTLSize(width: totalPixels, height: 1, depth: 1)
        let threadsPerThreadgroup = MTLSize(width: 256, height: 1, depth: 1)
        encoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)

        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        // 读取计数
        let count = counterBuffer.contents().load(as: UInt32.self)

        // 读取列表
        let listPointer = unconvergedListBuffer.contents().bindMemory(to: UInt32.self, capacity: Int(count))
        return Array(UnsafeBufferPointer(start: listPointer, count: Int(count)))
    }

    /// 重置像素掩码（GPU版本，比CPU memset更高效）
    private func resetPixelMask(buffer: MTLBuffer, totalPixels: Int) {
        guard let commandBuffer = context.commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return
        }

        encoder.setComputePipelineState(resetPixelMaskPipeline)
        encoder.setBuffer(buffer, offset: 0, index: 0)
        var totalPixelsVar = UInt32(totalPixels)
        encoder.setBytes(&totalPixelsVar, length: MemoryLayout<UInt32>.stride, index: 1)

        let threadsPerGrid = MTLSize(width: totalPixels, height: 1, depth: 1)
        let threadsPerThreadgroup = MTLSize(width: 256, height: 1, depth: 1)
        encoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)

        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    /// 创建像素掩码（GPU版本，从未收敛像素列表）
    private func createPixelMaskGPU(
        unconvergedList: [UInt32],
        pixelMaskBuffer: MTLBuffer,
        unconvergedCount: Int
    ) {
        // 如果列表为空，直接返回
        guard unconvergedCount > 0 else { return }

        // 将未收敛像素列表上传到GPU
        guard let unconvergedListBuffer = context.device.makeBuffer(
            bytes: unconvergedList,
            length: unconvergedCount * MemoryLayout<UInt32>.stride,
            options: .storageModeShared
        ) else {
            // 如果GPU分配失败，回退到CPU版本
            let maskPointer = pixelMaskBuffer.contents().bindMemory(to: UInt32.self, capacity: unconvergedCount)
            for pixelIdx in unconvergedList {
                maskPointer[Int(pixelIdx)] = 1
            }
            return
        }

        guard let commandBuffer = context.commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return
        }

        encoder.setComputePipelineState(createPixelMaskPipeline)
        encoder.setBuffer(unconvergedListBuffer, offset: 0, index: 0)
        encoder.setBuffer(pixelMaskBuffer, offset: 0, index: 1)
        var unconvergedCountVar = UInt32(unconvergedCount)
        encoder.setBytes(&unconvergedCountVar, length: MemoryLayout<UInt32>.stride, index: 2)

        let threadsPerGrid = MTLSize(width: unconvergedCount, height: 1, depth: 1)
        let threadsPerThreadgroup = MTLSize(width: 256, height: 1, depth: 1)
        encoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)

        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    private func readFinalPixels(
        colorSumBuffer: MTLBuffer,
        sampleCountBuffer: MTLBuffer,
        width: Int,
        height: Int
    ) -> [Float] {
        guard let outputBuffer = context.device.makeBuffer(
            length: width * height * 4 * MemoryLayout<Float>.stride,  // RGBA
            options: .storageModeShared
        ) else {
            return []
        }

        guard let commandBuffer = context.commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return []
        }

        encoder.setComputePipelineState(readFinalPixelsPipeline)
        encoder.setBuffer(colorSumBuffer, offset: 0, index: 0)
        encoder.setBuffer(sampleCountBuffer, offset: 0, index: 1)
        encoder.setBuffer(outputBuffer, offset: 0, index: 2)
        var widthVar = UInt32(width)
        var heightVar = UInt32(height)
        encoder.setBytes(&widthVar, length: MemoryLayout<UInt32>.stride, index: 3)
        encoder.setBytes(&heightVar, length: MemoryLayout<UInt32>.stride, index: 4)

        let threadsPerGrid = MTLSize(width: width, height: height, depth: 1)
        let threadsPerThreadgroup = MTLSize(width: 16, height: 16, depth: 1)
        encoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)

        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        // 读取结果（RGBA）
        let pixelPointer = outputBuffer.contents().bindMemory(to: Float.self, capacity: width * height * 4)
        return Array(UnsafeBufferPointer(start: pixelPointer, count: width * height * 4))
    }

    private func readSampleCounts(buffer: MTLBuffer, totalPixels: Int) -> [UInt32] {
        let pointer = buffer.contents().bindMemory(to: UInt32.self, capacity: totalPixels)
        return Array(UnsafeBufferPointer(start: pointer, count: totalPixels))
    }

    private func readVariances(buffer: MTLBuffer, totalPixels: Int) -> [Float] {
        let pointer = buffer.contents().bindMemory(to: Float.self, capacity: totalPixels)
        return Array(UnsafeBufferPointer(start: pointer, count: totalPixels))
    }

    private func readConvergedCount(buffer: MTLBuffer, totalPixels: Int) -> Int {
        let pointer = buffer.contents().bindMemory(to: UInt32.self, capacity: totalPixels)
        let flags = Array(UnsafeBufferPointer(start: pointer, count: totalPixels))
        return flags.filter { $0 == 1 }.count
    }

    private func generateStats(
        sampleCounts: [UInt32],
        renderTime: TimeInterval,
        targetSpp: Int,
        iterationCount: Int,
        totalPixels: Int,
        totalBudget: UInt64,
        usedBudget: UInt64
    ) -> AdaptiveStats {
        let sortedCounts = sampleCounts.sorted()
        let count = sortedCounts.count

        let minSpp = sortedCounts.first ?? 0
        let maxSpp = sortedCounts.last ?? 0

        // 安全的百分位数计算
        let percentile25Spp = sortedCounts[min(count / 4, count - 1)]
        let percentile50Spp = sortedCounts[min(count / 2, count - 1)]
        let percentile75Spp = sortedCounts[min(count * 3 / 4, count - 1)]

        let totalSamplesUsed = sampleCounts.reduce(UInt64(0)) { partial, v in
            partial + UInt64(v)
        }
        let averageSpp = Float(totalSamplesUsed) / Float(totalPixels)

        // 计算节省百分比（相对于固定采样 targetSpp），防止溢出
        let clampedUsed = min(usedBudget, totalBudget)
        let saved = totalBudget > 0 ? max(0, Int64(totalBudget - clampedUsed)) : 0
        let samplesSaved = totalBudget > 0 ? Float(saved) / Float(totalBudget) : 0

        return AdaptiveStats(
            totalRenderTime: renderTime,
            averageSpp: averageSpp,
            minSpp: minSpp,
            maxSpp: maxSpp,
            percentile25Spp: percentile25Spp,
            percentile50Spp: percentile50Spp,
            percentile75Spp: percentile75Spp,
            samplesSavedPercent: samplesSaved,
            iterationCount: iterationCount
        )
    }
}
