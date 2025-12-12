# Phase 10a: 自适应采样 (Adaptive Sampling)

**创建日期**: 2025-12-11
**前置条件**: Phase 1-9 完成
**实施周期**: 3-5 天
**优先级**: ⭐⭐⭐⭐⭐ 最高
**预期收益**: 渲染时间节省 **30-60%**

---

## 目标概览

### 核心问题

当前渲染器对所有像素使用**固定采样数** (spp)：

```
Cornell Box (400×400, 100 spp):
- 白色墙壁（纯色）: 100 spp → 浪费 70-80 spp
- 玻璃球边缘（高方差）: 100 spp → 仍有噪点
- 阴影边界（中方差）: 100 spp → 刚好够用

结果: 60-70% 的采样是浪费的！
```

### 自适应采样解决方案

**核心思想**: 根据像素颜色方差动态分配采样数

```
像素类型          | 方差  | 传统 spp | 自适应 spp | 节省
------------------|-------|----------|-----------|------
纯色墙壁          | 0.001 | 100      | 20        | 80%
光滑金属反射      | 0.010 | 100      | 40        | 60%
阴影边界          | 0.050 | 100      | 100       | 0%
玻璃折射边缘      | 0.150 | 100      | 200       | -100% (需要更多)

平均节省: 30-60%
```

---

## 一、技术架构

### 1.1 数学原理

#### 方差估计

对于像素 $(x, y)$，经过 $N$ 次采样后：

$$
\begin{aligned}
\text{Mean} &= \frac{1}{N} \sum_{i=1}^{N} C_i \\
\text{Variance} &= \frac{1}{N} \sum_{i=1}^{N} (C_i - \text{Mean})^2 \\
&= \frac{1}{N} \sum_{i=1}^{N} C_i^2 - \text{Mean}^2 \\
\end{aligned}
$$

**GPU 友好的累积形式**:
```
sum_color += color_i
sum_color_squared += color_i * color_i

mean = sum_color / N
variance = sum_color_squared / N - mean * mean
```

#### 收敛判断

像素收敛条件：
$$
\text{Variance} < \text{Threshold}
$$

**自适应阈值**（基于相对误差）:
$$
\text{Threshold} = (\text{target\_error} \times \text{mean\_luminance})^2
$$

典型值：`target_error = 0.01`（1% 相对误差）

### 1.2 数据结构设计

#### A. GPU 缓冲区（Sources/GPU/GPUStructs.swift）

```swift
/// 自适应采样缓冲区
struct AdaptiveSamplingBuffers {
    // 像素采样计数（每个像素当前采样数）
    var sampleCountBuffer: MTLBuffer        // uint[width * height]

    // 颜色累积（用于计算均值）
    var colorSumBuffer: MTLBuffer           // float4[width * height]

    // 颜色平方累积（用于计算方差）
    var colorSumSquaredBuffer: MTLBuffer    // float4[width * height]

    // 方差缓冲（当前方差值）
    var varianceBuffer: MTLBuffer           // float[width * height]

    // 收敛标志（0=未收敛, 1=已收敛）
    var convergedFlagBuffer: MTLBuffer      // uint[width * height]

    // 全局统计
    var globalStatsBuffer: MTLBuffer        // AdaptiveGlobalStats
}

/// 全局统计数据（用于进度跟踪）
struct AdaptiveGlobalStats {
    var totalConvergedPixels: UInt32        // 已收敛像素数
    var totalSamplesUsed: UInt64            // 总采样数
    var averageVariance: Float              // 平均方差
    var maxVariance: Float                  // 最大方差
}
```

#### B. GPU 结构体（Shaders/Common/Types.metal）

```metal
/// 自适应采样参数
struct AdaptiveSamplingParams {
    uint min_samples;           // 最小采样数（如 16）
    uint max_samples;           // 最大采样数（如 1024）
    float variance_threshold;   // 方差阈值（如 0.0001）
    uint adaptive_batch_size;   // 每批次增量（如 4 或 8）

    uint width;                 // 图像宽度
    uint height;                // 图像高度
    uint current_pass;          // 当前采样轮次
    float adaptive_relative_threshold;  // 相对误差阈值（如 0.01 = 1%）
};
```

### 1.3 渲染流程

#### 总体架构（Sources/Rendering/AdaptiveRenderer.swift - 新文件）

