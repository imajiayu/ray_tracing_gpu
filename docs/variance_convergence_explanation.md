# 自适应采样：方差计算与收敛判断详解

## 一、概述

自适应采样的核心思想是：**根据像素的方差（不确定性）动态分配采样数**。方差大的像素需要更多采样，方差小的像素可以提前停止采样。

## 二、数据累积阶段

### 2.1 累积缓冲区

在渲染过程中，我们维护三个关键缓冲区：

1. **`colorSumBuffer`**: 颜色累积和
   - 类型: `float4[]` (RGBA)
   - 内容: `Σ(color_i)` - 所有采样颜色的总和

2. **`colorSumSquaredBuffer`**: 颜色平方累积和
   - 类型: `float4[]` (RGBA)
   - 内容: `Σ(color_i²)` - 所有采样颜色平方的总和

3. **`sampleCountBuffer`**: 采样计数
   - 类型: `uint[]`
   - 内容: `N` - 该像素已采样的总次数

### 2.2 累积过程 (`accumulate_samples` kernel)

每次渲染一批采样后，调用 `accumulate_samples` 累积结果：

```metal
// 读取新采样（这是 batch_size 个采样的平均值）
float4 new_color_avg = new_samples.read(gid);

// 累积颜色总和
// 注意：new_color_avg 是 batch_size 个采样的平均值
// 所以需要乘以 batch_size 得到总和
color_sum[pixel_idx] += new_color_avg * float(spp);

// 累积颜色平方（用于方差计算）
// 使用 batch 平均值的平方作为方差估计
float4 squared = new_color_avg * new_color_avg * float(spp);
color_sum_squared[pixel_idx] += squared;

// 更新采样计数
atomic_fetch_add_explicit(&sample_count[pixel_idx], spp, memory_order_relaxed);
```

**关键点**:
- `new_samples` 纹理中存储的是 **batch 平均值**（例如 8 个采样的平均值）
- 累积时需要乘以 `spp`（batch_size）来得到总和
- 平方累积也使用 batch 平均值的平方

**示例**:
```
假设 batch_size = 8，已采样 2 次 batch：

Batch 1: 平均颜色 = (1.0, 0.5, 0.2)
Batch 2: 平均颜色 = (1.1, 0.6, 0.3)

累积后：
colorSum = (1.0 + 1.1) * 8 = 16.8
colorSumSquared = (1.0² + 1.1²) * 8 = 17.68
sampleCount = 8 + 8 = 16
```

---

## 三、方差计算阶段

### 3.1 数学原理

**方差的定义**:
```
Var[X] = E[X²] - E[X]²
```

其中：
- `E[X]` = 均值 = `Σ(x_i) / N`
- `E[X²]` = 平方均值 = `Σ(x_i²) / N`

### 3.2 代码实现 (`compute_variance` kernel)

```metal
kernel void compute_variance(
    device const float4* color_sum [[buffer(0)]],
    device const float4* color_sum_squared [[buffer(1)]],
    device const uint* sample_count [[buffer(2)]],
    device float* variance [[buffer(3)]],
    device uint* converged_flags [[buffer(4)]],
    constant AdaptiveSamplingParams& params [[buffer(5)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint pixel_idx = gid.y * params.width + gid.x;
    uint N = sample_count[pixel_idx];
    
    // 至少需要 min_samples 才计算方差
    if (N < params.min_samples) return;
    
    // 1. 计算均值
    float3 sum = color_sum[pixel_idx].rgb;
    float3 mean = sum / float(N);
    
    // 2. 计算平方均值
    float3 sum_squared = color_sum_squared[pixel_idx].rgb;
    float3 mean_squared = sum_squared / float(N);
    
    // 3. 计算方差: Var[X] = E[X²] - E[X]²
    float3 var = mean_squared - mean * mean;
    
    // 4. 批量采样方差校正（见下文解释）
    var *= float(params.adaptive_batch_size * params.adaptive_batch_size);
    
    // 5. 取 RGB 三通道最大方差（保守估计）
    float pixel_var = max(var.r, max(var.g, var.b));
    
    // 6. 防止负方差（数值误差）
    pixel_var = max(0.0f, pixel_var);
    
    variance[pixel_idx] = pixel_var;
    
    // 7. 计算自适应阈值
    float lum = luminance(mean);
    float adaptive_threshold = (params.adaptive_relative_threshold * lum);
    adaptive_threshold = adaptive_threshold * adaptive_threshold;  // 方差是误差的平方
    
    // 8. 使用固定阈值和自适应阈值的最大值
    float final_threshold = max(params.variance_threshold, adaptive_threshold);
    
    // 9. 判断收敛
    if (pixel_var < final_threshold && N >= params.min_samples) {
        converged_flags[pixel_idx] = 1;
    }
}
```

