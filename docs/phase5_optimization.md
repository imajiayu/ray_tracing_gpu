# Phase 5: 渲染质量、速度与正确性优化

**实施日期**: 2025-12-03+
**前置条件**: Phase 1-4 完成 (MIS 已实现)
**目标**: 全方位提升渲染器性能和可靠性

---

## 目标概览

基于代码深度分析（详见技术报告），Phase 5 聚焦三个维度的优化：

| 维度 | 当前状态 | 目标改进 | 预期收益 |
|------|---------|---------|---------|
| **质量** | MIS 固定 50/50 权重 | 自适应权重 + 多光源 | 噪声 -15% ～ -25% |
| **速度** | 中点分割 BVH | SAH 优化 + 缓存改进 | 渲染时间 -20% ～ -35% |
| **正确性** | 8 个已知问题 | 全部修复 + 稳健性强化 | 边界情况 100% 处理 |

---

## 一、质量优化 (Quality)

### 1.1 自适应 MIS 权重 ✨ 高优先级

**问题**:
当前 MIS 使用固定 50/50 混合，但在光源几何、材质不同时不均衡。

**解决方案**: Veach's Power Heuristic

```metal
// Shaders/Common/PDF.metal 新增函数
inline float power_heuristic(float pdf_a, float pdf_b, int beta = 2) {
    float a = pow(pdf_a, beta);
    float b = pow(pdf_b, beta);
    return a / (a + b);
}

// RayTracing.metal, 行 ~200 修改
if (lights_count > 0) {
    float light_pdf = hittable_pdf_value(...);
    float brdf_pdf = material_scattering_pdf(...);

    // 新: 动态权重
    float w_light = power_heuristic(light_pdf, brdf_pdf);
    float w_brdf = 1.0f - w_light;

    float pdf_val = w_light * light_pdf + w_brdf * brdf_pdf;
}
```

**修改文件**:
- `Shaders/Common/PDF.metal`: 新增 `power_heuristic()`
- `Shaders/Kernels/RayTracing.metal`: 替换固定权重

**预期收益**:
- Cornell Box 噪声 -10% ～ -15%
- 复杂场景（多种材质）噪声 -20%

**验证**: 渲染 Cornell Box (100 spp) 对比图像 MSE

---

### 1.2 多光源重要性采样 ✨ 高优先级

**问题**:
当前仅支持均匀随机选择光源，忽略几何/法线影响。

**解决方案**: 预计算光源立体角权重

```swift
// Sources/Scene/Scene.swift 新增
struct LightSample {
    var geometry: Geometry
    var probability: Float  // 采样概率
}

func computeLightImportance(from point: Vec3, normal: Vec3) -> [Float] {
    var importance = [Float](repeating: 0, count: lights.count)

    for (i, light) in lights.enumerated() {
        let toLight = light.center - point
        let distSquared = toLight.lengthSquared
        let cosTheta = max(0, dot(normalize(toLight), normal))

        // 立体角近似: Ω ≈ area * cosθ / distance²
        importance[i] = light.area * cosTheta / distSquared
    }

    // 归一化
    let sum = importance.reduce(0, +)
    return importance.map { $0 / sum }
}
```

**GPU 端**:
```metal
// Shaders/Common/PDF.metal 修改 hittable_pdf_generate()
inline float3 hittable_pdf_generate_weighted(
    device const GPULightInfo* lights,
    device const float* light_weights,  // 新参数
    uint lights_count,
    ...
) {
    // 加权随机选择
    float r = random_float(rng);
    uint selected_light = 0;
    float cumulative = 0.0f;

    for (uint i = 0; i < lights_count; i++) {
        cumulative += light_weights[i];
        if (r < cumulative) {
            selected_light = i;
            break;
        }
    }

    // 采样选中的光源
    return sample_light(lights[selected_light], ...);
}
```

**修改文件**:
- `Sources/Scene/Scene.swift`: 光源权重计算
- `Sources/Rendering/Renderer.swift`: 传递权重缓冲
- `Shaders/Common/PDF.metal`: 加权采样
- `Sources/GPU/GPUStructs.swift`: 新增 `GPULightWeights`