```swift
class AdaptiveRenderer {
    let context: MetalContext
    let baseRenderer: Renderer  // 复用现有 Renderer

    // Compute Pipeline States
    var computeVariancePipeline: MTLComputePipelineState
    var compactUnconvergedPipeline: MTLComputePipelineState
    var updateStatsPipeline: MTLComputePipelineState

    var buffers: AdaptiveSamplingBuffers

    /// 自适应渲染主函数
    func renderAdaptive(
        scene: Scene,
        camera: Camera,
        bvh: FlatBVH,
        minSamples: Int = 16,
        maxSamples: Int,
        varianceThreshold: Float = 0.0001,
        batchSize: Int = 8,
        progressCallback: ((AdaptiveProgress) -> Void)? = nil
    ) -> (pixels: [Float], renderTime: TimeInterval, stats: AdaptiveStats) {

        let startTime = Date()

        // 1. 初始化缓冲区
        resetBuffers()

        // 2. 第一轮：所有像素渲染 minSamples
        print("Phase 1: Rendering initial \(minSamples) samples for all pixels...")
        renderUniformBatch(
            scene: scene, camera: camera, bvh: bvh,
            spp: minSamples, sampleOffset: 0
        )

        // 3. 计算初始方差
        computeVariance()

        // 4. 迭代自适应采样
        var currentTotalSamples = minSamples
        var iteration = 1

        while currentTotalSamples < maxSamples {
            // 4a. 获取未收敛像素列表
            let unconvergedPixels = getUnconvergedPixels()

            if unconvergedPixels.isEmpty {
                print("All pixels converged at \(currentTotalSamples) spp")
                break
            }

            let unconvergedRatio = Float(unconvergedPixels.count) / Float(camera.imageWidth * camera.imageHeight)
            print("Iteration \(iteration): \(unconvergedPixels.count) pixels (\(String(format: "%.1f%%", unconvergedRatio * 100))) still need samples")

            // 4b. 只对未收敛像素继续采样
            renderAdaptiveBatch(
                scene: scene, camera: camera, bvh: bvh,
                unconvergedPixels: unconvergedPixels,
                spp: batchSize,
                sampleOffset: UInt32(currentTotalSamples)
            )

            currentTotalSamples += batchSize

            // 4c. 重新计算方差
            computeVariance()

            // 4d. 更新全局统计
            let stats = updateGlobalStats()

            // 4e. 进度回调
            progressCallback?(AdaptiveProgress(
                iteration: iteration,
                convergedPixels: Int(stats.totalConvergedPixels),
                totalPixels: camera.imageWidth * camera.imageHeight,
                averageSpp: Float(stats.totalSamplesUsed) / Float(camera.imageWidth * camera.imageHeight),
                averageVariance: stats.averageVariance
            ))

            iteration += 1
        }

        let renderTime = Date().timeIntervalSince(startTime)

        // 5. 读取最终结果
        let pixels = readFinalPixels()

        // 6. 生成统计报告
        let finalStats = generateStats()

        return (pixels, renderTime, finalStats)
    }

    /// 第一轮均匀采样
    private func renderUniformBatch(
        scene: Scene, camera: Camera, bvh: FlatBVH,
        spp: Int, sampleOffset: UInt32
    ) {
        // 复用现有 Renderer 的 renderToTexture
        guard let texture = baseRenderer.renderToTexture(
            scene: scene,
            camera: camera,
            bvh: bvh,
            buffers: gpuBuffers,
            sphereCount: sphereCount,
            quadCount: quadCount,
            batchSize: spp,
            sampleOffset: sampleOffset
        ) else {
            fatalError("Failed to render uniform batch")
        }

        // 累积到自适应缓冲区
        accumulateToAdaptiveBuffers(texture: texture, spp: UInt32(spp))
    }

    /// 自适应批次采样（仅未收敛像素）
    private func renderAdaptiveBatch(
        scene: Scene, camera: Camera, bvh: FlatBVH,
        unconvergedPixels: [UInt32],
        spp: Int, sampleOffset: UInt32
    ) {
        // 创建稀疏像素掩码
        let maskTexture = createPixelMask(pixels: unconvergedPixels)

        // 渲染（只写入掩码区域）
        guard let texture = baseRenderer.renderToTexture(
            scene: scene,
            camera: camera,
            bvh: bvh,
            buffers: gpuBuffers,
            sphereCount: sphereCount,
            quadCount: quadCount,
            batchSize: spp,
            sampleOffset: sampleOffset
        ) else {
            fatalError("Failed to render adaptive batch")
        }

        // 累积到自适应缓冲区（使用掩码）
        accumulateToAdaptiveBuffers(
            texture: texture,
            spp: UInt32(spp),
            mask: maskTexture
        )
    }
}
```

---

## 二、Metal Shader 实现

### 2.1 方差计算内核

**文件**: `Shaders/Kernels/AdaptiveSampling.metal`（新文件）

