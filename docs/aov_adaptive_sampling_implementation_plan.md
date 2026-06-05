# AOV自适应采样完整实现计划

## 当前进度

### ✅ 已完成
1. ✅ 定义AOV数据结构（Types.metal）
   - AOVChannel 枚举
   - AOVOutput 结构

2. ✅ 创建AOV kernel（AdaptiveSampling.metal）
   - `accumulate_samples_aov` - 累积5个通道（beauty/diffuse/specular/transmission/emission）
   - `compute_variance_aov` - 计算最大通道方差，specular/transmission加权2×

### 🚧 剩余工作

## 第一步：修改raytrace kernel输出AOV

**文件**: `Shaders/Kernels/RayTracing.metal`

**工作量**: 🔴 大（约300-500行代码修改）

**任务**:
1. 创建 `raytrace_aov` kernel（复制现有raytrace）
2. 修改路径追踪循环，分离材质贡献：
```metal
// 在每次scatter时
AOVOutput aov_out;
aov_out.beauty = float3(0);
aov_out.diffuse = float3(0);
aov_out.specular = float3(0);
aov_out.transmission = float3(0);
aov_out.emission = float3(0);

for (int depth = 0; depth < max_depth; ++depth) {
    // 相交测试...

    // 根据材质类型累积
    if (mat.type == MaterialLambertian) {
        aov_out.diffuse += attenuation * current_color;
    } else if (mat.type == MaterialMetal) {
        aov_out.specular += attenuation * current_color;
    } else if (mat.type == MaterialDielectric) {
        aov_out.transmission += attenuation * current_color;
    } else if (mat.type == MaterialDiffuseLight) {
        aov_out.emission += emission;
    }

    current_color *= attenuation;
}

aov_out.beauty = aov_out.diffuse + aov_out.specular + aov_out.transmission + aov_out.emission;
```

3. 输出到5个纹理：
```metal
kernel void raytrace_aov(
    texture2d<float, access::write> beauty_out [[texture(0)]],
    texture2d<float, access::write> diffuse_out [[texture(1)]],
    texture2d<float, access::write> specular_out [[texture(2)]],
    texture2d<float, access::write> transmission_out [[texture(3)]],
    texture2d<float, access::write> emission_out [[texture(4)]],
    // ... 其他参数
) {
    // 路径追踪...

    beauty_out.write(float4(aov_out.beauty, 1.0), gid);
    diffuse_out.write(float4(aov_out.diffuse, 1.0), gid);
    specular_out.write(float4(aov_out.specular, 1.0), gid);
    transmission_out.write(float4(aov_out.transmission, 1.0), gid);
    emission_out.write(float4(aov_out.emission, 1.0), gid);
}
```

**难点**:
- 需要重写路径追踪主循环
- 累积逻辑复杂（每个bounce需要正确的衰减）
- 确保energy conservation（总和 = beauty）

## 第二步：修改Renderer.swift

**文件**: `Sources/Rendering/Renderer.swift`

**工作量**: 🟡 中（约100-200行代码）

**任务**:
1. 创建 `renderToTexturesAOV` 函数：
```swift
func renderToTexturesAOV(
    scene: Scene,
    camera: Camera,
    bvh: FlatBVH,
    buffers: GPUBuffers,
    // ...
) -> (beauty: MTLTexture, diffuse: MTLTexture, specular: MTLTexture, transmission: MTLTexture, emission: MTLTexture)? {
    // 创建5个纹理
    let beautyTexture = createTexture(...)
    let diffuseTexture = createTexture(...)
    let specularTexture = createTexture(...)
    let transmissionTexture = createTexture(...)
    let emissionTexture = createTexture(...)

    // 设置到encoder
    encoder.setTexture(beautyTexture, index: 0)
    encoder.setTexture(diffuseTexture, index: 1)
    encoder.setTexture(specularTexture, index: 2)
    encoder.setTexture(transmissionTexture, index: 3)
    encoder.setTexture(emissionTexture, index: 4)

    // 调用 raytrace_aov kernel
    encoder.setComputePipelineState(raytraceAOVPipeline)
    encoder.dispatch(...)

    return (beautyTexture, diffuseTexture, specularTexture, transmissionTexture, emissionTexture)
}
```

## 第三步：修改AdaptiveRenderer.swift

**文件**: `Sources/Rendering/AdaptiveRenderer.swift`

**工作量**: 🟡 中（约150-250行代码）

**任务**:
1. 添加AOV缓冲区管理：
```swift
// 添加额外的AOV累积缓冲区
let diffuseSumBuffer = device.makeBuffer(...)
let diffuseSumSquaredBuffer = device.makeBuffer(...)
let specularSumBuffer = device.makeBuffer(...)
let specularSumSquaredBuffer = device.makeBuffer(...)
let transmissionSumBuffer = device.makeBuffer(...)
let transmissionSumSquaredBuffer = device.makeBuffer(...)
let emissionSumBuffer = device.makeBuffer(...)
let emissionSumSquaredBuffer = device.makeBuffer(...)
```

