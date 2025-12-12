# Phase 10: 高级性能优化 - Wavefront Path Tracing & BDPT

**创建日期**: 2025-12-11
**前置条件**: Phase 1-9 完成 (路径追踪 + BVH + MIS + 实时窗口 + 后处理 + 抗锯齿)
**目标**: 实现两项高级性能优化技术，突破现有 GPU 利用率瓶颈

---

## 目标概览

| 优化项 | 当前瓶颈 | 技术方案 | 预期收益 | 实施难度 |
|--------|---------|---------|---------|---------|
| **Wavefront Path Tracing** | GPU 线程束分歧严重 | 按深度分层渲染 | 性能 +40% ～ +100% | ⭐⭐⭐⭐ |
| **BDPT 双向路径追踪** | 复杂光照收敛慢 | 光源/相机双路径 | 噪声 -50% ～ -80% | ⭐⭐⭐⭐⭐ |

---

## 一、现有架构分析

### 1.1 当前渲染流程 (RayTracing.metal:27-185)

**迭代式路径追踪**:
```metal
inline float3 ray_color(...) {
    Ray current_ray = r;
    float3 accumulated_throughput = float3(1.0f);
    float3 accumulated_radiance = float3(0.0f);

    // 迭代式路径追踪（避免递归）
    for (uint depth = 0; depth < max_depth; depth++) {
        HitRecord rec;
        bool hit_anything = bvh_hit(...);  // BVH 遍历

        if (hit_anything) {
            // 材质散射 + MIS 采样
            material_scatter_mis(...);
            // 累积辐射度
            accumulated_radiance += ...;
        } else {
            break;
        }
    }
    return accumulated_radiance;
}
```

**主渲染内核** (RayTracing.metal:189-308):
```metal
kernel void raytrace(...) {
    // 每个线程处理一个像素
    for (uint s_j = 0; s_j < sqrt_spp; s_j++) {
        for (uint s_i = 0; s_i < sqrt_spp; s_i++) {
            Ray r = generate_camera_ray(...);
            float3 color = ray_color(r, ...);  // 完整路径追踪
            pixel_color += color * filter_weight;
        }
    }
    output.write(float4(pixel_color, 1.0f), gid);
}
```

### 1.2 GPU 资源利用瓶颈

#### 瓶颈 1: 线程束分歧 (Warp Divergence)

**问题描述**:
- Metal GPU 以 32 个线程为一组（SIMD 线程组）执行
- 当前架构下，同一线程组的 32 个像素路径深度不同：
  - 像素 A: 2 bounce 后击中天空 → 剩余 8 次循环空转
  - 像素 B: 10 bounce 后才结束 → 拖累整个组
  - 像素 C, D, E... 各自不同深度
- **结果**: 线程组效率 < 40%，大量 ALU 空闲

**性能影响** (实测数据 - Phase 5):
```
Cornell Box (400×400, 10 spp, max_depth=50):
- 理论峰值: 8.5 TFLOPS (M1 Max)
- 实际吞吐: 2.1 TFLOPS
- GPU 利用率: ~25%
```

#### 瓶颈 2: 内存访问模式低效

**问题描述**:
- BVH 遍历时，相邻线程访问不连续节点 → Cache Miss 率高
- 材质纹理采样随机跳跃 → Texture Cache 命中率低
- 光源采样时访问随机几何体 → 缓存局部性差

**性能影响**:
```
内存带宽利用率分析:
- 理论带宽: 400 GB/s (M1 Max)
- 实际使用: ~120 GB/s
- 效率: 30%
```

#### 瓶颈 3: 中间数据无法复用

**问题描述**:
- 相机光线与光源光线独立生成，无法共享交点信息
- 间接光照无法利用直接光照的几何信息
- 每帧重新计算，历史帧数据完全丢弃（除了累积纹理）

---

## 二、Wavefront Path Tracing (推荐优先实现)

### 2.1 核心思想

**传统路径追踪 (当前实现)**:
```
线程 1: Ray → Bounce1 → Bounce2 → ... → BounceN
线程 2: Ray → Bounce1 → Bounce2 → ...
线程 3: Ray → Bounce1 → ...
...
问题: 线程 1-32 的深度不同，产生严重分歧
```

**Wavefront 路径追踪**:
```
Pass 1 (Depth 0): 所有线程生成相机光线 → 存入 RayQueue[0]
Pass 2 (Depth 1): 所有线程处理 RayQueue[0] → 生成 RayQueue[1]
Pass 3 (Depth 2): 所有线程处理 RayQueue[1] → 生成 RayQueue[2]
...
优势: 同一深度的所有光线并行处理，无分歧
```

### 2.2 技术架构

#### A. 数据结构设计

**光线队列** (Shaders/Common/Types.metal):
```metal
// 光线载荷（Payload）- 64 bytes
struct RayPayload {
    Ray ray;                    // 12 + 12 + 4 = 28 bytes (origin, direction, time)
    float3 throughput;          // 12 bytes (累积吞吐量)
    float3 radiance;            // 12 bytes (累积辐射度)
    uint2 pixel_coord;          // 8 bytes (像素坐标)
    uint depth;                 // 4 bytes (当前深度)
    uint path_flags;            // 4 bytes (状态标志: active, specular, ...)
    float padding[1];           // 4 bytes (对齐到 64)
};

// 材质交互记录 - 128 bytes
struct MaterialInteraction {
    HitRecord hit_rec;          // 80 bytes
    uint material_index;        // 4 bytes
    uint light_index;           // 4 bytes (如果击中光源)
    float pdf_forward;          // 4 bytes (MIS PDF)
    uint bounce_type;           // 4 bytes (diffuse/specular/transmission)
    float padding[9];           // 36 bytes (对齐到 128)
};
```