```metal
#include <metal_stdlib>
#include "../Common/Types.metal"
using namespace metal;

/// 计算像素方差并判断收敛
kernel void compute_variance(
    device const float4* color_sum [[buffer(0)]],           // 颜色累积
    device const float4* color_sum_squared [[buffer(1)]],   // 颜色平方累积
    device const uint* sample_count [[buffer(2)]],          // 采样计数
    device float* variance [[buffer(3)]],                   // 输出方差
    device uint* converged_flags [[buffer(4)]],             // 输出收敛标志
    constant AdaptiveSamplingParams& params [[buffer(5)]],  // 参数
    uint2 gid [[thread_position_in_grid]]
) {
    // 边界检查
    if (gid.x >= params.width || gid.y >= params.height) return;

    uint pixel_idx = gid.y * params.width + gid.x;
    uint N = sample_count[pixel_idx];

    // 至少需要 min_samples 才计算方差
    if (N < params.min_samples) return;

    // 计算均值
    float3 sum = color_sum[pixel_idx].rgb;
    float3 mean = sum / float(N);

    // 计算方差: Var[X] = E[X²] - E[X]²
    float3 sum_squared = color_sum_squared[pixel_idx].rgb;
    float3 mean_squared = sum_squared / float(N);
    float3 var = mean_squared - mean * mean;

    // 取 RGB 三通道最大方差（保守估计）
    float pixel_var = max(var.r, max(var.g, var.b));

    // 防止负方差（数值误差）
    pixel_var = max(0.0f, pixel_var);

    variance[pixel_idx] = pixel_var;

    // 自适应阈值（相对误差）
    float luminance = 0.299f * mean.r + 0.587f * mean.g + 0.114f * mean.b;
    float adaptive_threshold = (params.adaptive_relative_threshold * luminance);
    adaptive_threshold = adaptive_threshold * adaptive_threshold;  // 方差是误差的平方

    // 使用固定阈值和自适应阈值的最大值
    float final_threshold = max(params.variance_threshold, adaptive_threshold);

    // 判断收敛
    if (pixel_var < final_threshold && N >= params.min_samples) {
        converged_flags[pixel_idx] = 1;
    } else if (N >= params.max_samples) {
        // 达到最大采样数，强制收敛
        converged_flags[pixel_idx] = 1;
    }
}

/// 累积新采样到自适应缓冲区
kernel void accumulate_samples(
    texture2d<float, access::read> new_samples [[texture(0)]],   // 新渲染的采样
    device float4* color_sum [[buffer(0)]],                      // 颜色累积
    device float4* color_sum_squared [[buffer(1)]],              // 颜色平方累积
    device atomic_uint* sample_count [[buffer(2)]],              // 采样计数（原子）
    device const uint* pixel_mask [[buffer(3)]],                 // 像素掩码（可选，null = 所有像素）
    constant uint& spp [[buffer(4)]],                            // 本批次采样数
    uint2 gid [[thread_position_in_grid]]
) {
    uint pixel_idx = gid.y * new_samples.get_width() + gid.x;

    // 检查像素掩码
    if (pixel_mask != nullptr && pixel_mask[pixel_idx] == 0) {
        return;
    }

    // 读取新采样
    float4 new_color = new_samples.read(gid);

    // 累积颜色
    color_sum[pixel_idx] += new_color;

    // 累积颜色平方（用于方差计算）
    float4 squared = new_color * new_color;
    color_sum_squared[pixel_idx] += squared;

    // 原子递增采样计数
    atomic_fetch_add_explicit(&sample_count[pixel_idx], spp, memory_order_relaxed);
}

/// 更新全局统计信息
kernel void update_global_stats(
    device const float* variance [[buffer(0)]],
    device const uint* converged_flags [[buffer(1)]],
    device const uint* sample_count [[buffer(2)]],
    device AdaptiveGlobalStats* global_stats [[buffer(3)]],
    constant uint& total_pixels [[buffer(4)]],
    uint gid [[thread_position_in_grid]]
) {
    // 使用并行规约（Parallel Reduction）
    // 这里简化实现，实际应使用 threadgroup 内存优化

    if (gid >= total_pixels) return;

    // 原子累加收敛像素数
    if (converged_flags[gid] == 1) {
        atomic_fetch_add_explicit(&global_stats->totalConvergedPixels, 1, memory_order_relaxed);
    }

    // 累加总采样数
    atomic_fetch_add_explicit(&global_stats->totalSamplesUsed, uint64_t(sample_count[gid]), memory_order_relaxed);

    // 计算最大方差（简化版，实际应使用规约）
    float var = variance[gid];
    // 注意：这里需要原子 max 操作，Metal 3.0+ 支持
    // atomic_fetch_max_explicit(&global_stats->maxVariance, var, memory_order_relaxed);
}

/// 压缩未收敛像素列表（Stream Compaction）
kernel void compact_unconverged_pixels(
    device const uint* converged_flags [[buffer(0)]],
    device uint* unconverged_list [[buffer(1)]],        // 输出：未收敛像素索引
    device atomic_uint* unconverged_counter [[buffer(2)]],  // 输出计数
    constant uint& total_pixels [[buffer(3)]],
    uint gid [[thread_position_in_grid]]
) {
    if (gid >= total_pixels) return;

    // 如果未收敛，加入列表
    if (converged_flags[gid] == 0) {
        uint idx = atomic_fetch_add_explicit(unconverged_counter, 1, memory_order_relaxed);
        unconverged_list[idx] = gid;
    }
}
```

