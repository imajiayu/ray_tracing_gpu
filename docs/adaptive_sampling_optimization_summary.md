# 自适应采样功能全面重构与优化总结

## 一、已实施的优化

### ✅ 1. 像素掩码支持（方案1 - P0）

**问题**: Phase 2 中仍然渲染整个图像，包括已收敛的像素，造成 50-90% 的计算浪费。

**解决方案**:
- 在 `raytrace` kernel 中添加可选的 `pixel_mask` 参数
- 在渲染开始处检查掩码，如果像素已收敛则直接返回
- Phase 2 渲染时传入像素掩码，只对未收敛像素进行光线追踪

**代码修改**:
- `Shaders/Kernels/RayTracing.metal`: 添加 `pixel_mask` 参数和检查逻辑
- `Sources/Rendering/Renderer.swift`: `renderToTexture` 添加 `pixelMask` 参数
- `Sources/Rendering/AdaptiveRenderer.swift`: Phase 2 传入 `pixelMaskBuffer`

**预期收益**:
- 在 50% 收敛时节省 ~50% 计算
- 在 80% 收敛时节省 ~80% 计算
- **加速比**: 1.17x - 1.5x（取决于收敛率）

---

### ✅ 2. 方差计算优化（P1）

**问题**: 每次迭代都重新计算所有像素的方差，包括已收敛的像素。

**解决方案**:
- 在 `compute_variance` kernel 中添加收敛检查
- 如果像素已收敛（`converged_flags[pixel_idx] == 1`），跳过方差计算
- 已收敛像素的方差不再变化，可以缓存

**代码修改**:
- `Shaders/Kernels/AdaptiveSampling.metal`: 在方差计算开始处添加收敛检查

**预期收益**:
- 减少 20-30% 的方差计算开销
- 在后期迭代中（收敛像素多），效果更明显

---

### ✅ 3. GPU 端像素掩码操作（P2）

**问题**: 像素掩码的创建和重置在 CPU 端执行，效率较低。

**解决方案**:
- 添加 `reset_pixel_mask` kernel，在 GPU 端重置掩码
- 添加 `create_pixel_mask` GPU 版本（已存在，现在使用）
- 添加 `initialize_buffers` kernel，初始化 GPU 缓冲区

**代码修改**:
- `Shaders/Kernels/AdaptiveSampling.metal`: 添加 `reset_pixel_mask` 和 `initialize_buffers` kernel
- `Sources/Rendering/AdaptiveRenderer.swift`: 
  - 添加 `resetPixelMask` 和 `initializeGPUBuffers` 方法
  - 将 `createPixelMask` 改为 GPU 版本 `createPixelMaskGPU`

**预期收益**:
- 减少 CPU-GPU 数据传输
- 提高掩码操作的并行度
- 减少初始化时间

---

### ✅ 4. 内存优化（P2）

**问题**: 所有缓冲区都使用 `storageModeShared`，即使不需要 CPU 访问。

**解决方案**:
- GPU-only 缓冲区使用 `storageModePrivate`（更快）
- CPU-accessible 缓冲区使用 `storageModeShared`（需要读取统计数据）

**代码修改**:
- `Sources/Rendering/AdaptiveRenderer.swift`: 
  - `colorSumBuffer`, `colorSumSquaredBuffer`, `pixelMaskBuffer` → `storageModePrivate`
  - `sampleCountBuffer`, `varianceBuffer`, `convergedFlagBuffer`, `unconvergedListBuffer` → `storageModeShared`

**预期收益**:
- 提高 GPU 内存访问速度（Private 模式更快）
- 减少内存带宽占用
- 更好的缓存局部性

---

### 🔄 5. 采样数分配策略优化（部分实施）

**问题**: 所有未收敛像素分配相同的采样数，没有考虑方差差异。

**当前实现**:
- 读取方差数据并计算统计信息
- 为未来优化预留接口

**未来优化方向**:
- 根据方差大小动态分配采样数
- 高方差像素分配更多采样
- 低方差像素分配较少采样
- 需要修改渲染流程，支持不同像素使用不同采样数

---

