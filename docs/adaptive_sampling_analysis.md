# 自适应采样渲染流程分析与优化方案

## 一、当前渲染流程总结

### Phase 1: 初始均匀采样（所有像素）

**目标**: 确保所有像素至少达到 `minSpp` 次采样

**流程**:
1. **渲染阶段** (`renderToTexture`):
   - 调用 `raytrace` kernel，对所有像素进行光线追踪
   - 每个像素采样 `batchSize` 次（通常 8 次）
   - 输出到临时纹理 `batchTexture`

2. **累积阶段** (`accumulate_samples`):
   - 读取 `batchTexture` 的所有像素
   - 累积到 `colorSumBuffer`（颜色总和）
   - 累积到 `colorSumSquaredBuffer`（颜色平方和，用于方差计算）
   - 更新 `sampleCountBuffer`（采样计数）
   - **关键**: `pixelMaskBuffer = nil`，表示所有像素都累积

3. **迭代**: 重复直到所有像素达到 `minSpp`

**资源消耗**: 
- GPU 计算: `width × height × minSpp` 次光线追踪
- 内存: 累积缓冲区（colorSum, colorSumSquared, sampleCount）

---

### Phase 2: 自适应采样（仅未收敛像素）

**目标**: 将剩余预算分配给高方差像素

**流程**:

1. **方差计算** (`compute_variance`):
   ```metal
   // 对每个像素：
   - 计算均值: mean = colorSum / sampleCount
   - 计算方差: variance = E[X²] - E[X]²
   - 应用批量采样校正因子
   - 判断收敛: variance < threshold && sampleCount >= minSamples
   ```

2. **未收敛像素压缩** (`compact_unconverged_pixels`):
   - 使用 Stream Compaction 算法
   - 遍历所有像素，将 `convergedFlag == 0` 的像素索引写入 `unconvergedListBuffer`
   - 使用原子计数器统计未收敛像素数量

3. **创建像素掩码** (`createPixelMask` - CPU 端):
   ```swift
   // 在 CPU 端设置掩码
   for pixelIdx in unconvergedList {
       pixelMaskBuffer[pixelIdx] = 1  // 标记需要采样
   }
   ```

4. **渲染阶段** (`renderToTexture`):
   - ⚠️ **问题**: 仍然调用 `raytrace` kernel 渲染**整个图像**
   - GPU 对所有像素进行光线追踪，包括已收敛的像素
   - 输出到 `batchTexture`

5. **累积阶段** (`accumulate_samples`):
   ```metal
   // 检查像素掩码
   if (pixel_mask != nullptr && pixel_mask[pixel_idx] == 0) {
       return;  // 跳过已收敛像素的累积
   }
   // 只累积未收敛像素的结果
   ```
   - 通过掩码跳过已收敛像素的累积
   - 只更新未收敛像素的统计信息

6. **迭代**: 重复直到预算耗尽或所有像素收敛

---

## 二、Phase 2 的资源浪费分析

### 当前实现的效率问题

**核心问题**: Phase 2 中，`renderToTexture` 仍然渲染整个图像，包括已收敛的像素。

**浪费计算量**:
```
假设: 600×600 图像，50% 像素已收敛
- 实际需要: 180,000 像素 × 8 spp = 1,440,000 次光线追踪
- 实际执行: 360,000 像素 × 8 spp = 2,880,000 次光线追踪
- 浪费率: 50%
```

**为什么这样设计**:
1. `raytrace` kernel 不支持像素掩码参数
2. GPU 并行架构：跳过像素需要条件分支，可能降低性能
3. 实现简单：只需在累积阶段过滤，不需要修改渲染内核

**实际影响**:
- 随着收敛像素增加，浪费率线性增长
- 在后期迭代中，可能 80-90% 的计算都是浪费的
- 但 GPU 的 SIMD 特性使得"跳过"的开销可能小于"不渲染"的开销

---

## 三、优化方案

### 方案 1: 在渲染内核中添加像素掩码支持（推荐）

**实现**:
1. 修改 `raytrace` kernel，添加可选的像素掩码参数
2. 在 kernel 开始处检查掩码，如果像素已收敛则直接返回