**预期收益**:
- 多光源场景（3+ 光源）噪声 -20% ～ -30%
- 单次采样效率 +25%

**验证**: 创建 3 光源场景，对比噪声分布

---

### 1.3 改进 Tone Mapping 🎨 中优先级

**问题**:
当前仅使用 Gamma 2.2，高动态范围场景（如爆炸、强光）过曝。

**解决方案**: ACES Filmic Tone Mapping

```swift
// Sources/Utils/ImageWriter.swift 新增
enum ToneMappingMode {
    case gamma(Float)      // 当前实现
    case reinhard          // Reinhard 算子
    case acesFilmic        // ACES (推荐)
}

func applyACESFilmic(_ color: Color) -> Color {
    let a = 2.51
    let b = 0.03
    let c = 2.43
    let d = 0.59
    let e = 0.14

    var mapped = color
    mapped.r = (mapped.r * (a * mapped.r + b)) / (mapped.r * (c * mapped.r + d) + e)
    mapped.g = (mapped.g * (a * mapped.g + b)) / (mapped.g * (c * mapped.g + d) + e)
    mapped.b = (mapped.b * (a * mapped.b + b)) / (mapped.b * (c * mapped.b + d) + e)

    // 钳制到 [0, 1]
    return Color(
        clamp(mapped.r, 0, 1),
        clamp(mapped.g, 0, 1),
        clamp(mapped.b, 0, 1)
    )
}
```

**修改文件**:
- `Sources/Utils/ImageWriter.swift`: 新增 Tone Mapping 选项
- `Sources/main.swift`: 添加命令行参数 `--tone-mapping <mode>`

**预期收益**:
- 高对比度场景视觉质量 +30%
- 避免颜色裁剪（clipping）

**验证**: 渲染高光场景（如镜面反射强光）

---

### 1.4 修复纹理限制 🔧 高优先级

**问题**:
`Textures.metal:145-146` 仅支持第一个图片纹理。

**解决方案**: 纹理数组支持

```metal
// Shaders/Common/Textures.metal 修改
inline float3 texture_value(
    GPUTexture tex,
    float u, float v, float3 p,
    texture2d_array<float> image_textures,  // 改为数组
    ...
) {
    case TextureImage:
        {
            // 移除硬编码检查
            constexpr sampler textureSampler(...);

            float2 texCoord = float2(u, 1.0f - v);

            // 使用纹理索引
            float4 color = image_textures.sample(
                textureSampler,
                texCoord,
                tex.image_index
            );

            return color.rgb;
        }
}
```

**修改文件**:
- `Shaders/Common/Textures.metal`: 数组支持
- `Sources/Rendering/Renderer.swift`: 创建 `MTLTextureArray`
- `Sources/GPU/GPUStructs.swift`: `imageIndex` 改为 `UInt32`

**预期收益**:
- 支持多纹理场景（如多地球球体）
- 解除 Phase 4 限制

**验证**: 创建 3 个不同图片纹理的球体

---

## 二、速度优化 (Performance)

### 2.1 SAH-based BVH 构建 🚀 最高优先级

**问题**:
当前中点分割导致 BVH 树不平衡，遍历深度过大。

**解决方案**: Surface Area Heuristic 分割