2. 修改渲染调用：
```swift
// 使用 renderToTexturesAOV 替代 renderToTexture
guard let (beauty, diffuse, specular, transmission, emission) =
    baseRenderer.renderToTexturesAOV(...) else {
    fatalError("Failed to render AOV")
}
```

3. 调用AOV accumulate kernel：
```swift
encoder.setComputePipelineState(accumulateSamplesAOVPipeline)
encoder.setTexture(beauty, index: 0)
encoder.setTexture(diffuse, index: 1)
encoder.setTexture(specular, index: 2)
encoder.setTexture(transmission, index: 3)
encoder.setTexture(emission, index: 4)
encoder.setBuffer(diffuseSumBuffer, offset: 0, index: 2)
encoder.setBuffer(diffuseSumSquaredBuffer, offset: 0, index: 3)
// ... 设置其他buffer
```

4. 调用AOV variance kernel：
```swift
encoder.setComputePipelineState(computeVarianceAOVPipeline)
encoder.setBuffer(diffuseSumBuffer, offset: 0, index: 0)
encoder.setBuffer(diffuseSumSquaredBuffer, offset: 0, index: 1)
encoder.setBuffer(specularSumBuffer, offset: 0, index: 2)
// ...
```

5. 最终像素读取（使用beauty）：
```swift
// 从beauty_sum读取最终图像
let pixels = readFinalPixels(
    colorSumBuffer: beautySumBuffer,  // 使用beauty而不是color_sum
    sampleCountBuffer: sampleCountBuffer,
    width: width,
    height: height
)
```

## 第四步：添加命令行参数

**文件**: `Sources/Utils/CommandLineArgs.swift`

**工作量**: 🟢 小（约30行代码）

**任务**:
```swift
var useAOVAdaptive: Bool = false  // 是否使用AOV自适应采样

// 解析参数
case "--aov":
    self.useAOVAdaptive = true
```

**文件**: `Sources/Window/AppDelegate.swift`

**修改**: 检查useAOVAdaptive，选择使用标准或AOV渲染器

## 第五步：测试验证

**测试场景**: Cornell Box

**对比测试**:
```bash
# 标准固定采样
swift run raytracer --mode image --scene 1 --spp 1000

# 标准自适应采样
swift run raytracer --mode image --scene 1 --spp 1000 --min-spp 100

# AOV自适应采样（新）
swift run raytracer --mode image --scene 1 --spp 1000 --min-spp 100 --aov
```

**预期效果**:
- 镜面反射（玻璃球）噪点明显减少
- 平均spp降低（节省30-50%采样）
- 总渲染时间减少

---

## 工作量估算

| 任务 | 难度 | 预估时间 | 风险 |
|------|------|---------|------|
| 修改raytrace kernel | 🔴 高 | 2-3小时 | 高（容易引入bug） |
| 修改Renderer.swift | 🟡 中 | 1-2小时 | 中 |
| 修改AdaptiveRenderer.swift | 🟡 中 | 1-2小时 | 中 |
| 添加命令行参数 | 🟢 低 | 0.5小时 | 低 |
| 测试调试 | 🟡 中 | 1-2小时 | 中 |
| **总计** | | **5-9小时** | |

---

## 简化方案（备选）

如果完整实现工作量太大，可以采用**材质加权方差**简化方案：

### 方案：基于颜色特征的伪AOV

**核心思路**: 不真正分离AOV，而是基于像素颜色特征估计材质类型：

```metal
kernel void compute_variance_weighted(
    device const float4* color_sum [[buffer(0)]],
    // ...
) {
    float3 mean = color_sum[pixel_idx].rgb / float(N);

    // 基于颜色特征估计材质类型
    float brightness = max(mean.r, max(mean.g, mean.b));
    float saturation = (max_component - min_component) / (brightness + 0.001);

    // 高亮区域 = specular/transmission，需要更严格的阈值
    float material_weight = 1.0;
    if (brightness > 0.8 && saturation < 0.3) {
        material_weight = 3.0;  // 高亮区域权重3×
    }

    // 应用权重到方差阈值
    float final_threshold = params.variance_threshold / material_weight;

    if (pixel_var < final_threshold && N >= params.min_samples) {
        converged_flags[pixel_idx] = 1;
    }
}
```

**优势**:
- ✅ 不需要修改raytrace kernel
- ✅ 实现简单（只修改1个kernel）
- ✅ 风险低
- ✅ 立即可测试

**劣势**:
- ❌ 精度不如真实AOV
- ❌ 基于启发式规则，不保证完全正确

---

## 建议

**立即可行**: 先实现**简化方案**，快速验证效果
**长期目标**: 如果效果好，再投入时间完成**完整AOV实现**

请选择实现方案：
1. **完整AOV**（5-9小时，更准确）
2. **简化方案**（0.5-1小时，快速验证）