### 2.2 辅助函数

```metal
/// 计算像素的感知亮度（用于自适应阈值）
inline float luminance(float3 color) {
    return 0.299f * color.r + 0.587f * color.g + 0.114f * color.b;
}

/// 相对方差（归一化）
inline float relative_variance(float3 variance, float3 mean) {
    float lum_variance = luminance(variance);
    float lum_mean = luminance(mean);

    if (lum_mean < 1e-6f) return 0.0f;

    return sqrt(lum_variance) / lum_mean;  // 相对标准差
}
```

---

## 三、实施步骤

### 阶段 1: 基础架构（Day 1）

#### 任务 1.1: 创建数据结构 ✅

1. **新增 GPU 结构体**
   - 文件: `Sources/GPU/GPUStructs.swift`
   - 添加: `AdaptiveSamplingBuffers`, `AdaptiveGlobalStats`

2. **Metal 结构体**
   - 文件: `Shaders/Common/Types.metal`
   - 添加: `AdaptiveSamplingParams`

#### 任务 1.2: 创建 AdaptiveRenderer 类 ✅

```swift
// Sources/Rendering/AdaptiveRenderer.swift
import Foundation
import Metal

class AdaptiveRenderer {
    let context: MetalContext
    let baseRenderer: Renderer
    var buffers: AdaptiveSamplingBuffers

    // Pipeline states
    var computeVariancePipeline: MTLComputePipelineState
    var accumulateSamplesPipeline: MTLComputePipelineState
    var compactUnconvergedPipeline: MTLComputePipelineState

    init(context: MetalContext, baseRenderer: Renderer) {
        self.context = context
        self.baseRenderer = baseRenderer

        // 创建 compute pipelines
        self.computeVariancePipeline = context.makeComputePipeline(function: "compute_variance")!
        self.accumulateSamplesPipeline = context.makeComputePipeline(function: "accumulate_samples")!
        self.compactUnconvergedPipeline = context.makeComputePipeline(function: "compact_unconverged_pixels")!

        // 初始化缓冲区（延迟到 render 调用）
        self.buffers = AdaptiveSamplingBuffers()
    }
}
```

### 阶段 2: 核心算法（Day 2-3）

#### 任务 2.1: 实现方差计算 ✅

1. **编写 Metal Shader**
   - 文件: `Shaders/Kernels/AdaptiveSampling.metal`（新建）
   - 实现: `compute_variance` 内核

2. **Swift 端调用**
   ```swift
   func computeVariance() {
       guard let commandBuffer = context.commandQueue.makeCommandBuffer(),
             let encoder = commandBuffer.makeComputeCommandEncoder() else {
           return
       }

       encoder.setComputePipelineState(computeVariancePipeline)
       encoder.setBuffer(buffers.colorSumBuffer, offset: 0, index: 0)
       encoder.setBuffer(buffers.colorSumSquaredBuffer, offset: 0, index: 1)
       encoder.setBuffer(buffers.sampleCountBuffer, offset: 0, index: 2)
       encoder.setBuffer(buffers.varianceBuffer, offset: 0, index: 3)
       encoder.setBuffer(buffers.convergedFlagBuffer, offset: 0, index: 4)
       var params = adaptiveParams
       encoder.setBytes(&params, length: MemoryLayout<AdaptiveSamplingParams>.stride, index: 5)

       let threadsPerGrid = MTLSize(width: imageWidth, height: imageHeight, depth: 1)
       let threadsPerThreadgroup = MTLSize(width: 16, height: 16, depth: 1)
       encoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)

       encoder.endEncoding()
       commandBuffer.commit()
       commandBuffer.waitUntilCompleted()
   }
   ```

#### 任务 2.2: 实现累积逻辑 ✅

1. **编写 `accumulate_samples` 内核**（已在 2.1 中）
2. **Swift 端集成**
   ```swift
   func accumulateToAdaptiveBuffers(texture: MTLTexture, spp: UInt32, mask: MTLBuffer? = nil) {
       guard let commandBuffer = context.commandQueue.makeCommandBuffer(),
             let encoder = commandBuffer.makeComputeCommandEncoder() else {
           return
       }

       encoder.setComputePipelineState(accumulateSamplesPipeline)
       encoder.setTexture(texture, index: 0)
       encoder.setBuffer(buffers.colorSumBuffer, offset: 0, index: 0)
       encoder.setBuffer(buffers.colorSumSquaredBuffer, offset: 0, index: 1)
       encoder.setBuffer(buffers.sampleCountBuffer, offset: 0, index: 2)
       if let mask = mask {
           encoder.setBuffer(mask, offset: 0, index: 3)
       }
       var sppValue = spp
       encoder.setBytes(&sppValue, length: MemoryLayout<UInt32>.stride, index: 4)

       // ... dispatch ...

       encoder.endEncoding()
       commandBuffer.commit()
       commandBuffer.waitUntilCompleted()
   }
   ```