```swift
// Sources/Acceleration/FlatBVH.swift 新增
private func findBestSplit(
    geometries: [GeometryWrapper],
    bbox: AABB,
    axis: Int
) -> (split: Float, cost: Float) {
    let numBins = 16
    var bins = [SAHBin](repeating: SAHBin(), count: numBins)

    // 1. 分箱统计
    for geom in geometries {
        let center = geom.bbox.center[axis]
        let binIndex = min(numBins - 1, Int((center - bbox.min[axis]) /
                                            (bbox.max[axis] - bbox.min[axis]) * Float(numBins)))
        bins[binIndex].count += 1
        bins[binIndex].bounds = AABB.merge(bins[binIndex].bounds, geom.bbox)
    }

    // 2. 扫描计算 SAH
    var bestCost = Float.infinity
    var bestSplit = bbox.min[axis]

    var leftBox = AABB.empty
    var leftCount = 0

    for i in 0..<(numBins - 1) {
        leftBox = AABB.merge(leftBox, bins[i].bounds)
        leftCount += bins[i].count

        var rightBox = AABB.empty
        var rightCount = 0
        for j in (i+1)..<numBins {
            rightBox = AABB.merge(rightBox, bins[j].bounds)
            rightCount += bins[j].count
        }

        // SAH 成本: C = t_traverse + (N_left * SA_left + N_right * SA_right) / SA_parent
        let cost = 1.0 + (Float(leftCount) * leftBox.surfaceArea +
                         Float(rightCount) * rightBox.surfaceArea) / bbox.surfaceArea

        if cost < bestCost {
            bestCost = cost
            bestSplit = bbox.min[axis] + (Float(i + 1) / Float(numBins)) *
                       (bbox.max[axis] - bbox.min[axis])
        }
    }

    return (bestSplit, bestCost)
}

private func buildRecursive(...) -> BVHNode {
    // ...原有逻辑

    // 替换中点分割为 SAH
    let axis = nodeBBox.longestAxis
    let (splitPos, _) = findBestSplit(geometries: geometries[start..<end],
                                      bbox: nodeBBox,
                                      axis: axis)

    // 分区
    let mid = geometries[start..<end].partition { geom in
        geom.bbox.center[axis] < splitPos
    }

    // 递归构建
    node.left = buildRecursive(..., start: start, end: mid, ...)
    node.right = buildRecursive(..., start: mid, end: end, ...)
}
```

**修改文件**:
- `Sources/Acceleration/FlatBVH.swift`: SAH 分割算法
- `Sources/Acceleration/AABB.swift`: 新增 `surfaceArea()` 属性

**预期收益**:
- BVH 遍历深度 -20% ～ -30%
- Final Scene (3400 几何体) 渲染时间 -25%
- Bouncing Spheres 渲染时间 -15%

**验证**: 统计平均 BVH 遍历深度（添加调试计数器）

---

### 2.2 减少 PDF 重复计算 ⚡ 高优先级

**问题**:
每次光线反弹都重新构建 ONB，浪费 ~20 FLOPS。

**解决方案**: 缓存 ONB 在 ScatterRecord

```metal
// Shaders/Common/Materials.metal 修改
struct ScatterRecord {
    float3 attenuation;
    PDF pdf;
    bool skip_pdf;
    Ray skip_pdf_ray;

    // 新增: 缓存 ONB
    ONB cached_onb;
    bool onb_valid;
};

// 材质散射时预计算
inline bool lambertian_scatter_mis(..., thread ScatterRecord* srec) {
    srec->attenuation = ...;

    srec->pdf.type = PDF_COSINE;
    srec->pdf.w = rec.normal;

    // 预计算 ONB
    srec->cached_onb = onb_build(rec.normal);
    srec->onb_valid = true;

    srec->skip_pdf = false;
    return true;
}

// PDF.metal 修改，复用 ONB
inline float3 cosine_pdf_generate(
    PDF pdf,
    thread ScatterRecord* srec,  // 新参数
    thread RandomState* rng
) {
    ONB uvw;
    if (srec->onb_valid && pdf.type == PDF_COSINE) {
        uvw = srec->cached_onb;  // 直接使用缓存
    } else {
        uvw = onb_build(pdf.w);
    }

    return onb_transform(uvw, random_cosine_direction(rng));
}
```

**修改文件**:
- `Shaders/Common/Materials.metal`: ONB 缓存
- `Shaders/Common/PDF.metal`: 复用逻辑
- `Shaders/Kernels/RayTracing.metal`: 传递 ScatterRecord

**预期收益**:
- 每光线反弹节省 ~15 FLOPS
- 总体渲染时间 -8% ～ -12%

**验证**: GPU profiler 测量 ONB 计算时间

---

### 2.3 压缩 BVH 节点 💾 中优先级

**问题**:
`GPUBVHNode` 48 bytes，超 L2 缓存（Apple Silicon 4MB）。