**代码修改**:
```metal
kernel void raytrace(
    texture2d<float, access::read_write> output [[texture(0)]],
    // ... 其他参数 ...
    device const uint* pixel_mask [[buffer(14)]],  // 新增：像素掩码（可选）
    uint2 gid [[thread_position_in_grid]]
) {
    // 边界检查
    if (gid.x >= params.width || gid.y >= params.height) return;
    
    uint pixel_idx = gid.y * params.width + gid.x;
    
    // 像素掩码检查（如果提供）
    if (pixel_mask != nullptr && pixel_mask[pixel_idx] == 0) {
        // 像素已收敛，跳过渲染
        // 保持之前累积的颜色不变
        return;
    }
    
    // 正常渲染流程...
}
```

**优点**:
- ✅ 直接跳过已收敛像素的光线追踪
- ✅ 节省 GPU 计算资源
- ✅ 在后期迭代中效果显著（收敛像素多）

**缺点**:
- ⚠️ 需要修改核心渲染内核
- ⚠️ GPU 分支可能影响 SIMD 效率（但通常仍比渲染更高效）

**预期收益**:
- 在 50% 收敛时节省 ~50% 计算
- 在 80% 收敛时节省 ~80% 计算

---

### 方案 2: 使用间接渲染（Indirect Rendering）

**实现**:
1. 将未收敛像素索引打包成紧凑列表
2. 使用 `dispatchThreads` 的间接模式，只对未收敛像素启动线程

**代码修改**:
```swift
// 创建间接命令缓冲区
let indirectBuffer = device.makeBuffer(
    length: MemoryLayout<MTLDispatchThreadgroupsIndirectArguments>.stride,
    options: .storageModeShared
)

// 设置间接参数
var args = MTLDispatchThreadgroupsIndirectArguments()
args.threadgroupsPerGrid[0] = (unconvergedCount + 255) / 256
args.threadgroupsPerGrid[1] = 1
args.threadgroupsPerGrid[2] = 1
indirectBuffer.contents().storeBytes(of: args, as: MTLDispatchThreadgroupsIndirectArguments.self)

// 使用间接调度
encoder.dispatchThreadgroups(indirectBuffer, threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
```

**优点**:
- ✅ 完全跳过已收敛像素的线程启动
- ✅ 更符合 GPU 并行架构

**缺点**:
- ⚠️ Metal 的间接调度支持有限
- ⚠️ 需要重新组织渲染逻辑（按像素索引而非坐标）

---

### 方案 3: 分块渲染（Tile-based Rendering）

**实现**:
1. 将图像分成 16×16 或 32×32 的块（tiles）
2. 统计每个块中未收敛像素的比例
3. 如果块中所有像素都已收敛，跳过整个块的渲染

**代码修改**:
```swift
// 计算每个块的收敛状态
let tileSize = 32
let tilesX = (width + tileSize - 1) / tileSize
let tilesY = (height + tileSize - 1) / tileSize

// 创建块掩码
let tileMask = device.makeBuffer(length: tilesX * tilesY * MemoryLayout<UInt32>.stride, ...)
// 统计每个块的未收敛像素数
computeTileMask(convergedFlags, tileMask, width, height, tileSize)

// 渲染时检查块掩码
// 如果块已收敛，跳过该块的所有像素
```

**优点**:
- ✅ 减少分支开销（块级而非像素级）
- ✅ 更好的缓存局部性
- ✅ 实现相对简单

**缺点**:
- ⚠️ 如果块中只有少数像素未收敛，仍会渲染整个块
- ⚠️ 需要额外的块掩码计算

**预期收益**:
- 在 80% 收敛时节省 ~60-70% 计算（取决于块大小）

---

### 方案 4: 动态批次大小调整

**实现**:
1. 根据未收敛像素比例动态调整批次大小
2. 如果未收敛像素很少，使用更小的批次，减少浪费

**代码修改**:
```swift
let unconvergedRatio = Float(unconvergedPixels.count) / Float(totalPixels)
let adaptiveBatchSize = max(1, Int(Float(batchSize) * unconvergedRatio))
```

**优点**:
- ✅ 实现简单
- ✅ 减少后期迭代的浪费

**缺点**:
- ⚠️ 不能完全消除浪费
- ⚠️ 小批次可能降低 GPU 利用率

---

### 方案 5: 混合策略（推荐组合）

**组合方案**:
1. **短期**: 实现方案 1（像素掩码支持）
   - 快速实现，直接收益
   - 在渲染内核开始处检查掩码

2. **中期**: 添加方案 3（分块渲染）
   - 进一步优化，减少分支开销
   - 结合块掩码和像素掩码