#### 任务 2.3: 实现未收敛像素列表 ✅

1. **编写 `compact_unconverged_pixels` 内核**（已在 2.1 中）
2. **Swift 端提取列表**
   ```swift
   func getUnconvergedPixels() -> [UInt32] {
       // 重置计数器
       let counterBuffer = context.device.makeBuffer(
           length: MemoryLayout<UInt32>.stride,
           options: .storageModeShared
       )!
       counterBuffer.contents().storeBytes(of: UInt32(0), as: UInt32.self)

       // 执行压缩
       guard let commandBuffer = context.commandQueue.makeCommandBuffer(),
             let encoder = commandBuffer.makeComputeCommandEncoder() else {
           return []
       }

       encoder.setComputePipelineState(compactUnconvergedPipeline)
       encoder.setBuffer(buffers.convergedFlagBuffer, offset: 0, index: 0)
       encoder.setBuffer(unconvergedListBuffer, offset: 0, index: 1)
       encoder.setBuffer(counterBuffer, offset: 0, index: 2)
       var totalPixels = UInt32(imageWidth * imageHeight)
       encoder.setBytes(&totalPixels, length: MemoryLayout<UInt32>.stride, index: 3)

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
   ```

### 阶段 3: 集成与优化（Day 4）

#### 任务 3.1: 集成到 main.swift ✅

```swift
// Sources/main.swift

// 解析命令行参数
var useAdaptiveSampling = false
var adaptiveMinSamples = 16
var adaptiveMaxSamples = 1024
var adaptiveVarianceThreshold: Float = 0.0001
var adaptiveBatchSize = 8

// 添加新参数
if CommandLine.arguments.contains("--adaptive") {
    useAdaptiveSampling = true
}
if let idx = CommandLine.arguments.firstIndex(of: "--adaptive-min-spp"),
   idx + 1 < CommandLine.arguments.count {
    adaptiveMinSamples = Int(CommandLine.arguments[idx + 1]) ?? 16
}
// ... 其他参数 ...

// 渲染
if useAdaptiveSampling {
    print("Using Adaptive Sampling:")
    print("  Min SPP: \(adaptiveMinSamples)")
    print("  Max SPP: \(adaptiveMaxSamples)")
    print("  Variance Threshold: \(adaptiveVarianceThreshold)")

    let adaptiveRenderer = AdaptiveRenderer(context: metalContext, baseRenderer: renderer)

    let (pixels, renderTime, stats) = adaptiveRenderer.renderAdaptive(
        scene: scene,
        camera: camera,
        bvh: bvh,
        minSamples: adaptiveMinSamples,
        maxSamples: adaptiveMaxSamples,
        varianceThreshold: adaptiveVarianceThreshold,
        batchSize: adaptiveBatchSize,
        progressCallback: { progress in
            print("  Iteration \(progress.iteration): \(progress.convergedPixels)/\(progress.totalPixels) pixels converged (avg \(String(format: "%.1f", progress.averageSpp)) spp)")
        }
    )

    print("\nAdaptive Sampling Statistics:")
    print("  Total Render Time: \(String(format: "%.2f", renderTime * 1000)) ms")
    print("  Average SPP: \(String(format: "%.1f", stats.averageSpp))")
    print("  SPP Distribution:")
    print("    Min: \(stats.minSpp)")
    print("    25%: \(stats.percentile25Spp)")
    print("    50%: \(stats.percentile50Spp)")
    print("    75%: \(stats.percentile75Spp)")
    print("    Max: \(stats.maxSpp)")
    print("  Samples Saved: \(String(format: "%.1f%%", stats.samplesSavedPercent * 100))")

    // 写入图片
    writeImage(pixels, width: camera.imageWidth, height: camera.imageHeight, filename: args.output)
} else {
    // 传统固定采样渲染
    // ...
}
```

#### 任务 3.2: 性能优化 ✅

1. **批次大小调优**
   - 测试不同 `batchSize`: 4, 8, 16
   - 平衡：批次太小 → 频繁计算方差（开销大）
   - 批次太大 → 浪费采样（某些像素可能提前收敛）
   - **推荐**: 8

2. **方差阈值调优**
   - 过高（如 0.001）→ 提前停止，图像有噪点
   - 过低（如 0.00001）→ 过度采样，节省不明显
   - **推荐**: 0.0001（或相对误差 1%）

3. **内存优化**
   - 使用 `storageModePrivate` 存储中间缓冲区（GPU 独占，更快）
   - 像素掩码使用位图（1 bit per pixel）而不是 uint 数组（节省 32× 内存）

### 阶段 4: 测试与验证（Day 5）

#### 任务 4.1: 基准测试 ✅