**解决方案**: 16-bit 索引 + 压缩 AABB

```swift
// Sources/GPU/GPUStructs.swift 新增
struct GPUBVHNodeCompact {
    var bbox_min_x: Float16     // 2 bytes
    var bbox_min_y: Float16     // 2 bytes
    var bbox_min_z: Float16     // 2 bytes
    var bbox_max_x: Float16     // 2 bytes
    var bbox_max_y: Float16     // 2 bytes
    var bbox_max_z: Float16     // 2 bytes

    var leftChildOrFirst: UInt16  // 2 bytes (最多 65K 节点)
    var rightChild: UInt16        // 2 bytes
    var geometryCount: UInt8      // 1 byte (最多 255 几何体/叶)
    var splitAxis: UInt8          // 1 byte
    var padding: UInt16           // 2 bytes
}  // Total: 20 bytes (-58%)
```

**注意事项**:
- Float16 精度: ±65504，误差 ~0.001
- 适用场景: 场景范围 [-1000, 1000]
- 超大场景需 fallback 到 Float32

**修改文件**:
- `Sources/GPU/GPUStructs.swift`: 新结构体
- `Sources/Acceleration/FlatBVH.swift`: 可选压缩
- `Shaders/Common/Acceleration.metal`: 解压缩逻辑

**预期收益**:
- 内存带宽 -58%
- Final Scene 渲染时间 -10% ～ -15%（大场景）

**验证**: 内存 profiler 测量带宽占用

---

### 2.4 优化随机数生成 🎲 低优先级

**问题**:
拒绝采样平均 1.56 次随机数生成，可改进。

**解决方案**: Marsaglia 极坐标法

```metal
// Random.metal 新增
inline float3 random_unit_vector_fast(thread RandomState* rng) {
    float theta = random_float(rng) * 2.0f * M_PI_F;
    float z = random_float_range(rng, -1.0f, 1.0f);
    float r = sqrt(1.0f - z * z);

    return float3(r * cos(theta), r * sin(theta), z);
}
```

**性能对比**:
- 原版: 平均 1.56 次 `random_float()`
- 新版: 固定 2 次 `random_float()` + 1 次 `sqrt()` + 2 次三角函数

**注意**: 三角函数在 GPU 上成本高，实际收益需测试。

**修改文件**:
- `Shaders/Common/Random.metal`: 新函数
- `Shaders/Kernels/RayTracing.metal`: 可选启用

**预期收益**:
- 随机数开销 -10% ～ -20%（理论）
- 总体渲染时间 -3% ～ -5%

**验证**: A/B 测试对比两版本

---

## 三、正确性修复 (Correctness)

### 3.1 修复已识别的 8 个问题 🐛 最高优先级

#### 问题 #1: PDF 除零保护不明确

**文件**: `RayTracing.metal:114`

```metal
// 修改前
float pdf_val = ...;
if (pdf_val < 1e-10f) pdf_val = 1e-10f;

// 修改后
float pdf_val = fmax(1e-6f, ...);  // 更明确，阈值提高
```

#### 问题 #2: 未使用的 scattered 变量

**文件**: `RayTracing.metal:146`

```metal
// 删除
// float3 scattered = ...;

// 直接使用
float3 scattered_dir = pdf_generate(...);
```

#### 问题 #3: MixturePDF 嵌套支持

**文件**: `PDF.metal:327-331`

```metal
// 新增递归支持
case PDF_MIXTURE:
    {
        // 递归计算子 PDF
        PDF pdf1 = pdf.child1;  // 需扩展 PDF 结构
        PDF pdf2 = pdf.child2;

        float v1 = pdf_value(pdf1, direction, origin, ...);
        float v2 = pdf_value(pdf2, direction, origin, ...);

        return 0.5f * v1 + 0.5f * v2;
    }
```

**注意**: 需扩展 PDF 结构体存储子 PDF，增加复杂度。

#### 问题 #4: metal::refract() 错误处理

**文件**: `Materials.metal:153`