**GPU 缓冲区** (Sources/GPU/GPUStructs.swift):
```swift
struct WavefrontBuffers {
    // 双缓冲光线队列（乒乓切换）
    var rayQueueA: MTLBuffer      // RayPayload[width * height * spp]
    var rayQueueB: MTLBuffer      // RayPayload[width * height * spp]

    // 材质交互缓冲
    var materialBuffer: MTLBuffer // MaterialInteraction[...]

    // 压缩计数（活跃光线数）
    var activeCounterA: MTLBuffer // atomic<uint>
    var activeCounterB: MTLBuffer // atomic<uint>

    // 像素累积缓冲（最终输出）
    var pixelAccumBuffer: MTLBuffer // float4[width * height]
}
```

#### B. 渲染流程

**总体架构** (Sources/Rendering/WavefrontRenderer.swift - 新文件):
```swift
class WavefrontRenderer {
    let context: MetalContext
    let buffers: WavefrontBuffers

    // Compute Pipeline States
    var generateRaysPipeline: MTLComputePipelineState      // Pass 1
    var traceRaysPipeline: MTLComputePipelineState         // Pass 2
    var shadeMaterialsPipeline: MTLComputePipelineState    // Pass 3
    var accumulatePipeline: MTLComputePipelineState        // Pass 4

    func render(scene: Scene, camera: Camera, bvh: FlatBVH) {
        for batch in 0..<batchCount {
            // Pass 1: 生成相机光线
            generateCameraRays(rayQueue: rayQueueA, camera: camera)

            var currentQueue = rayQueueA
            var nextQueue = rayQueueB

            // Pass 2-N: 迭代深度
            for depth in 0..<maxDepth {
                // 2a. 光线相交测试
                let hitCount = traceRays(
                    rays: currentQueue,
                    hits: materialBuffer,
                    bvh: bvh
                )

                if hitCount == 0 { break }  // 所有光线结束

                // 2b. 材质着色 + 生成新光线
                shadeAndScatter(
                    hits: materialBuffer,
                    inputRays: currentQueue,
                    outputRays: nextQueue,
                    depth: depth
                )

                // 2c. 交换队列（乒乓缓冲）
                swap(&currentQueue, &nextQueue)
            }

            // Pass 3: 累积到像素缓冲
            accumulateToPixels(rays: currentQueue)
        }
    }
}
```

**Pass 1: 生成相机光线** (Shaders/Kernels/WavefrontGenerate.metal - 新文件):
```metal
kernel void generate_camera_rays(
    device RayPayload* ray_queue [[buffer(0)]],
    device atomic_uint* active_counter [[buffer(1)]],
    constant CameraParams& camera [[buffer(2)]],
    constant RenderParams& params [[buffer(3)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= params.width || gid.y >= params.height) return;

    // 初始化随机数
    uint seed = hash(gid.x, gid.y, params.sample_offset);
    RandomState rng = random_init(seed);

    // 分层采样 + 像素滤波器
    float2 jitter = stratified_sample(&rng, params.sqrt_spp);
    float3 pixel_sample = compute_pixel_sample(camera, gid, jitter);

    // 景深效果
    float3 ray_origin = camera.origin;
    if (camera.defocus_angle > 0.0f) {
        float3 p = random_in_unit_disk(&rng);
        ray_origin += camera.defocus_disk_u * p.x + camera.defocus_disk_v * p.y;
    }

    // 写入光线队列
    uint ray_idx = gid.y * params.width + gid.x;
    ray_queue[ray_idx].ray.origin = ray_origin;
    ray_queue[ray_idx].ray.direction = normalize(pixel_sample - ray_origin);
    ray_queue[ray_idx].ray.time = 0.0f;
    ray_queue[ray_idx].throughput = float3(1.0f);
    ray_queue[ray_idx].radiance = float3(0.0f);
    ray_queue[ray_idx].pixel_coord = gid;
    ray_queue[ray_idx].depth = 0;
    ray_queue[ray_idx].path_flags = PATH_FLAG_ACTIVE;

    // 原子计数活跃光线数
    atomic_fetch_add_explicit(active_counter, 1, memory_order_relaxed);
}
```

**Pass 2: 光线相交测试** (Shaders/Kernels/WavefrontTrace.metal - 新文件):
```metal
kernel void trace_rays(
    device const RayPayload* ray_queue [[buffer(0)]],
    device MaterialInteraction* hit_buffer [[buffer(1)]],
    device atomic_uint* hit_counter [[buffer(2)]],
    device const GPUBVHNode* bvh_nodes [[buffer(3)]],
    device const uint* geometry_indices [[buffer(4)]],
    device const GPUSphere* spheres [[buffer(5)]],
    device const GPUQuad* quads [[buffer(6)]],
    device const GPUTransform* transforms [[buffer(7)]],
    constant RenderParams& params [[buffer(8)]],
    uint gid [[thread_position_in_grid]]
) {
    // 检查光线是否活跃
    if (gid >= params.ray_count) return;
    RayPayload payload = ray_queue[gid];
    if (!(payload.path_flags & PATH_FLAG_ACTIVE)) return;

    // BVH 相交测试
    HitRecord rec;
    bool hit = bvh_hit(
        bvh_nodes, geometry_indices,
        spheres, quads, transforms,
        params.sphere_count,
        payload.ray, 0.001f, 1e10f, &rec
    );

    if (hit) {
        // 写入交点信息
        uint hit_idx = atomic_fetch_add_explicit(hit_counter, 1, memory_order_relaxed);
        hit_buffer[hit_idx].hit_rec = rec;
        hit_buffer[hit_idx].material_index = rec.material_index;
        hit_buffer[hit_idx].ray_index = gid;  // 回溯到原光线
    } else {
        // 未击中任何物体 → 累积背景色，标记为非活跃
        uint pixel_idx = payload.pixel_coord.y * params.width + payload.pixel_coord.x;
        // 写入背景辐射度（原子操作或分离累积）
        // ...
        ray_queue[gid].path_flags &= ~PATH_FLAG_ACTIVE;
    }
}
```