3. **长期**: 考虑方案 2（间接渲染）
   - 如果 Metal 支持改进，可以完全跳过线程启动

---

## 四、其他优化建议

### 1. 方差计算优化

**当前问题**: 每次迭代都重新计算所有像素的方差

**优化**:
- 只对未收敛像素重新计算方差
- 已收敛像素的方差不再变化，可以缓存

```metal
// 在 compute_variance 中
if (converged_flags[pixel_idx] == 1) {
    // 已收敛，跳过计算
    return;
}
```

### 2. 采样数分配策略优化

**当前策略**: 所有未收敛像素分配相同的采样数

**优化策略**: 根据方差大小分配采样数
- 高方差像素分配更多采样
- 低方差像素分配较少采样

```swift
// 根据方差排序未收敛像素
let sortedPixels = unconvergedPixels.sorted { variance[$0] > variance[$1] }

// 分配采样数
for (idx, pixelIdx) in sortedPixels.enumerated() {
    let varianceLevel = variance[pixelIdx]
    let samples = varianceLevel > highThreshold ? batchSize * 2 : batchSize
    // ...
}
```

### 3. 预算分配优化

**当前问题**: 预算分配可能不均匀

**优化**:
- 使用优先级队列，优先分配高方差像素
- 动态调整每轮分配的预算比例

### 4. 内存优化

**当前缓冲区**:
- `colorSumBuffer`: `width × height × 16 bytes`
- `colorSumSquaredBuffer`: `width × height × 16 bytes`
- `sampleCountBuffer`: `width × height × 4 bytes`
- `varianceBuffer`: `width × height × 4 bytes`
- `convergedFlagBuffer`: `width × height × 4 bytes`
- `unconvergedListBuffer`: `width × height × 4 bytes`
- `pixelMaskBuffer`: `width × height × 4 bytes`

**优化**:
- `unconvergedListBuffer` 可以动态分配（根据实际未收敛像素数）
- `varianceBuffer` 可以只在需要时分配
- 使用 `storageModePrivate` 而非 `storageModeShared`（如果不需要 CPU 访问）

### 5. 并行度优化

**当前**: 每次迭代串行执行（渲染 → 累积 → 方差计算 → 压缩）

**优化**:
- 使用多个 command buffer 并行执行
- 下一轮的渲染可以与当前轮的方差计算并行

---

## 五、性能预期

### 当前实现（无优化）
- Phase 1: 100% 计算（必需）
- Phase 2: 假设 50% 收敛，浪费 50% 计算
- **总效率**: ~75% 有效计算

### 方案 1（像素掩码）
- Phase 1: 100% 计算
- Phase 2: 假设 50% 收敛，节省 50% 计算
- **总效率**: ~87.5% 有效计算
- **加速比**: 1.17x

### 方案 3（分块渲染）
- Phase 1: 100% 计算
- Phase 2: 假设 50% 收敛，节省 ~40% 计算（块级浪费）
- **总效率**: ~85% 有效计算
- **加速比**: 1.13x

### 组合方案（方案 1 + 方案 3）
- Phase 1: 100% 计算
- Phase 2: 假设 50% 收敛，节省 ~60% 计算
- **总效率**: ~90% 有效计算
- **加速比**: 1.25x

---

## 六、实施优先级

1. **P0（立即实施）**: 方案 1 - 像素掩码支持
   - 实现简单，收益明显
   - 修改 `raytrace` kernel 和 `renderToTexture`

2. **P1（短期）**: 方差计算优化
   - 只计算未收敛像素的方差
   - 减少计算量

3. **P2（中期）**: 方案 3 - 分块渲染
   - 进一步优化，减少分支开销

4. **P3（长期）**: 采样数分配策略优化
   - 根据方差动态分配采样数
   - 更智能的预算分配

---

## 七、总结

当前自适应采样实现的核心问题是在 Phase 2 中仍然渲染整个图像，导致已收敛像素的计算浪费。通过添加像素掩码支持，可以直接跳过已收敛像素的光线追踪，显著提升效率。结合分块渲染和其他优化，可以进一步提升性能。

**关键洞察**: 
- 当前实现通过掩码在累积阶段过滤，但渲染阶段仍然浪费
- GPU 的 SIMD 特性使得"跳过渲染"的开销通常小于"渲染但不累积"
- 在后期迭代中（收敛像素多），优化效果最明显