### 3.3 逐步解析

#### 步骤 1-3: 基础方差计算

```metal
// 均值
mean = colorSum / N

// 平方均值
mean_squared = colorSumSquared / N

// 方差
var = mean_squared - mean * mean
```

**数学推导**:
```
设样本为 x₁, x₂, ..., xₙ

均值: μ = (x₁ + x₂ + ... + xₙ) / N = Σxᵢ / N

平方均值: E[X²] = (x₁² + x₂² + ... + xₙ²) / N = Σxᵢ² / N

方差: Var[X] = E[X²] - E[X]²
            = Σxᵢ²/N - (Σxᵢ/N)²
```

**示例**:
```
假设 16 个采样值: [1.0, 1.1, 0.9, 1.0, 1.2, 0.8, 1.1, 1.0, ...]

colorSum = 16.0
colorSumSquared = 16.32
N = 16

mean = 16.0 / 16 = 1.0
mean_squared = 16.32 / 16 = 1.02
var = 1.02 - 1.0² = 0.02
```

#### 步骤 4: 批量采样方差校正

**问题**: 我们累积的是 **batch 平均值**，而不是单个样本值。

**数学分析**:

假设每个 batch 包含 `B` 个样本，batch 平均值为 `X̄_batch`。

batch 平均值的方差：
```
Var[X̄_batch] = Var[X] / B
```

其中 `Var[X]` 是单个样本的真实方差。

**校正**:
```metal
// 需要将 batch 平均值的方差乘以 B² 来估计真实方差
var *= float(params.adaptive_batch_size * params.adaptive_batch_size);
```

**推导**:
```
设单个样本方差为 σ²
batch 平均值方差: Var[X̄] = σ² / B

要估计 σ²，需要:
σ² ≈ Var[X̄] × B²
```

**示例**:
```
假设 batch_size = 8，真实样本方差 σ² = 0.1

batch 平均值的方差: Var[X̄] = 0.1 / 8 = 0.0125

校正后: σ² ≈ 0.0125 × 8² = 0.8

注意：这个估计是近似的，因为：
1. 我们使用的是 batch_avg² 而不是 Σ(sample_i²)
2. 路径追踪的样本方差通常很高，需要经验校正
```

**为什么需要校正**:
- 如果不校正，方差会被低估（除以了 batch_size）
- 低估的方差会导致过早收敛（认为像素已经足够好）
- 校正后能更准确地反映真实的不确定性

#### 步骤 5: 取最大方差

```metal
float pixel_var = max(var.r, max(var.g, var.b));
```

**原因**: 
- RGB 三通道可能有不同的方差
- 使用最大方差是保守估计，确保所有通道都满足收敛条件
- 避免某个通道方差大但整体被判定为收敛

#### 步骤 6: 防止负方差

```metal
pixel_var = max(0.0f, pixel_var);
```

**原因**: 
- 由于浮点精度误差，`mean_squared - mean * mean` 可能略小于 0
- 方差必须是非负数

---

## 四、收敛判断

### 4.1 阈值计算

收敛判断使用**双重阈值**：固定阈值 + 自适应阈值

#### 固定阈值 (`variance_threshold`)
- 默认值: `1e-07` (0.0000001)
- 作用: 绝对误差阈值，防止极暗区域被误判为收敛

#### 自适应阈值 (`adaptive_relative_threshold`)
- 默认值: `0.005` (0.5%)
- 作用: 相对误差阈值，根据像素亮度动态调整

**计算过程**:
```metal
// 1. 计算像素亮度（感知亮度）
float lum = luminance(mean);
// luminance = 0.299*R + 0.587*G + 0.114*B

// 2. 计算相对误差阈值（方差是误差的平方）
float adaptive_threshold = (params.adaptive_relative_threshold * lum);
adaptive_threshold = adaptive_threshold * adaptive_threshold;

// 3. 使用两者的最大值
float final_threshold = max(params.variance_threshold, adaptive_threshold);
```

**示例**:
```
假设 relative_threshold = 0.005 (0.5%)

亮像素 (lum = 1.0):
  adaptive_threshold = (0.005 × 1.0)² = 0.000025
  final_threshold = max(1e-07, 0.000025) = 0.000025

暗像素 (lum = 0.1):
  adaptive_threshold = (0.005 × 0.1)² = 0.00000025
  final_threshold = max(1e-07, 0.00000025) = 1e-07 (使用固定阈值)

极暗像素 (lum = 0.01):
  adaptive_threshold = (0.005 × 0.01)² = 0.0000000025
  final_threshold = max(1e-07, 0.0000000025) = 1e-07 (使用固定阈值)
```