**Pass 3: 材质着色与散射** (Shaders/Kernels/WavefrontShade.metal - 新文件):
```metal
kernel void shade_and_scatter(
    device const MaterialInteraction* hit_buffer [[buffer(0)]],
    device RayPayload* input_rays [[buffer(1)]],
    device RayPayload* output_rays [[buffer(2)]],
    device atomic_uint* output_counter [[buffer(3)]],
    device const GPUMaterial* materials [[buffer(4)]],
    device const GPUTexture* textures [[buffer(5)]],
    texture2d<float> image_texture [[texture(0)]],
    device const uint* light_indices [[buffer(6)]],
    constant RenderParams& params [[buffer(7)]],
    uint gid [[thread_position_in_grid]]
) {
    if (gid >= params.hit_count) return;

    MaterialInteraction hit = hit_buffer[gid];
    RayPayload payload = input_rays[hit.ray_index];

    // 初始化随机数（使用光线 ID + 深度）
    uint seed = hash(hit.ray_index, payload.depth);
    RandomState rng = random_init(seed);

    // 1. 累积发光项
    float3 emission = material_emitted(materials, textures, image_texture, hit.hit_rec);
    payload.radiance += payload.throughput * emission;

    // 2. 材质散射（MIS）
    ScatterRecord srec;
    if (!material_scatter_mis(materials, textures, hit.hit_rec, &srec, &rng)) {
        // 材质不散射（发光材质） → 结束路径
        payload.path_flags &= ~PATH_FLAG_ACTIVE;
        return;
    }

    // 3. 镜面反射快速路径
    if (srec.skip_pdf) {
        payload.throughput *= srec.attenuation;
        payload.ray = srec.skip_pdf_ray;
        payload.depth++;

        // 写入下一级队列
        uint out_idx = atomic_fetch_add_explicit(output_counter, 1, memory_order_relaxed);
        output_rays[out_idx] = payload;
        return;
    }

    // 4. MIS 采样（光源 + BRDF）
    float3 scattered_dir;
    if (params.lights_count > 0 && random_float(&rng) < 0.5f) {
        // 光源采样
        uint light_idx = uint(random_float(&rng) * params.lights_count) % params.lights_count;
        scattered_dir = sample_light_direction(light_indices[light_idx], hit.hit_rec.p, &rng);
    } else {
        // BRDF 采样
        scattered_dir = pdf_generate(srec.pdf, hit.hit_rec.p, &rng);
    }

    // 5. 计算吞吐量
    Ray scattered = {hit.hit_rec.p, scattered_dir, payload.ray.time};
    float light_pdf = compute_light_pdf(light_indices, scattered_dir, hit.hit_rec.p);
    float brdf_pdf = compute_brdf_pdf(srec.pdf, scattered_dir, hit.hit_rec.p);
    float scattering_pdf = material_scattering_pdf(materials, hit.hit_rec, scattered);

    float w_light = power_heuristic(light_pdf, brdf_pdf);
    float pdf_val = w_light * light_pdf + (1.0f - w_light) * brdf_pdf;

    payload.throughput *= srec.attenuation * (scattering_pdf / fmax(1e-6f, pdf_val));
    payload.ray = scattered;
    payload.depth++;

    // 6. Russian Roulette 终止判断
    if (payload.depth > 3) {
        float survival_prob = min(0.95f, max3(payload.throughput));
        if (random_float(&rng) > survival_prob) {
            payload.path_flags &= ~PATH_FLAG_ACTIVE;
            return;
        }
        payload.throughput /= survival_prob;
    }

    // 7. 写入下一级队列
    uint out_idx = atomic_fetch_add_explicit(output_counter, 1, memory_order_relaxed);
    output_rays[out_idx] = payload;
}
```

**Pass 4: 累积到像素** (Shaders/Kernels/WavefrontAccumulate.metal - 新文件):
```metal
kernel void accumulate_to_pixels(
    device const RayPayload* ray_queue [[buffer(0)]],
    texture2d<float, access::read_write> output [[texture(0)]],
    constant RenderParams& params [[buffer(1)]],
    uint gid [[thread_position_in_grid]]
) {
    if (gid >= params.ray_count) return;

    RayPayload payload = ray_queue[gid];
    uint2 pixel = payload.pixel_coord;

    // 读取累积颜色
    float4 prev_color = output.read(pixel);

    // 累积新的采样
    float3 new_color = prev_color.rgb + payload.radiance;

    // 写回
    output.write(float4(new_color, 1.0f), pixel);
}
```

### 2.3 内存管理与优化

#### A. 光线压缩（Stream Compaction）

**问题**: 随着深度增加，活跃光线数减少，但队列大小不变 → 浪费带宽

**解决方案**: 使用 Metal 的 `atomic_add` 实现流压缩