```metal
// 修改前
float3 direction = metal::refract(unit_direction, rec.normal, refraction_ratio);

// 修改后
float3 direction;
if (cannot_refract) {
    direction = metal::reflect(unit_direction, rec.normal);
} else {
    direction = metal::refract(unit_direction, rec.normal, refraction_ratio);

    // 验证结果
    if (length_squared(direction) < 1e-6f) {
        direction = metal::reflect(unit_direction, rec.normal);
    }
}
```

#### 问题 #5: BVH 栈溢出检查

**文件**: `Acceleration.metal:140-144`

```metal
// 修改前
if (stack_ptr < MAX_STACK_SIZE - 1) {
    stack[stack_ptr++] = second;
    stack[stack_ptr++] = first;
}

// 修改后
if (stack_ptr + 2 <= MAX_STACK_SIZE) {
    stack[stack_ptr++] = second;
    stack[stack_ptr++] = first;
} else {
    // 记录溢出（可选调试）
    // overflow_flag = true;
}
```

#### 问题 #6: 动态栈深度

**文件**: `Acceleration.metal:75`

```metal
// 修改为运行时参数
kernel void raytrace(
    ...
    constant uint& max_stack_size [[buffer(N)]],  // 新参数
    ...
) {
    // 动态分配栈（限制: Metal 不支持 VLA）
    // 实际方案: 预定义多个内核版本
    #if MAX_STACK_SIZE == 32
        uint stack[32];
    #elif MAX_STACK_SIZE == 64
        uint stack[64];
    #elif MAX_STACK_SIZE == 128
        uint stack[128];
    #endif
}
```

**替代方案**: 编译时指定，使用函数常数（function constants）。

#### 问题 #7: 多纹理支持（已在 1.4 处理）

#### 问题 #8: 拒绝采样阈值

**文件**: `Random.metal:71`

```metal
// 修改前
if (1e-8f < lensq && lensq <= 1.0f)

// 修改后
if (1e-6f < lensq && lensq <= 1.0f)  // 避免极小向量
```

---

### 3.2 浮点数稳定性强化 🔢 高优先级

#### A. 法线归一化双重保护

**文件**: `Geometry.metal` 多处

```metal
// 添加检查
inline void set_face_normal_safe(
    thread HitRecord* rec,
    Ray r,
    float3 outward_normal
) {
    float3 normalized = normalize(outward_normal);

    // 验证归一化结果
    float len_sq = dot(normalized, normalized);
    if (abs(len_sq - 1.0f) > 0.01f) {
        // 归一化失败，使用备用法线
        normalized = float3(0, 1, 0);
    }

    rec->front_face = dot(r.direction, normalized) < 0.0f;
    rec->normal = rec->front_face ? normalized : -normalized;
}
```

#### B. 避免除零

**全局搜索并修复**:
```bash
grep -n "/ " Shaders/**/*.metal | grep -v "M_PI" | grep -v "//"
```

**修复模式**:
```metal
// 替换
float result = a / b;

// 为
float result = a / fmax(b, 1e-6f);
```

#### C. NaN 检测与替换

**文件**: `RayTracing.metal`

```metal
// 统一 NaN 检测函数
inline bool is_valid_color(float3 color) {
    return (color.r == color.r) &&
           (color.g == color.g) &&
           (color.b == color.b) &&
           all(color >= 0.0f) &&
           all(color < 1e6f);  // 防止极大值
}

// 在输出前验证
if (!is_valid_color(color)) {
    color = float3(1, 0, 1);  // 洋红色标记错误像素
}
```

**修改文件**:
- `Shaders/Kernels/RayTracing.metal`: 全局 NaN 检测

---

### 3.3 边界条件测试 ✅ 中优先级

**新增测试场景**:

```swift
// Sources/Scenes/EdgeCaseTests.swift
struct EdgeCaseTests {
    // 1. 零半径球
    static func zeroRadiusSphere() -> Scene { ... }

    // 2. 共面四边形
    static func coplanarQuads() -> Scene { ... }

    // 3. 极小/极大场景范围
    static func extremeScale() -> Scene { ... }

    // 4. 零发光材质
    static func zeroEmission() -> Scene { ... }

    // 5. 极高折射率
    static func extremeRefraction() -> Scene { ... }
}
```