## 二、代码质量改进

### 1. 错误处理
- 添加了 GPU 缓冲区分配失败的回退机制
- 改进了错误消息的可读性

### 2. 代码组织
- 提取了公共的 GPU 操作逻辑
- 改进了方法命名和注释
- 添加了性能优化说明

### 3. 内存管理
- 明确区分 GPU-only 和 CPU-accessible 缓冲区
- 使用 GPU kernel 初始化缓冲区，提高效率

---

## 三、性能预期总结

### 优化前
- Phase 1: 100% 计算（必需）
- Phase 2: 假设 50% 收敛，浪费 50% 计算
- **总效率**: ~75% 有效计算

### 优化后（方案1 + 方差优化 + GPU掩码）
- Phase 1: 100% 计算
- Phase 2: 假设 50% 收敛，节省 ~50% 计算（像素掩码）
- 方差计算: 节省 ~25% 开销（跳过已收敛像素）
- **总效率**: ~90% 有效计算
- **加速比**: 1.2x - 1.6x（取决于收敛率和场景复杂度）

### 内存优化收益
- GPU 内存访问速度提升 ~10-20%（Private 模式）
- 减少 CPU-GPU 数据传输开销

---

## 四、待实施的优化（未来）

### 1. 基于方差的采样数分配（P3）
- 实现不同像素使用不同采样数
- 需要修改渲染流程，支持稀疏采样

### 2. 分块渲染（P3）
- 将图像分成 32×32 块
- 如果块中所有像素已收敛，跳过整个块
- 进一步减少分支开销

### 3. 并行度优化（P4）
- 使用多个 command buffer 并行执行
- 下一轮渲染与当前轮方差计算并行

### 4. 动态批次大小调整（P4）
- 根据未收敛像素比例动态调整批次大小
- 减少后期迭代的浪费

---

## 五、使用建议

### 推荐参数设置

**快速预览**:
```bash
--spp 100 --min-spp 16
```

**高质量渲染**:
```bash
--spp 1000 --min-spp 32
```

**极高质量**:
```bash
--spp 10000 --min-spp 100
```

### 性能调优

1. **batchSize**: 默认 8，可以根据 GPU 性能调整（4-16）
2. **varianceThreshold**: 默认 1e-07，更小 = 更高质量，更多采样
3. **adaptiveRelativeThreshold**: 默认 0.005 (0.5%)，更小 = 更严格收敛标准

---

## 六、技术细节

### 像素掩码实现
- 使用 `uint` 数组，1 = 渲染，0 = 跳过
- GPU kernel 开始处检查，早期退出
- 减少分支惩罚（GPU SIMD 特性）

### 方差计算优化
- 收敛检查在计算开始处，避免不必要的计算
- 已收敛像素的方差缓存，不再重新计算

### 内存模式选择
- **Private**: GPU 快速访问，CPU 无法访问
- **Shared**: CPU-GPU 共享，速度较慢但可访问
- 根据访问模式选择合适的内存模式

---

## 七、测试建议

### 性能测试
1. 对比优化前后的渲染时间
2. 测量不同收敛率下的性能提升
3. 验证内存使用情况

### 质量测试
1. 对比优化前后的图像质量
2. 验证方差计算的正确性
3. 检查收敛判断的准确性

### 稳定性测试
1. 测试不同场景和参数组合
2. 验证边界情况（全部收敛、全部未收敛）
3. 检查内存泄漏和缓冲区溢出

---

## 八、总结

本次重构和优化主要聚焦于：

1. **性能优化**: 像素掩码支持、方差计算优化、GPU 端操作
2. **内存优化**: 使用 Private 模式，减少数据传输
3. **代码质量**: 改进错误处理、代码组织、注释

**关键成果**:
- ✅ 实现了像素掩码支持，显著减少 Phase 2 的计算浪费
- ✅ 优化了方差计算，跳过已收敛像素
- ✅ 改进了内存使用，提高 GPU 访问效率
- ✅ 提升了代码质量和可维护性

**预期性能提升**: 1.2x - 1.6x 加速比（取决于场景和收敛率）