**实现** (Shaders/Common/StreamCompaction.metal - 新文件):
```metal
kernel void compact_rays(
    device const RayPayload* input_queue [[buffer(0)]],
    device RayPayload* output_queue [[buffer(1)]],
    device atomic_uint* output_counter [[buffer(2)]],
    constant uint& input_count [[buffer(3)]],
    uint gid [[thread_position_in_grid]]
) {
    if (gid >= input_count) return;

    RayPayload payload = input_queue[gid];

    // 只写入活跃光线
    if (payload.path_flags & PATH_FLAG_ACTIVE) {
        uint out_idx = atomic_fetch_add_explicit(output_counter, 1, memory_order_relaxed);
        output_queue[out_idx] = payload;
    }
}
```

#### B. 内存对齐优化

**缓冲区对齐** (Sources/GPU/GPUStructs.swift):
```swift
extension WavefrontBuffers {
    // 确保所有缓冲区 256-byte 对齐（Metal 最优）
    func createAlignedBuffer(length: Int) -> MTLBuffer? {
        let alignedLength = (length + 255) & ~255
        return context.device.makeBuffer(
            length: alignedLength,
            options: .storageModePrivate  // GPU 独占，最快
        )
    }
}
```

### 2.4 性能预测

**理论分析**:
```
假设场景: Cornell Box (600×600, 100 spp, max_depth=50)
总光线数: 600 × 600 × 100 = 36M primary rays

当前实现（迭代式）:
- 平均深度: ~5 bounce
- 线程束利用率: 25%
- 有效计算: 36M × 5 × 0.25 = 45M ray-bounce
- 渲染时间: 329 ms

Wavefront 实现:
- 深度 0: 36M rays (100% 利用率)
- 深度 1: 30M rays (83% 利用率)
- 深度 2: 20M rays (55% 利用率)
- 深度 3: 10M rays (28% 利用率)
- 深度 4: 3M rays (8% 利用率)
- 深度 5+: < 1M rays
- 平均利用率: ~60%
- 有效计算: 99M ray-bounce
- 预期渲染时间: 329 × (45/99) / 0.6 ≈ 150 ms
- 性能提升: 2.2×
```

**实际收益** (基于文献 [Laine et al. 2013]):
- 简单场景（平均 3-5 bounce）: +40% ～ +80%
- 复杂场景（平均 8-15 bounce）: +100% ～ +200%
- 实时模式（1-2 bounce）: +20% ～ +40%

### 2.5 实施步骤

#### 阶段 1: 基础架构（3-5 天）

1. **创建 Wavefront 数据结构** ✅
   - 新增 `Sources/GPU/WavefrontStructs.swift`
   - 定义 `RayPayload`, `MaterialInteraction`, `WavefrontBuffers`

2. **实现 Pass 1: 光线生成** ✅
   - 新增 `Shaders/Kernels/WavefrontGenerate.metal`
   - 移植现有的相机光线生成代码

3. **实现 Pass 2: 光线追踪** ✅
   - 新增 `Shaders/Kernels/WavefrontTrace.metal`
   - 复用现有的 `bvh_hit()` 函数

#### 阶段 2: 材质着色（2-3 天）

4. **实现 Pass 3: 材质散射** ✅
   - 新增 `Shaders/Kernels/WavefrontShade.metal`
   - 移植 MIS 采样逻辑

5. **实现 Pass 4: 像素累积** ✅
   - 新增 `Shaders/Kernels/WavefrontAccumulate.metal`
   - 支持双模式（离线 + 实时）

#### 阶段 3: 性能优化（2-3 天）

6. **流压缩优化** ✅
   - 新增 `Shaders/Common/StreamCompaction.metal`
   - 动态调整线程组大小

7. **内存优化** ✅
   - 缓冲区乒乓切换
   - 对齐优化 (256-byte)

#### 阶段 4: 集成与测试（2-3 天）

8. **创建 WavefrontRenderer** ✅
   - 新增 `Sources/Rendering/WavefrontRenderer.swift`
   - 集成到 `main.swift`

9. **命令行参数** ✅
   - 添加 `--wavefront` 开关
   - 性能对比测试

10. **性能验证** ✅
    - 对比基准测试
    - 生成性能报告

**总计**: 9-14 天（全职开发）

---

## 三、BDPT 双向路径追踪 (高级优化)

### 3.1 核心思想

**传统路径追踪**:
```
相机 → Bounce1 → Bounce2 → ... → 光源
问题: 光源被遮挡时，无法有效采样（如间接照明）
```

**BDPT (Bidirectional Path Tracing)**:
```
路径 1 (从相机): Camera → A → B → C
路径 2 (从光源): Light → X → Y → Z

连接所有可能的顶点对:
- Camera-Light (直接照明)
- Camera-A-X-Light
- Camera-A-B-Y-Light
- Camera-A-B-C-Z-Light
- ...

优势: 多种采样策略组合，收敛速度快 3-10×
```

### 3.2 技术架构

#### A. 数据结构设计

**路径顶点** (Shaders/Common/Types.metal):
```metal
// 路径顶点（Path Vertex）- 128 bytes
struct PathVertex {
    float3 position;            // 12 bytes
    float3 normal;              // 12 bytes
    float3 wo;                  // 12 bytes (出射方向)
    float3 throughput;          // 12 bytes (累积吞吐量)
    uint material_index;        // 4 bytes
    uint vertex_type;           // 4 bytes (surface/light/camera)
    float pdf_forward;          // 4 bytes (前向 PDF)
    float pdf_reverse;          // 4 bytes (反向 PDF)
    uint is_delta;              // 4 bytes (镜面顶点标志)
    float3 emission;            // 12 bytes (发光项)
    float2 uv;                  // 8 bytes (纹理坐标)
    float padding[7];           // 28 bytes (对齐到 128)
};

// 路径存储
struct PathStorage {
    PathVertex vertices[MAX_PATH_LENGTH];  // 最大 16 个顶点
    uint vertex_count;                     // 当前顶点数
    uint padding[3];
};
```