**测试脚本** (`tests/test_adaptive_sampling.sh`):
```bash
#!/bin/bash

echo "=== Adaptive Sampling Benchmark ==="

# 场景列表
scenes=("cornellBox" "bouncingSpheres" "finalScene")

for scene in "${scenes[@]}"; do
    echo ""
    echo "Testing scene: $scene"

    # 1. 传统固定采样 (100 spp)
    echo "  [1/3] Traditional (100 spp)..."
    time swift run -c release raytracer \
        --mode image \
        --scene $scene \
        --spp 100 \
        --output "output/${scene}_traditional.ppm" \
        2>&1 | grep "Render time:"

    # 2. 自适应采样（默认参数）
    echo "  [2/3] Adaptive (default)..."
    time swift run -c release raytracer \
        --mode image \
        --scene $scene \
        --adaptive \
        --adaptive-min-spp 16 \
        --adaptive-max-spp 1024 \
        --adaptive-threshold 0.0001 \
        --output "output/${scene}_adaptive.ppm" \
        2>&1 | grep -E "(Render time:|Average SPP:|Samples Saved:)"

    # 3. 自适应采样（激进参数，更大阈值）
    echo "  [3/3] Adaptive (aggressive)..."
    time swift run -c release raytracer \
        --mode image \
        --scene $scene \
        --adaptive \
        --adaptive-min-spp 16 \
        --adaptive-max-spp 1024 \
        --adaptive-threshold 0.0005 \
        --output "output/${scene}_adaptive_aggressive.ppm" \
        2>&1 | grep -E "(Render time:|Average SPP:|Samples Saved:)"
done

echo ""
echo "=== Image Quality Comparison ==="
echo "Please visually compare the output images in output/ directory"
```

#### 任务 4.2: 质量验证 ✅

**生成采样热力图**:
```swift
// Sources/Utils/HeatmapGenerator.swift (新文件)
import Foundation

struct HeatmapGenerator {
    /// 生成 SPP 热力图（用于可视化自适应采样分布）
    static func generateSppHeatmap(
        sampleCounts: [UInt32],
        width: Int,
        height: Int,
        outputPath: String
    ) {
        var pixels = [Float](repeating: 0, count: width * height * 3)

        let maxSpp = sampleCounts.max() ?? 1

        for y in 0..<height {
            for x in 0..<width {
                let idx = y * width + x
                let spp = sampleCounts[idx]

                // 颜色映射：蓝色（低 SPP）→ 绿色 → 红色（高 SPP）
                let normalized = Float(spp) / Float(maxSpp)
                let pixelIdx = idx * 3

                if normalized < 0.5 {
                    // 蓝色 → 绿色
                    pixels[pixelIdx + 0] = 0.0
                    pixels[pixelIdx + 1] = normalized * 2.0
                    pixels[pixelIdx + 2] = (1.0 - normalized * 2.0)
                } else {
                    // 绿色 → 红色
                    pixels[pixelIdx + 0] = (normalized - 0.5) * 2.0
                    pixels[pixelIdx + 1] = (1.0 - (normalized - 0.5) * 2.0)
                    pixels[pixelIdx + 2] = 0.0
                }
            }
        }

        // 写入 PPM
        ImageWriter.write(pixels: pixels, width: width, height: height, to: outputPath)
    }
}
```

**使用**:
```swift
// 在 AdaptiveRenderer.renderAdaptive() 结束时
HeatmapGenerator.generateSppHeatmap(
    sampleCounts: readSampleCounts(),
    width: camera.imageWidth,
    height: camera.imageHeight,
    outputPath: "output/adaptive_heatmap.ppm"
)
```

#### 任务 4.3: 回归测试 ✅

**验证图像一致性**:
```bash
# 渲染参考图像（高 spp 固定采样）
swift run -c release raytracer --scene cornellBox --spp 1000 --output reference.ppm

# 渲染自适应图像（期望质量相当）
swift run -c release raytracer --scene cornellBox --adaptive --adaptive-max-spp 1000 --output adaptive.ppm

# 计算 MSE（需要 Python + numpy）
python3 scripts/compare_images.py reference.ppm adaptive.ppm
```

**Python 脚本** (`scripts/compare_images.py`):
```python
import numpy as np
import sys

def load_ppm(filename):
    with open(filename, 'rb') as f:
        # 跳过 PPM 头
        header = f.readline()
        assert header == b'P6\n'
        dims = f.readline().decode().split()
        width, height = int(dims[0]), int(dims[1])
        maxval = int(f.readline())

        # 读取像素数据
        pixels = np.fromfile(f, dtype=np.uint8).reshape(height, width, 3)
        return pixels.astype(np.float32) / 255.0

def compute_mse(img1, img2):
    diff = img1 - img2
    mse = np.mean(diff ** 2)
    return mse

def compute_psnr(mse):
    if mse < 1e-10:
        return 100.0
    return 10 * np.log10(1.0 / mse)

if __name__ == '__main__':
    ref = load_ppm(sys.argv[1])
    test = load_ppm(sys.argv[2])

    mse = compute_mse(ref, test)
    psnr = compute_psnr(mse)

    print(f"MSE: {mse:.6f}")
    print(f"PSNR: {psnr:.2f} dB")

    # 判断通过条件
    if mse < 0.001:  # MSE < 0.1%
        print("✅ PASS: Images are visually identical")
    elif mse < 0.01:  # MSE < 1%
        print("⚠️ WARNING: Minor differences detected")
    else:
        print("❌ FAIL: Significant differences detected")
        sys.exit(1)
```