**测试方法**:
```bash
swift run raytracer --scene edgeCaseTest1 --spp 10
# 检查输出是否有 NaN/Inf/洋红色像素
```

---

## 四、实施计划

### 阶段 1: 基础优化（1 周）

**目标**: 修复正确性问题 + SAH-BVH

**任务**:
- [ ] 修复 8 个已识别问题
- [ ] 实现 SAH-BVH 构建
- [ ] 添加浮点数稳定性检查
- [ ] 创建边界测试场景

**验证标准**:
- 所有测试场景无 NaN/Inf
- Final Scene 渲染时间 < 70 ms (当前 88 ms)

---

### 阶段 2: 质量提升（1 周）

**目标**: 自适应 MIS + 多光源采样

**任务**:
- [ ] 实现 Power Heuristic
- [ ] 多光源重要性采样
- [ ] 修复纹理限制
- [ ] ACES Tone Mapping

**验证标准**:
- Cornell Box (100 spp) 噪声 -15%
- 多光源场景渲染质量明显提升

---

### 阶段 3: 性能调优（1 周）

**目标**: 减少冗余计算 + 内存优化

**任务**:
- [ ] ONB 缓存
- [ ] BVH 节点压缩（可选）
- [ ] 随机数优化（可选）
- [ ] GPU Profiler 分析

**验证标准**:
- Bouncing Spheres 渲染时间 < 150 ms (当前 180 ms)
- 内存带宽占用 -20%

---

### 阶段 4: 文档与测试（1 周）

**目标**: 完善文档和基准测试

**任务**:
- [ ] 更新 CLAUDE.md
- [ ] 编写性能对比报告
- [ ] 创建回归测试套件
- [ ] 代码注释完善

---

## 五、性能目标

### 基准场景对比

| 场景 | Phase 4 | Phase 5 目标 | 提升 |
|------|--------|------------|------|
| Cornell Box (400×400, 100 spp) | 482 ms | **350 ms** | -27% |
| Bouncing Spheres (800×450, 10 spp) | 180 ms | **150 ms** | -17% |
| Final Scene (400×400, 10 spp) | 88 ms | **70 ms** | -20% |

### 质量指标

| 指标 | Phase 4 | Phase 5 目标 |
|------|--------|------------|
| Cornell Box 噪声 (MSE) | 基准 | **-15%** |
| 多光源场景噪声 | 基准 | **-25%** |
| 高动态范围保留 | 50% | **90%** (ACES) |

---

## 六、风险与缓解

| 风险 | 概率 | 影响 | 缓解措施 |
|------|------|------|---------|
| SAH 构建时间过长 | 中 | 高 | 限制分箱数量为 16 |
| Float16 精度不足 | 低 | 中 | 提供 Float32 fallback |
| ONB 缓存增加内存 | 低 | 低 | ScatterRecord 对齐优化 |
| ACES 映射颜色偏移 | 中 | 低 | 提供 Gamma 备选 |

---

## 七、验收标准

**Phase 5 完成条件**:
1. ✅ 所有 8 个已知问题修复
2. ✅ SAH-BVH 实现并通过测试
3. ✅ 自适应 MIS 权重生效
4. ✅ 多纹理支持（3+ 纹理）
5. ✅ 边界测试场景无错误
6. ✅ 性能目标达成（-20% 平均）
7. ✅ 文档更新完整

---

## 附录：旧 Phase 顺序调整

**旧计划**:
- Phase 5: 实时窗口模式
- Phase 6: 体积雾效果

**新计划**:
- Phase 5: **质量/速度/正确性优化** (本文档)
- Phase 6: 实时窗口模式（原 Phase 5）
- Phase 7: 体积雾效果（原 Phase 6）

**理由**:
- 优化基础渲染器是实时渲染的前提
- 修复正确性问题避免在复杂功能中积累技术债
- 性能提升使后续功能开发更高效

---

**文档版本**: v1.0
**创建日期**: 2025-12-03
**状态**: 待开始实施