**连接缓冲区** (Sources/GPU/GPUStructs.swift):
```swift
struct BDPTBuffers {
    // 相机路径（每个像素一条）
    var cameraPathsBuffer: MTLBuffer  // PathStorage[width * height]

    // 光源路径（共享，数量 = spp）
    var lightPathsBuffer: MTLBuffer   // PathStorage[light_path_count]

    // 连接贡献（临时）
    var connectionBuffer: MTLBuffer   // float3[width * height * strategies]

    // MIS 权重缓存
    var misWeightBuffer: MTLBuffer    // float[strategies]
}
```

#### B. 渲染流程

**总体架构** (Sources/Rendering/BDPTRenderer.swift - 新文件):
```swift
class BDPTRenderer {
    let context: MetalContext
    let buffers: BDPTBuffers

    // Compute Pipeline States
    var generateCameraPathsPipeline: MTLComputePipelineState
    var generateLightPathsPipeline: MTLComputePipelineState
    var connectPathsPipeline: MTLComputePipelineState
    var accumulateBDPTPipeline: MTLComputePipelineState

    func render(scene: Scene, camera: Camera, bvh: FlatBVH) {
        for batch in 0..<batchCount {
            // Pass 1: 生成光源路径（共享，每 SPP 一条）
            generateLightPaths(count: lightPathCount, bvh: bvh)

            // Pass 2: 生成相机路径（每像素一条）
            generateCameraPaths(camera: camera, bvh: bvh)

            // Pass 3: 连接路径并计算贡献
            connectAndEvaluate(
                cameraPaths: cameraPathsBuffer,
                lightPaths: lightPathsBuffer,
                output: connectionBuffer
            )

            // Pass 4: MIS 加权累积
            accumulateWithMIS(
                connections: connectionBuffer,
                output: outputTexture
            )
        }
    }
}
```

**Pass 1: 生成光源路径** (Shaders/Kernels/BDPTLightPath.metal - 新文件):
```metal
kernel void generate_light_paths(
    device PathStorage* light_paths [[buffer(0)]],
    device const GPUSphere* spheres [[buffer(1)]],
    device const GPUQuad* quads [[buffer(2)]],
    device const GPUMaterial* materials [[buffer(3)]],
    device const GPUBVHNode* bvh_nodes [[buffer(4)]],
    device const uint* light_indices [[buffer(5)]],
    constant RenderParams& params [[buffer(6)]],
    uint gid [[thread_position_in_grid]]
) {
    if (gid >= params.light_path_count) return;

    // 初始化随机数
    uint seed = hash(gid, params.sample_offset);
    RandomState rng = random_init(seed);

    PathStorage path;
    path.vertex_count = 0;

    // 1. 采样光源起点
    uint light_idx = uint(random_float(&rng) * params.lights_count) % params.lights_count;
    uint geom_idx = light_indices[light_idx];

    float3 light_pos, light_normal;
    float light_area, light_pdf;
    sample_light_surface(geom_idx, spheres, quads, &rng, &light_pos, &light_normal, &light_area);

    // 顶点 0: 光源表面
    PathVertex v0;
    v0.position = light_pos;
    v0.normal = light_normal;
    v0.throughput = float3(1.0f);
    v0.emission = materials[light_mat_idx].emission;
    v0.vertex_type = VERTEX_LIGHT;
    v0.pdf_forward = 1.0f / light_area;
    path.vertices[path.vertex_count++] = v0;

    // 2. 采样光源出射方向（余弦加权）
    float3 wo = sample_cosine_hemisphere(light_normal, &rng);
    Ray ray = {light_pos, wo, 0.0f};
    float3 throughput = materials[light_mat_idx].emission * M_PI_F;  // BRDF * cos(θ) / PDF

    // 3. 迭代追踪光源路径
    for (uint depth = 1; depth < params.max_depth; depth++) {
        HitRecord rec;
        if (!bvh_hit(bvh_nodes, ..., ray, 0.001f, 1e10f, &rec)) {
            break;  // 击中天空
        }

        // 顶点 i: 表面交点
        PathVertex vi;
        vi.position = rec.p;
        vi.normal = rec.normal;
        vi.wo = -ray.direction;
        vi.throughput = throughput;
        vi.material_index = rec.material_index;
        vi.vertex_type = VERTEX_SURFACE;

        // 计算前向/反向 PDF
        vi.pdf_forward = compute_pdf(...);
        vi.pdf_reverse = compute_reverse_pdf(...);

        path.vertices[path.vertex_count++] = vi;

        // 材质散射
        ScatterRecord srec;
        if (!material_scatter_mis(materials, ..., &srec, &rng)) {
            break;
        }

        // 生成新光线
        float3 wi = pdf_generate(srec.pdf, rec.p, &rng);
        ray = Ray{rec.p, wi, 0.0f};

        // 更新吞吐量
        float pdf_val = pdf_value(srec.pdf, wi, rec.p);
        float scatter_pdf = material_scattering_pdf(materials, rec, ray);
        throughput *= srec.attenuation * (scatter_pdf / fmax(1e-6f, pdf_val));
    }

    light_paths[gid] = path;
}
```

**Pass 2: 生成相机路径** (类似，省略)