**为什么需要双重阈值**:
1. **固定阈值**: 保护极暗区域，防止数值误差导致误判
2. **自适应阈值**: 对亮像素使用更宽松的标准（相对误差），对暗像素使用更严格的标准

### 4.2 收敛条件

```metal
if (pixel_var < final_threshold && N >= params.min_samples) {
    converged_flags[pixel_idx] = 1;
}
```

**条件**:
1. `pixel_var < final_threshold`: 方差低于阈值
2. `N >= params.min_samples`: 至少达到最小采样数

**为什么需要最小采样数**:
- 早期采样数少时，方差估计不准确
- 确保所有像素至少达到基本质量要求
- 防止噪声导致的误判

---

## 五、完整流程示例

### 场景：600×600 图像，minSpp=16, targetSpp=100

#### Phase 1: 初始均匀采样

```
迭代 1: batch_size=8
  - 渲染所有 360,000 像素，每像素 8 次采样
  - 累积: colorSum, colorSumSquared, sampleCount=8

迭代 2: batch_size=8
  - 渲染所有 360,000 像素，每像素 8 次采样
  - 累积: sampleCount=16 (达到 minSpp)

计算方差:
  - 对每个像素计算方差
  - 假设 50% 像素收敛（方差 < threshold）
```

#### Phase 2: 自适应采样

```
迭代 1:
  - 未收敛像素: 180,000 个
  - 渲染所有像素（浪费），但只累积未收敛像素
  - 累积: sampleCount=24 (未收敛像素)
  - 重新计算方差
  - 假设 70% 像素收敛

迭代 2:
  - 未收敛像素: 108,000 个
  - 继续渲染所有像素，只累积未收敛像素
  - ...
```

---

## 六、潜在问题与改进

### 6.1 批量采样方差校正的准确性

**当前问题**:
- 使用 `batch_avg² × batch_size` 来估计 `Σ(sample_i²)`
- 这个估计是近似的，可能不够准确

**数学分析**:
```
真实: Σ(sample_i²) = Σ(xᵢ²)

当前估计: batch_avg² × batch_size = (Σxᵢ/batch_size)² × batch_size
         = (Σxᵢ)² / batch_size

误差: 缺少交叉项
(Σxᵢ)² = Σxᵢ² + 2Σᵢ<ⱼ xᵢxⱼ
```

**改进方案**:
- 在 GPU 端累积 `Σ(sample_i²)` 而不是 `batch_avg²`
- 需要修改渲染内核，在采样时直接累积平方

### 6.2 方差估计的稳定性

**问题**: 早期采样数少时，方差估计不稳定

**改进**:
- 使用滑动窗口或指数移动平均
- 只在采样数达到一定阈值后才判断收敛

### 6.3 自适应阈值的调整

**当前**: 固定相对误差阈值 0.5%

**改进**:
- 根据场景复杂度动态调整
- 高对比度区域使用更宽松的阈值
- 平滑区域使用更严格的阈值

---

## 七、总结

### 方差计算流程

1. **累积阶段**: 
   - 累积颜色总和: `colorSum += batch_avg × batch_size`
   - 累积颜色平方: `colorSumSquared += batch_avg² × batch_size`
   - 更新采样计数: `sampleCount += batch_size`

2. **方差计算**:
   - 均值: `mean = colorSum / N`
   - 平方均值: `mean_squared = colorSumSquared / N`
   - 方差: `var = mean_squared - mean²`
   - 批量校正: `var *= batch_size²`
   - 取最大值: `pixel_var = max(var.r, var.g, var.b)`

3. **收敛判断**:
   - 计算自适应阈值: `(relative_threshold × luminance)²`
   - 最终阈值: `max(fixed_threshold, adaptive_threshold)`
   - 收敛条件: `pixel_var < threshold && N >= min_samples`

### 关键参数

- `min_samples`: 最小采样数（默认 16）
- `variance_threshold`: 固定方差阈值（默认 1e-07）
- `adaptive_relative_threshold`: 相对误差阈值（默认 0.005 = 0.5%）
- `adaptive_batch_size`: 批量大小（默认 8）

### 设计权衡

1. **批量采样**: 提高 GPU 效率，但需要方差校正
2. **双重阈值**: 平衡亮暗像素的收敛标准
3. **最大方差**: 保守估计，确保所有通道都收敛
4. **最小采样数**: 防止早期误判