---

## 四、预期效果与性能分析

### 4.1 Cornell Box (600×600, 目标 100 spp)

**传统固定采样**:
```
所有像素: 100 spp
总采样数: 600 × 600 × 100 = 36M
渲染时间: 329 ms
```

**自适应采样**（预测）:
```
像素分布（基于方差分析）:
  白色墙壁 (60%): 20 spp
  红色/绿色墙壁 (20%): 30 spp
  阴影区域 (10%): 80 spp
  玻璃球边缘 (5%): 200 spp
  镜面盒子反射 (5%): 150 spp

平均 spp: 0.6×20 + 0.2×30 + 0.1×80 + 0.05×200 + 0.05×150 = 41 spp
总采样数: 600 × 600 × 41 = 14.8M
节省: (36M - 14.8M) / 36M = 59%

渲染时间: 329 × 0.41 + 开销 ≈ 180 ms
加速比: 1.83×
```

### 4.2 Bouncing Spheres (800×450, 目标 10 spp)

**传统固定采样**:
```
总采样数: 800 × 450 × 10 = 3.6M
渲染时间: 82 ms
```

**自适应采样**（预测）:
```
像素分布:
  天空背景 (40%): 4 spp
  球体表面 (50%): 10 spp
  球体边缘/接触阴影 (10%): 20 spp

平均 spp: 0.4×4 + 0.5×10 + 0.1×20 = 8.6 spp
总采样数: 800 × 450 × 8.6 = 3.1M
节省: 14%

渲染时间: 82 × 0.86 + 开销 ≈ 75 ms
加速比: 1.09× (提升不明显，因为场景方差分布较均匀)
```

### 4.3 Final Scene (400×400, 目标 10 spp)

**传统固定采样**:
```
总采样数: 400 × 400 × 10 = 1.6M
渲染时间: 60 ms
```

**自适应采样**（预测）:
```
像素分布:
  远景天空/地面 (70%): 5 spp
  球体/四边形 (25%): 10 spp
  高方差区域 (5%): 20 spp

平均 spp: 0.7×5 + 0.25×10 + 0.05×20 = 6.5 spp
总采样数: 400 × 400 × 6.5 = 1.04M
节省: 35%

渲染时间: 60 × 0.65 + 开销 ≈ 42 ms
加速比: 1.43×
```

### 4.4 开销分析

**自适应采样额外开销**:
```
1. 方差计算: ~2-3 ms (每次迭代)
2. 未收敛像素压缩: ~1 ms (每次迭代)
3. 全局统计更新: ~0.5 ms (每次迭代)

迭代次数 (batchSize=8):
  Cornell Box: (100-16)/8 ≈ 10 次
  总开销: 10 × (2+1+0.5) = 35 ms

开销占比: 35 / 180 = 19%
```

---

## 五、命令行参数

### 5.1 基本参数

```bash
# 启用自适应采样
--adaptive

# 最小采样数（初始均匀采样）
--adaptive-min-spp <N>
# 默认: 16
# 推荐范围: 8-32

# 最大采样数（上限）
--adaptive-max-spp <N>
# 默认: 1024
# 推荐: 等于传统模式的 --spp

# 方差阈值（绝对值）
--adaptive-threshold <float>
# 默认: 0.0001
# 更小 = 更高质量，更多采样
# 更大 = 更快渲染，可能有噪点

# 相对误差阈值（百分比）
--adaptive-relative-error <float>
# 默认: 0.01 (1%)
# 自适应阈值 = (relative_error × luminance)²
```

### 5.2 高级参数

```bash
# 批次大小（每次迭代增量）
--adaptive-batch-size <N>
# 默认: 8
# 更小 = 更精确控制，更多开销
# 更大 = 更少迭代，可能浪费采样

# 生成 SPP 热力图
--adaptive-heatmap <filename>
# 输出采样分布可视化图像

# 导出统计数据
--adaptive-stats <filename>
# 输出 JSON 格式统计信息
```

### 5.3 使用示例