**Pass 3: 连接路径** (Shaders/Kernels/BDPTConnect.metal - 新文件):
```metal
kernel void connect_paths(
    device const PathStorage* camera_paths [[buffer(0)]],
    device const PathStorage* light_paths [[buffer(1)]],
    device float3* connection_buffer [[buffer(2)]],  // [pixel][strategy]
    device const GPUBVHNode* bvh_nodes [[buffer(3)]],
    constant RenderParams& params [[buffer(4)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= params.width || gid.y >= params.height) return;

    uint pixel_idx = gid.y * params.width + gid.x;
    PathStorage camera_path = camera_paths[pixel_idx];

    // 遍历所有连接策略: s + t = total_length
    // s = 相机路径长度, t = 光源路径长度
    uint strategy_idx = 0;
    for (uint s = 1; s <= camera_path.vertex_count; s++) {
        for (uint t = 0; t <= params.max_light_path_length; t++) {
            if (s + t > params.max_depth) continue;

            // 特殊情况处理
            if (t == 0) {
                // 直接击中光源（传统路径追踪）
                float3 contrib = evaluate_camera_only(camera_path, s);
                connection_buffer[pixel_idx * MAX_STRATEGIES + strategy_idx] = contrib;
            } else {
                // 连接两条路径
                PathStorage light_path = light_paths[t % params.light_path_count];
                float3 contrib = connect_and_evaluate(
                    camera_path, s,
                    light_path, t,
                    bvh_nodes, params
                );
                connection_buffer[pixel_idx * MAX_STRATEGIES + strategy_idx] = contrib;
            }

            strategy_idx++;
        }
    }
}

// 连接两个顶点并计算贡献
inline float3 connect_and_evaluate(
    PathStorage camera_path, uint s,
    PathStorage light_path, uint t,
    device const GPUBVHNode* bvh_nodes,
    constant RenderParams& params
) {
    PathVertex camera_vertex = camera_path.vertices[s - 1];
    PathVertex light_vertex = light_path.vertices[t - 1];

    // 1. 连接向量
    float3 connection = light_vertex.position - camera_vertex.position;
    float dist = length(connection);
    float3 wi = connection / dist;

    // 2. 可见性测试（shadow ray）
    Ray shadow_ray = {camera_vertex.position, wi, 0.0f};
    HitRecord shadow_rec;
    if (bvh_hit(bvh_nodes, ..., shadow_ray, 0.001f, dist - 0.001f, &shadow_rec)) {
        return float3(0.0f);  // 被遮挡
    }

    // 3. 计算几何项
    float cos_camera = fabs(dot(camera_vertex.normal, wi));
    float cos_light = fabs(dot(light_vertex.normal, -wi));
    float G = (cos_camera * cos_light) / (dist * dist);

    // 4. BRDF 评估
    float3 f_camera = evaluate_brdf(camera_vertex, wi);
    float3 f_light = evaluate_brdf(light_vertex, -wi);

    // 5. 合并吞吐量
    float3 throughput = camera_vertex.throughput * f_camera * G * f_light * light_vertex.throughput;

    // 6. MIS 权重（Balance Heuristic）
    float weight = compute_mis_weight(camera_path, s, light_path, t, params);

    return throughput * weight;
}
```

**Pass 4: MIS 累积** (Shaders/Kernels/BDPTAccumulate.metal - 新文件):
```metal
kernel void accumulate_bdpt(
    device const float3* connection_buffer [[buffer(0)]],
    texture2d<float, access::read_write> output [[texture(0)]],
    constant RenderParams& params [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= params.width || gid.y >= params.height) return;

    uint pixel_idx = gid.y * params.width + gid.x;

    // 累加所有连接策略的贡献
    float3 total_contrib = float3(0.0f);
    for (uint i = 0; i < params.strategy_count; i++) {
        total_contrib += connection_buffer[pixel_idx * MAX_STRATEGIES + i];
    }

    // 累积到输出纹理
    float4 prev_color = output.read(gid);
    float3 new_color = prev_color.rgb + total_contrib;
    output.write(float4(new_color, 1.0f), gid);
}
```

### 3.3 MIS 权重计算

**Balance Heuristic** (最优 MIS 权重):
```metal
inline float compute_mis_weight(
    PathStorage camera_path, uint s,
    PathStorage light_path, uint t,
    constant RenderParams& params
) {
    // 当前策略 (s, t) 的 PDF
    float pdf_current = compute_strategy_pdf(camera_path, s, light_path, t);

    // 所有其他策略的 PDF
    float sum_pdf = pdf_current;
    for (uint s_alt = 1; s_alt <= params.max_depth; s_alt++) {
        for (uint t_alt = 0; t_alt <= params.max_light_path_length; t_alt++) {
            if (s_alt + t_alt != s + t) continue;  // 路径长度相同
            if (s_alt == s && t_alt == t) continue;  // 跳过自己

            float pdf_alt = compute_strategy_pdf_alt(
                camera_path, s, s_alt,
                light_path, t, t_alt
            );
            sum_pdf += pdf_alt;
        }
    }

    // Balance Heuristic: w = p_i / Σp_j
    return pdf_current / sum_pdf;
}
```

### 3.4 性能与质量权衡

**计算复杂度**:
```
设最大路径长度 = N
传统路径追踪: O(N) per pixel
BDPT: O(N²) per pixel （需要评估 N×N 个连接策略）

实际开销:
- 传统: 1× 计算
- BDPT: ~4× 计算（因为很多连接可以剪枝）
```

**质量提升**:
```
场景类型 | 传统 PT 收敛时间 | BDPT 收敛时间 | 加速比
---------|-----------------|--------------|--------
直接照明 | 基准 (1×)       | 1.2× (略慢)   | 0.83×
间接照明 | 10×             | 2×           | 5×
焦散     | 100×            | 10×          | 10×
复杂遮挡 | 50×             | 5×           | 10×
```

**适用场景**:
- ✅ **强烈推荐**: 间接照明复杂（如室内场景）
- ✅ **推荐**: 小光源 + 复杂几何（如Cornell Box）
- ⚠️ **谨慎**: 直接照明为主（开销大于收益）
- ❌ **不推荐**: 实时渲染（计算量太大）

### 3.5 实施步骤

#### 阶段 1: 基础架构（5-7 天）

1. **创建 BDPT 数据结构** ✅
   - 新增 `Sources/GPU/BDPTStructs.swift`
   - 定义 `PathVertex`, `PathStorage`, `BDPTBuffers`

2. **实现光源路径生成** ✅
   - 新增 `Shaders/Kernels/BDPTLightPath.metal`
   - 支持光源采样 + 路径追踪

3. **实现相机路径生成** ✅
   - 新增 `Shaders/Kernels/BDPTCameraPath.metal`
   - 复用 Wavefront 的光线追踪代码

#### 阶段 2: 路径连接（7-10 天）

4. **实现路径连接算法** ✅
   - 新增 `Shaders/Kernels/BDPTConnect.metal`
   - 可见性测试 + BRDF 评估

5. **实现 MIS 权重计算** ✅
   - 新增 `Shaders/Common/BDPTMIS.metal`
   - Balance Heuristic 实现

6. **实现贡献累积** ✅
   - 新增 `Shaders/Kernels/BDPTAccumulate.metal`
   - 多策略加权求和

#### 阶段 3: 优化与调试（5-7 天）

7. **连接策略剪枝** ✅
   - 跳过无效连接（镜面顶点、背面）
   - 自适应策略选择

8. **内存优化** ✅
   - 路径存储压缩
   - 连接缓冲区复用

9. **光源重要性采样** ✅
   - 根据场景自动选择光源路径数量
   - 多光源加权采样

#### 阶段 4: 集成与验证（3-5 天）

10. **创建 BDPTRenderer** ✅
    - 新增 `Sources/Rendering/BDPTRenderer.swift`
    - 集成到 `main.swift`

11. **命令行参数** ✅
    - 添加 `--bdpt` 开关
    - `--light-paths <count>` 参数

12. **质量验证** ✅
    - 对比渲染结果（MSE、PSNR）
    - 生成收敛曲线

**总计**: 20-29 天（全职开发）

---

## 四、实施建议与优先级

### 4.1 推荐实施顺序

#### 方案 A: 逐步优化（推荐）

1. **Phase 10a: Wavefront Path Tracing** (2-3 周)
   - 优先级: ⭐⭐⭐⭐⭐
   - 收益: 立即可见（性能提升 40%-100%）
   - 风险: 低（技术成熟，实现难度中等）
   - 适用: 所有场景（离线 + 实时）

2. **Phase 10b: BDPT** (3-4 周，可选)
   - 优先级: ⭐⭐⭐
   - 收益: 特定场景显著（间接照明复杂场景）
   - 风险: 中（实现复杂，调试困难）
   - 适用: 离线渲染

#### 方案 B: 混合实施（高级用户）

- **Wavefront + BDPT 结合**: 使用 Wavefront 架构生成 BDPT 的相机/光源路径
- **优势**: 最大化 GPU 利用率 + 最优收敛速度
- **难度**: ⭐⭐⭐⭐⭐（需要深度理解两种算法）

### 4.2 性能基准测试

**测试场景**:
```
场景 1: Cornell Box (600×600, 100 spp)
场景 2: Bouncing Spheres (800×450, 10 spp)
场景 3: Final Scene (400×400, 10 spp)
```

**对比指标**:
```
1. 渲染时间（总时间、per-sample 时间）
2. GPU 利用率（Metal System Trace）
3. 内存带宽（读/写峰值）
4. 图像质量（MSE vs 参考图）
```

**预期结果**:
```
| 场景 | 当前 (ms) | Wavefront (ms) | BDPT (ms) | Wavefront+BDPT (ms) |
|------|-----------|----------------|-----------|---------------------|
| Cornell | 329 | 180 (-45%) | 450 (+37%) | 250 (-24%) |
| Bouncing | 82 | 50 (-39%) | N/A | N/A |
| Final | 60 | 35 (-42%) | N/A | N/A |
```

### 4.3 命令行参数设计

**Wavefront 模式**:
```bash
# 启用 Wavefront（默认关闭）
swift run raytracer --wavefront --scene cornellBox --spp 100

# 流压缩阈值（活跃光线占比 < threshold 时执行压缩）
swift run raytracer --wavefront --compact-threshold 0.5

# 调试模式（输出每个 Pass 的光线数）
swift run raytracer --wavefront --debug-passes
```

**BDPT 模式**:
```bash
# 启用 BDPT（默认关闭）
swift run raytracer --bdpt --scene cornellBox --spp 100

# 光源路径数量（默认 = spp）
swift run raytracer --bdpt --light-paths 1000

# 最大连接深度（默认 = max_depth）
swift run raytracer --bdpt --max-connect-depth 10

# 连接策略剪枝（跳过低贡献策略）
swift run raytracer --bdpt --prune-strategies --prune-threshold 0.01
```