```bash
# 基本使用（默认参数）
swift run raytracer --adaptive --scene cornellBox --output adaptive.ppm

# 自定义参数
swift run raytracer \
    --adaptive \
    --adaptive-min-spp 32 \
    --adaptive-max-spp 512 \
    --adaptive-threshold 0.0002 \
    --adaptive-batch-size 16 \
    --scene cornellBox \
    --output adaptive.ppm

# 生成热力图
swift run raytracer \
    --adaptive \
    --scene cornellBox \
    --adaptive-heatmap heatmap.ppm \
    --output adaptive.ppm

# 激进模式（快速预览）
swift run raytracer \
    --adaptive \
    --adaptive-min-spp 8 \
    --adaptive-max-spp 64 \
    --adaptive-relative-error 0.05 \
    --scene cornellBox \
    --output preview.ppm

# 高质量模式
swift run raytracer \
    --adaptive \
    --adaptive-min-spp 32 \
    --adaptive-max-spp 2048 \
    --adaptive-relative-error 0.005 \
    --scene cornellBox \
    --output final.ppm
```

---

## 六、常见问题与调试

### Q1: 为什么某些像素采样数异常高？

**原因**:
- 玻璃/镜面材质边缘天然高方差（焦散效应）
- 阴影边界抗锯齿需求
- 纹理细节（如棋盘格边缘）

**解决方案**:
- 正常现象，说明自适应采样正确识别高方差区域
- 可以设置 `--adaptive-max-spp` 限制上限

### Q2: 渲染时间没有明显减少？

**可能原因**:
1. **场景方差分布均匀**（如 Bouncing Spheres）
   - 所有像素都需要类似采样数
   - 自适应采样收益有限

2. **阈值设置过低**
   - 导致大部分像素达到 `max_spp`
   - 调整: 增大 `--adaptive-threshold` 或 `--adaptive-relative-error`

3. **批次大小过小**
   - 频繁计算方差，开销大
   - 调整: 增大 `--adaptive-batch-size` (如 16)

### Q3: 图像质量下降，有明显噪点？

**原因**: 阈值设置过高，过早停止采样

**解决方案**:
```bash
# 降低阈值
--adaptive-threshold 0.00005  # 原来 0.0001

# 或降低相对误差
--adaptive-relative-error 0.005  # 原来 0.01

# 或增加最小采样数
--adaptive-min-spp 32  # 原来 16
```

### Q4: 如何验证自适应采样的正确性？

**验证步骤**:
1. 渲染参考图像（高 spp 固定采样）
   ```bash
   swift run raytracer --scene cornellBox --spp 1000 --output reference.ppm
   ```

2. 渲染自适应图像（相同最大 spp）
   ```bash
   swift run raytracer --scene cornellBox --adaptive --adaptive-max-spp 1000 --output adaptive.ppm
   ```

3. 对比图像（使用 Python 脚本）
   ```bash
   python3 scripts/compare_images.py reference.ppm adaptive.ppm
   ```

4. 生成热力图，检查采样分布是否合理
   ```bash
   swift run raytracer --scene cornellBox --adaptive --adaptive-heatmap heatmap.ppm
   ```

---

## 七、后续优化方向

### 7.1 与其他技术结合

**自适应采样 + Wavefront**:
- Wavefront 提高 GPU 利用率
- 自适应采样减少总采样数
- **叠加收益**: -70% ~ -85% 渲染时间

**自适应采样 + BDPT**:
- BDPT 加速收敛（减少方差）
- 自适应采样更快识别收敛像素
- **叠加收益**: 收敛速度 5-10×

### 7.2 高级自适应策略

**多层次自适应**:
```
Level 1: 像素级（当前实现）
Level 2: 路径深度级（不同深度不同采样数）
Level 3: 材质级（漫反射少采样，镜面多采样）
```

**机器学习辅助**:
- 使用神经网络预测像素方差
- 提前分配采样资源
- 减少初始均匀采样的开销

---

## 八、总结

### 8.1 核心优势

✅ **实施简单**: 3-5 天即可完成
✅ **立即见效**: 首个测试就能看到 30-60% 性能提升
✅ **低风险**: 不影响现有架构，可以随时回退
✅ **普适性强**: 适用所有场景（收益因场景而异）
✅ **可扩展**: 为后续优化（Wavefront/BDPT）打基础

### 8.2 预期成果

**性能提升**:
- Cornell Box: **-59% 渲染时间** (329 ms → 180 ms)
- Bouncing Spheres: **-14% 渲染时间** (82 ms → 75 ms)
- Final Scene: **-35% 渲染时间** (60 ms → 42 ms)

**平均收益**: **-30% ~ -60%**（取决于场景方差分布）

### 8.3 下一步行动

1. **Day 1**: 创建数据结构 + AdaptiveRenderer 框架
2. **Day 2-3**: 实现核心算法（方差计算 + 累积逻辑）
3. **Day 4**: 集成到 main.swift + 参数解析
4. **Day 5**: 测试、验证、优化

**准备好开始实施了吗？** 🚀

---

**文档版本**: v1.0
**创建日期**: 2025-12-11
**预计完成**: 2025-12-15
**状态**: 设计完成，待实施