**组合使用**:
```bash
# Wavefront + BDPT（终极性能）
swift run raytracer --wavefront --bdpt --scene cornellBox --spp 100 --light-paths 500
```

### 4.4 潜在风险与缓解

#### 风险 1: 内存开销大

**问题**: Wavefront 需要存储所有光线状态 (width × height × spp × 64 bytes)
```
示例: 800×800, 100 spp
内存: 800 × 800 × 100 × 64 = 4 GB
```

**缓解**:
- 使用流压缩减少活跃光线数
- 分批处理 SPP（如 10 spp/batch）
- 使用 `storageModePrivate`（GPU 独占，更快）

#### 风险 2: BDPT 调试困难

**问题**: 路径连接逻辑复杂，容易出现能量不守恒、黑点、萤火虫等问题

**缓解**:
- 先实现单一策略（如 s=1, t=1），验证正确性
- 使用已知参考图像对比（Cornell Box 官方数据）
- 增加详细日志输出（每个策略的贡献值）

#### 风险 3: 性能提升不达预期

**问题**: 某些场景可能不适合 Wavefront/BDPT

**缓解**:
- 提供降级选项（`--fallback-traditional`）
- 根据场景特征自动选择算法
- 用户可通过命令行强制指定模式

---

## 五、技术参考资料

### 5.1 学术论文

**Wavefront Path Tracing**:
1. Laine, S., Karras, T., & Aila, T. (2013). "Megakernels Considered Harmful: Wavefront Path Tracing on GPUs". *HPG 2013*.
2. Áfra, A. T., Benthin, C., Wald, I., & Woop, S. (2016). "Embree Ray Tracing Kernels: Overview and New Features". *SIGGRAPH 2016 Talks*.

**BDPT**:
1. Veach, E., & Guibas, L. J. (1995). "Optimally Combining Sampling Techniques for Monte Carlo Rendering". *SIGGRAPH 1995*.
2. Lafortune, E. P., & Willems, Y. D. (1993). "Bi-Directional Path Tracing". *CompuGraphics 1993*.

**MIS (Multiple Importance Sampling)**:
1. Veach, E. (1997). "Robust Monte Carlo Methods for Light Transport Simulation". PhD Thesis, Stanford University.

### 5.2 开源实现参考

**Wavefront**:
- NVIDIA OptiX 7+ (SDK 示例: `optixPathTracer`)
- Intel Embree (CPU Wavefront)
- Blender Cycles (GPU 分层渲染)

**BDPT**:
- PBRT-v3 (`src/integrators/bdpt.cpp`)
- Mitsuba Renderer 2 (`src/integrators/bdpt/`)
- SmallVCM (参考实现)

### 5.3 Metal 性能优化资源

1. Apple WWDC 2022: "Discover Metal 3"
2. Apple Metal Best Practices Guide (2023)
3. GPU Gems 3, Chapter 29: "Real-Time Global Illumination Using Precomputed Light Field Probes"

---

## 六、预期成果与验证

### 6.1 性能基准对比

**测试配置**:
```
硬件: M1 Max (32 GPU cores, 400 GB/s 带宽)
场景: Cornell Box (600×600, 100 spp, max_depth=50)
```

**性能对比表**:
```
| 实现方式 | 渲染时间 | GPU 利用率 | 内存带宽 | 加速比 |
|---------|---------|-----------|---------|--------|
| 当前 (Phase 9) | 329 ms | 25% | 120 GB/s | 1.0× |
| + Wavefront | 180 ms | 60% | 280 GB/s | 1.83× |
| + BDPT | 450 ms | 30% | 150 GB/s | 0.73× |
| + Wavefront+BDPT | 250 ms | 55% | 260 GB/s | 1.32× |
```

### 6.2 图像质量验证

**BDPT 收敛速度测试** (Cornell Box):
```
SPP | 传统 PT MSE | BDPT MSE | 收敛加速
----|------------|----------|----------
10  | 0.120      | 0.045    | 2.7×
50  | 0.025      | 0.008    | 3.1×
100 | 0.010      | 0.002    | 5.0×
500 | 0.002      | 0.0003   | 6.7×
```

### 6.3 最终文档产出

1. **实现文档**: `docs/phase10_wavefront.md`, `docs/phase10_bdpt.md`
2. **性能报告**: `docs/phase10_performance_report.md`
3. **用户指南**: 更新 `CLAUDE.md` 添加新参数说明
4. **测试结果**: `tests/wavefront_comparison.txt`, `tests/bdpt_quality.txt`

---

## 七、总结

### 7.1 实施优先级

**立即实施 (Phase 10a)**:
- ✅ **Wavefront Path Tracing**: 性能提升显著，适用所有场景

**可选实施 (Phase 10b)**:
- ⚠️ **BDPT**: 特定场景受益，实现复杂度高，建议在 Wavefront 完成后评估

### 7.2 技术要点

**Wavefront**:
- 核心思想: 按深度分层，消除线程束分歧
- 关键技术: 光线队列、流压缩、乒乓缓冲
- 预期收益: +40% ～ +100% 性能

**BDPT**:
- 核心思想: 双向路径 + 多策略连接 + MIS 加权
- 关键技术: 路径存储、可见性测试、Balance Heuristic
- 预期收益: 3× ～ 10× 收敛速度（特定场景）

### 7.3 开发时间估算

```
Wavefront Path Tracing: 2-3 周
BDPT: 3-4 周
总计: 5-7 周（如果全部实施）
```

---

**文档版本**: v1.0
**创建日期**: 2025-12-11
**作者**: Claude Code
**状态**: 设计完成，待实施
