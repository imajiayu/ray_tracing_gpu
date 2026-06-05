# Wavefront + 多通道AOV自适应采样 + Tile-Based 渲染实现计划

**项目**: Ray Tracing GPU
**目标**: 大规模架构改造，实现三大特性
**预估工作量**: 8-12天（分10个阶段）
**创建时间**: 2025-12-16

---

## 📋 改造目标

### 1. Wavefront Path Tracing
**当前问题**: Per-pixel path tracing导致GPU线程分化严重
- 每个线程处理一个像素的完整路径（0-50次bounce）
- 不同像素的路径长度差异大→部分warp空闲→GPU占用率低

**改造方案**: Wavefront/Stream Path Tracing
- 将光线按深度分层处理（depth-by-depth）
- 每个kernel只处理一次bounce，光线池化
- 活跃光线动态压缩（stream compaction）
- GPU占用率提升30-50%

### 2. 多通道AOV自适应采样
**当前问题**: 单一beauty通道方差无法精确判断收敛
- 不同材质的噪声特性不同（diffuse vs specular）
- 当前的材质加权估计不够准确

**改造方案**: 多通道AOV + 精确方差计算
- 分离渲染通道：Diffuse / Specular / Transmission / Volume / Emission
- 每个通道独立计算方差
- 使用最大通道方差判断收敛
- 自适应采样精度提升20-40%

### 3. Tile-Based 渲染
**当前问题**: 全图渲染内存占用大，缓存局部性差

**改造方案**: 图像分块渲染
- 将图像分成64×64或128×128的tile
- 每个tile独立管理自适应采样
- 支持分布式渲染（未来扩展）
- 内存占用降低，缓存命中率提升

---

## 🏗️ 架构设计

### 核心数据结构

```swift
// 光线池（Wavefront）
struct RayPool {
    var rays: MTLBuffer              // Ray[MAX_RAYS]
    var throughputs: MTLBuffer       // float3[MAX_RAYS]
    var pixelIndices: MTLBuffer      // uint[MAX_RAYS]
    var activeCount: MTLBuffer       // atomic<uint>（活跃光线数）
    var depth: Int                   // 当前深度
}

// AOV累积缓冲区（每个tile）
struct AOVBuffers {
    // Beauty = diffuse + specular + transmission + volume + emission
    var beautySum: MTLBuffer         // float4[tilePixels]
    var beautySumSq: MTLBuffer       // float4[tilePixels]

    // 分解通道
    var diffuseSum: MTLBuffer        // float4[tilePixels]
    var diffuseSumSq: MTLBuffer
    var specularSum: MTLBuffer
    var specularSumSq: MTLBuffer
    var transmissionSum: MTLBuffer
    var transmissionSumSq: MTLBuffer
    var volumeSum: MTLBuffer
    var volumeSumSq: MTLBuffer
    var emissionSum: MTLBuffer
    var emissionSumSq: MTLBuffer

    // 辅助通道（用于降噪，可选）
    var albedoSum: MTLBuffer         // 首次bounce反照率
    var normalSum: MTLBuffer         // 首次bounce法线
    var depthSum: MTLBuffer          // 首次相交深度

    // 采样计数和收敛状态
    var sampleCount: MTLBuffer       // uint[tilePixels]
    var variance: MTLBuffer          // float[tilePixels]（最大通道方差）
    var convergedFlags: MTLBuffer    // uint[tilePixels]
}

// Tile管理器
struct TileManager {
    var tileSize: Int                // 64 或 128
    var tilesX: Int
    var tilesY: Int
    var tiles: [Tile]

    struct Tile {
        var x: Int, y: Int           // tile位置
        var width: Int, height: Int  // tile尺寸（边缘tile可能更小）
        var aovBuffers: AOVBuffers
        var converged: Bool
        var averageSpp: Float
    }
}
```

### 渲染流程（Wavefront + AOV + Tile）

```
对于每个 Tile (64×64):
    初始化 AOV 缓冲区

    对于每个采样批次 (batch_size = 8):
        # 阶段1: 生成初始光线
        GenerateCameraRays() → RayPool[depth=0]

        # 阶段2: Wavefront路径追踪（迭代至max_depth）
        for depth in 0..<max_depth:
            if RayPool.activeCount == 0: break

            # 2.1 相交测试（BVH遍历）
            IntersectKernel(RayPool) → HitRecords

            # 2.2 着色和散射（分AOV通道累积）
            ShadeAndScatterKernel(RayPool, HitRecords) → {
                - 累积各AOV通道（diffuse/specular/transmission...）
                - 生成新光线
                - 压缩活跃光线（stream compaction）
            }

            depth++

        # 阶段3: 累积到自适应缓冲区
        AccumulateAOVKernel(aov_textures, aovBuffers, batch_size)

        # 阶段4: 计算方差并判断收敛（checkpoint）
        if current_spp % checkpoint_interval == 0:
            ComputeVarianceAOV(aovBuffers) → max_channel_variance
            UpdateConvergenceFlags(variance, threshold)

            if all_pixels_converged:
                break

    # 阶段5: 合成最终图像
    ComposeFinalImage(aovBuffers) → tile_pixels
```

---

## 📝 实施步骤（10个阶段）

### **阶段0: 代码审计与准备工作** ⏱️ 0.5天

**目标**: 全面理解现有代码，建立测试基线

**任务**:
1. ✅ 代码审计
   - [ ] 绘制当前渲染流程图（per-pixel path tracing）
   - [ ] 识别需要重构的核心模块
   - [ ] 列出与现有功能的兼容性要求

2. ✅ 建立测试基线
   - [ ] 记录当前性能数据（Cornell Box, Bouncing Spheres, Final Scene）
   - [ ] 记录当前自适应采样效果（样本节省率、收敛精度）
   - [ ] 保存参考图像（用于验证改造后的视觉一致性）

3. ✅ 创建开发分支
   ```bash
   git checkout -b feature/wavefront-aov-tile
   git add docs/wavefront_aov_tile_implementation_plan.md
   git commit -m "docs: add wavefront+aov+tile implementation plan"
   ```

**验收标准**:
- 有完整的性能基线数据（渲染时间、样本节省率）
- 有参考图像用于回归测试
- 代码审计文档完成

---

### **阶段1: 重构GPU数据结构** ⏱️ 0.5天

**目标**: 扩展GPU结构体以支持Wavefront和AOV

**文件修改**:
- `Sources/GPU/GPUStructs.swift`
- `Shaders/Common/Types.metal`

**任务**:
1. ✅ 定义Wavefront光线池结构
   ```swift
   // Swift端
   struct WavefrontRay {
       var origin: SIMD3<Float>        // 12 bytes
       var direction: SIMD3<Float>     // 12 bytes
       var throughput: SIMD3<Float>    // 12 bytes（路径吞吐量）
       var pixelIndex: UInt32          // 4 bytes
       var depth: UInt32               // 4 bytes
       var time: Float                 // 4 bytes
       var padding: SIMD2<Float>       // 8 bytes
   }  // Total: 64 bytes

   struct WavefrontHitRecord {
       var p: SIMD3<Float>             // 相交点
       var normal: SIMD3<Float>        // 法线
       var t: Float                    // 距离
       var materialIndex: UInt32       // 材质索引
       var frontFace: UInt32           // 是否正面
       var u: Float, v: Float          // 纹理坐标
       var pixelIndex: UInt32          // 对应像素索引
       // ... 对齐到64 bytes
   }
   ```

2. ✅ 定义AOV输出通道结构（已在Types.metal中，需验证）
   ```metal
   // 确认AOVOutput结构完整性
   struct AOVOutput {
       float3 beauty;
       float3 diffuse;
       float3 specular;
       float3 transmission;
       float3 volume;
       float3 emission;
       float3 albedo;
       float3 normal;
       float depth;
   };
   ```

3. ✅ 定义Tile参数结构
   ```swift
   struct TileParams {
       var tileX: UInt32
       var tileY: UInt32
       var tileWidth: UInt32
       var tileHeight: UInt32
       var tileSizeX: UInt32  // 全局tile尺寸（如64）
       var tileSizeY: UInt32
       var imageWidth: UInt32
       var imageHeight: UInt32
   }  // 32 bytes
   ```

**验收标准**:
- Swift和Metal端结构体完全对齐（使用`MemoryLayout<T>.stride`验证）
- 编译通过，无对齐警告
- 单元测试：创建和传输结构体缓冲区成功

---

### **阶段2: 实现Wavefront光线生成与压缩** ⏱️ 1天

**目标**: 实现wavefront的基础设施（光线池管理）

**新建文件**:
- `Shaders/Kernels/Wavefront.metal`
- `Sources/Rendering/WavefrontRenderer.swift`

**任务**:
1. ✅ 实现初始光线生成kernel
   ```metal
   // Wavefront.metal
   kernel void generate_camera_rays(
       device WavefrontRay* ray_pool [[buffer(0)]],
       device atomic_uint* active_count [[buffer(1)]],
       constant CameraParams& camera [[buffer(2)]],
       constant TileParams& tile [[buffer(3)]],
       constant uint& samples_per_pixel [[buffer(4)]],
       uint2 gid [[thread_position_in_grid]]
   ) {
       // 仅为当前tile内的像素生成光线
       uint tile_pixel_x = gid.x;
       uint tile_pixel_y = gid.y;

       if (tile_pixel_x >= tile.tileWidth || tile_pixel_y >= tile.tileHeight) return;

       // 计算全局像素坐标
       uint global_x = tile.tileX + tile_pixel_x;
       uint global_y = tile.tileY + tile_pixel_y;

       // 分层采样（与现有逻辑一致）
       uint sqrt_spp = uint(sqrt(float(samples_per_pixel)));
       for (uint s_j = 0; s_j < sqrt_spp; s_j++) {
           for (uint s_i = 0; s_i < sqrt_spp; s_i++) {
               // 生成相机光线
               // ... 与现有raytrace kernel的逻辑类似

               // 写入光线池
               uint ray_idx = atomic_fetch_add_explicit(active_count, 1, memory_order_relaxed);
               ray_pool[ray_idx].origin = ray_origin;
               ray_pool[ray_idx].direction = ray_direction;
               ray_pool[ray_idx].throughput = float3(1.0);
               ray_pool[ray_idx].pixelIndex = global_y * tile.imageWidth + global_x;
               ray_pool[ray_idx].depth = 0;
           }
       }
   }
   ```

2. ✅ 实现光线压缩kernel（stream compaction）
   ```metal
   kernel void compact_active_rays(
       device const WavefrontRay* input_rays [[buffer(0)]],
       device const uint* active_flags [[buffer(1)]],  // 1=继续追踪, 0=终止
       device WavefrontRay* output_rays [[buffer(2)]],
       device atomic_uint* output_count [[buffer(3)]],
       constant uint& input_count [[buffer(4)]],
       uint gid [[thread_position_in_grid]]
   ) {
       if (gid >= input_count) return;

       if (active_flags[gid] == 1) {
           uint out_idx = atomic_fetch_add_explicit(output_count, 1, memory_order_relaxed);
           output_rays[out_idx] = input_rays[gid];
       }
   }
   ```

3. ✅ Swift端光线池管理器
   ```swift
   // WavefrontRenderer.swift
   class WavefrontRayPool {
       let maxRays: Int  // 例如: tileWidth * tileHeight * max_spp
       var rayBuffer: MTLBuffer
       var hitRecordBuffer: MTLBuffer
       var activeCountBuffer: MTLBuffer
       var activeFlagsBuffer: MTLBuffer

       func reset() {
           // 重置活跃计数为0
           activeCountBuffer.contents().storeBytes(of: UInt32(0), as: UInt32.self)
       }

       func getActiveCount() -> Int {
           return Int(activeCountBuffer.contents().load(as: UInt32.self))
       }
   }
   ```

**验收标准**:
- 能够为一个64×64 tile生成初始光线（64×64×4 = 16,384条光线，假设4 spp）
- Stream compaction正确（活跃光线数逐层递减）
- 性能测试：光线压缩overhead < 0.5ms @ 16K光线

---

### **阶段3: 实现Wavefront相交测试** ⏱️ 1天

**目标**: 将BVH遍历改造为批量光线模式

**文件修改**:
- `Shaders/Kernels/Wavefront.metal`（新增kernel）
- `Shaders/Common/Acceleration.metal`（可能需要小幅修改）

**任务**:
1. ✅ 实现批量相交测试kernel
   ```metal
   kernel void intersect_rays(
       device const WavefrontRay* rays [[buffer(0)]],
       device WavefrontHitRecord* hit_records [[buffer(1)]],
       constant uint& ray_count [[buffer(2)]],
       device const GPUBVHNode* bvh_nodes [[buffer(3)]],
       device const uint* geometry_indices [[buffer(4)]],
       device const GPUSphere* spheres [[buffer(5)]],
       device const GPUQuad* quads [[buffer(6)]],
       device const GPUTransform* transforms [[buffer(7)]],
       uint gid [[thread_position_in_grid]]
   ) {
       if (gid >= ray_count) return;

       WavefrontRay ray = rays[gid];
       Ray r = {ray.origin, ray.direction, ray.time};

       HitRecord rec;
       bool hit = bvh_hit(bvh_nodes, geometry_indices, spheres, quads,
                          transforms, sphere_count, r, 0.001, 1e10, &rec, nullptr);

       // 写入HitRecord
       if (hit) {
           hit_records[gid].p = rec.p;
           hit_records[gid].normal = rec.normal;
           hit_records[gid].t = rec.t;
           hit_records[gid].materialIndex = rec.material_index;
           hit_records[gid].frontFace = rec.front_face ? 1 : 0;
           hit_records[gid].u = rec.u;
           hit_records[gid].v = rec.v;
           hit_records[gid].pixelIndex = ray.pixelIndex;
       } else {
           hit_records[gid].t = -1.0;  // 标记未击中
           hit_records[gid].pixelIndex = ray.pixelIndex;
       }
   }
   ```

2. ✅ 处理体积雾（ConstantMedium）
   - 确保`bvh_hit`中的体积散射逻辑在wavefront模式下正常工作
   - 可能需要传递`RandomState`（每条光线独立的RNG状态）

3. ✅ 性能优化
   - 确保BVH遍历的栈大小足够（wavefront模式下栈是per-ray的）
   - 考虑光线排序以提高缓存命中率（可选，后续优化）

**验收标准**:
- Cornell Box场景：16K光线批量相交测试正确
- 性能测试：批量相交 vs 单光线相交的speedup > 1.2×
- 支持所有几何体类型（Sphere, Quad, ConstantMedium）

---

### **阶段4: 实现AOV着色kernel** ⏱️ 1.5天

**目标**: 材质散射+AOV通道分离+发光累积

**文件修改**:
- `Shaders/Kernels/Wavefront.metal`（新增kernel）
- `Shaders/Common/Materials.metal`（可能需要修改返回AOV通道）

**任务**:
1. ✅ 修改材质散射函数，返回AOV通道
   ```metal
   // Materials.metal
   struct ScatterResult {
       ScatterRecord srec;           // 原有的散射记录
       float3 diffuse_contribution;  // Lambertian贡献
       float3 specular_contribution; // Metal贡献
       float3 transmission_contribution; // Dielectric贡献
       float3 volume_contribution;   // Isotropic贡献
       bool skip_pdf;
   };

   inline ScatterResult material_scatter_aov(
       device const GPUMaterial* materials,
       device const GPUTexture* textures,
       texture2d<float> image_texture,
       constant float3* perlin_randvec,
       constant int* perlin_perm_x,
       constant int* perlin_perm_y,
       constant int* perlin_perm_z,
       uint material_index,
       Ray r_in,
       HitRecord rec,
       thread RandomState* rng
   ) {
       ScatterResult result;

       GPUMaterial mat = materials[material_index];

       switch (mat.type) {
           case MaterialLambertian: {
               // 漫反射散射
               // ... 原有逻辑

               // 记录AOV贡献
               result.diffuse_contribution = attenuation;  // 当前bounce的贡献
               result.specular_contribution = float3(0);
               result.transmission_contribution = float3(0);
               result.volume_contribution = float3(0);
               break;
           }

           case MaterialMetal: {
               // 镜面反射
               result.diffuse_contribution = float3(0);
               result.specular_contribution = attenuation;
               // ...
               break;
           }

           case MaterialDielectric: {
               // 玻璃折射/反射
               result.diffuse_contribution = float3(0);
               result.specular_contribution = float3(0);
               result.transmission_contribution = attenuation;
               break;
           }

           case MaterialIsotropic: {
               // 体积散射
               result.volume_contribution = attenuation;
               // ...
               break;
           }
       }

       result.srec = srec;
       result.skip_pdf = srec.skip_pdf;
       return result;
   }
   ```

2. ✅ 实现着色和散射kernel
   ```metal
   kernel void shade_and_scatter(
       device const WavefrontRay* input_rays [[buffer(0)]],
       device const WavefrontHitRecord* hit_records [[buffer(1)]],
       device WavefrontRay* output_rays [[buffer(2)]],
       device uint* active_flags [[buffer(3)]],        // 输出：是否继续追踪
       device atomic_uint* output_count [[buffer(4)]],

       // AOV累积缓冲区（per-pixel）
       device atomic<float>* beauty_sum [[buffer(5)]],      // float3[width*height]
       device atomic<float>* diffuse_sum [[buffer(6)]],
       device atomic<float>* specular_sum [[buffer(7)]],
       device atomic<float>* transmission_sum [[buffer(8)]],
       device atomic<float>* volume_sum [[buffer(9)]],
       device atomic<float>* emission_sum [[buffer(10)]],

       // 辅助通道（首次bounce）
       device atomic<float>* albedo_sum [[buffer(11)]],
       device atomic<float>* normal_sum [[buffer(12)]],
       device atomic<float>* depth_sum [[buffer(13)]],

       // 场景数据
       device const GPUMaterial* materials [[buffer(14)]],
       // ... 其他buffers

       constant uint& ray_count [[buffer(20)]],
       constant uint& max_depth [[buffer(21)]],
       constant bool& use_background [[buffer(22)]],

       uint gid [[thread_position_in_grid]]
   ) {
       if (gid >= ray_count) return;

       WavefrontRay ray = input_rays[gid];
       WavefrontHitRecord hit = hit_records[gid];

       // 未击中 → 累积背景光
       if (hit.t < 0.0) {
           if (use_background) {
               float3 bg_color = background_color(Ray{ray.origin, ray.direction, ray.time});
               float3 contribution = ray.throughput * bg_color;

               // 原子累加到beauty通道
               atomic_add_float3(&beauty_sum[ray.pixelIndex * 3], contribution);
           }

           active_flags[gid] = 0;  // 终止路径
           return;
       }

       // 重建HitRecord
       HitRecord rec;
       rec.p = hit.p;
       rec.normal = hit.normal;
       rec.t = hit.t;
       rec.material_index = hit.materialIndex;
       rec.front_face = (hit.frontFace == 1);
       rec.u = hit.u;
       rec.v = hit.v;

       // 1. 累积发光
       float3 emission = material_emitted(materials, textures, image_texture,
                                          perlin_randvec, perlin_perm_x, perlin_perm_y, perlin_perm_z,
                                          rec.material_index, rec);
       float3 emission_contribution = ray.throughput * emission;
       atomic_add_float3(&emission_sum[ray.pixelIndex * 3], emission_contribution);
       atomic_add_float3(&beauty_sum[ray.pixelIndex * 3], emission_contribution);

       // 2. 材质散射（AOV版本）
       RandomState rng = random_init(ray.pixelIndex + ray.depth * 12345);  // 确定性RNG
       ScatterResult scatter = material_scatter_aov(materials, textures, image_texture,
                                                    perlin_randvec, perlin_perm_x, perlin_perm_y, perlin_perm_z,
                                                    rec.material_index,
                                                    Ray{ray.origin, ray.direction, ray.time},
                                                    rec, &rng);

       if (!scatter.srec.is_specular && !scatter.skip_pdf) {
           // 非镜面材质 → 终止路径（或者实现完整的MIS，复杂度更高）
           // 简化版本：Lambertian在第一次bounce后终止

           // 累积当前bounce的贡献
           atomic_add_float3(&diffuse_sum[ray.pixelIndex * 3],
                            ray.throughput * scatter.diffuse_contribution);
           atomic_add_float3(&specular_sum[ray.pixelIndex * 3],
                            ray.throughput * scatter.specular_contribution);
           atomic_add_float3(&transmission_sum[ray.pixelIndex * 3],
                            ray.throughput * scatter.transmission_contribution);
           atomic_add_float3(&volume_sum[ray.pixelIndex * 3],
                            ray.throughput * scatter.volume_contribution);

           active_flags[gid] = 0;
           return;
       }

       // 3. 镜面反射/折射 → 继续追踪
       if (scatter.skip_pdf) {
           // 更新光线
           WavefrontRay new_ray;
           new_ray.origin = scatter.srec.skip_pdf_ray.origin;
           new_ray.direction = scatter.srec.skip_pdf_ray.direction;
           new_ray.throughput = ray.throughput * scatter.srec.attenuation;
           new_ray.pixelIndex = ray.pixelIndex;
           new_ray.depth = ray.depth + 1;
           new_ray.time = ray.time;

           // 俄罗斯轮盘赌
           if (ray.depth > 3) {
               float p = fmax(new_ray.throughput.r, fmax(new_ray.throughput.g, new_ray.throughput.b));
               if (random_float(&rng) > p) {
                   active_flags[gid] = 0;
                   return;
               }
               new_ray.throughput /= p;
           }

           // 检查最大深度
           if (new_ray.depth >= max_depth) {
               active_flags[gid] = 0;
               return;
           }

           // 写入输出光线池
           uint out_idx = atomic_fetch_add_explicit(output_count, 1, memory_order_relaxed);
           output_rays[out_idx] = new_ray;
           active_flags[gid] = 1;

           // 记录辅助AOV（仅首次bounce）
           if (ray.depth == 0) {
               atomic_add_float3(&albedo_sum[ray.pixelIndex * 3], scatter.srec.attenuation);
               atomic_add_float3(&normal_sum[ray.pixelIndex * 3], rec.normal);
               atomic_fetch_add_explicit(&depth_sum[ray.pixelIndex], hit.t, memory_order_relaxed);
           }
       }
   }
   ```

3. ✅ 实现原子浮点加法辅助函数
   ```metal
   // Wavefront.metal
   inline void atomic_add_float3(device atomic<float>* buffer, float3 value) {
       atomic_fetch_add_explicit(&buffer[0], value.r, memory_order_relaxed);
       atomic_fetch_add_explicit(&buffer[1], value.g, memory_order_relaxed);
       atomic_fetch_add_explicit(&buffer[2], value.b, memory_order_relaxed);
   }
   ```

**验收标准**:
- AOV通道分离正确（diffuse/specular/transmission独立）
- Beauty通道 = sum(all AOV channels)
- 视觉一致性：wavefront渲染结果与原per-pixel渲染一致（允许蒙特卡洛误差）

---

### **阶段5: 集成Wavefront渲染循环** ⏱️ 1天

**目标**: 实现完整的wavefront path tracing主循环

**文件修改**:
- `Sources/Rendering/WavefrontRenderer.swift`

**任务**:
1. ✅ 实现WavefrontRenderer类
   ```swift
   class WavefrontRenderer {
       let context: MetalContext
       let baseRenderer: Renderer  // 复用GPU buffers

       // Wavefront pipelines
       var generateRaysPipeline: MTLComputePipelineState
       var intersectPipeline: MTLComputePipelineState
       var shadeAndScatterPipeline: MTLComputePipelineState
       var compactRaysPipeline: MTLComputePipelineState

       // 光线池（双缓冲）
       var rayPoolA: WavefrontRayPool
       var rayPoolB: WavefrontRayPool

       func renderTile(
           scene: Scene,
           camera: Camera,
           bvh: FlatBVH,
           tileParams: TileParams,
           aovBuffers: AOVBuffers,
           samplesPerPixel: Int,
           maxDepth: Int
       ) {
           // 1. 生成初始光线
           var currentPool = rayPoolA
           var nextPool = rayPoolB

           generateCameraRays(tileParams: tileParams, spp: samplesPerPixel, output: currentPool)

           // 2. Wavefront迭代（depth-by-depth）
           for depth in 0..<maxDepth {
               let activeCount = currentPool.getActiveCount()
               if activeCount == 0 { break }

               // 2.1 相交测试
               intersectRays(rayPool: currentPool, hitRecords: currentPool.hitRecordBuffer, count: activeCount)

               // 2.2 着色和散射
               nextPool.reset()
               shadeAndScatter(
                   inputRays: currentPool,
                   hitRecords: currentPool.hitRecordBuffer,
                   outputRays: nextPool,
                   aovBuffers: aovBuffers,
                   count: activeCount
               )

               // 交换缓冲区
               swap(&currentPool, &nextPool)
           }
       }
   }
   ```

2. ✅ 实现辅助函数
   ```swift
   private func generateCameraRays(tileParams: TileParams, spp: Int, output: WavefrontRayPool) {
       guard let commandBuffer = context.commandQueue.makeCommandBuffer(),
             let encoder = commandBuffer.makeComputeCommandEncoder() else {
           return
       }

       encoder.setComputePipelineState(generateRaysPipeline)
       encoder.setBuffer(output.rayBuffer, offset: 0, index: 0)
       encoder.setBuffer(output.activeCountBuffer, offset: 0, index: 1)
       encoder.setBytes(&cameraParams, length: MemoryLayout<GPUCameraParams>.stride, index: 2)
       encoder.setBytes(&tileParams, length: MemoryLayout<TileParams>.stride, index: 3)
       var sppValue = UInt32(spp)
       encoder.setBytes(&sppValue, length: MemoryLayout<UInt32>.stride, index: 4)

       let threadsPerGrid = MTLSize(width: tileParams.tileWidth, height: tileParams.tileHeight, depth: 1)
       let threadsPerThreadgroup = MTLSize(width: 8, height: 8, depth: 1)
       encoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)

       encoder.endEncoding()
       commandBuffer.commit()
       commandBuffer.waitUntilCompleted()
   }
   ```

**验收标准**:
- 单个tile渲染成功（64×64, 4 spp）
- 活跃光线数随深度递减（符合预期）
- 性能测试：wavefront vs per-pixel的speedup > 1.1×（初步）

---

### **阶段6: 实现Tile-Based渲染管理器** ⏱️ 1天

**目标**: 将全图分块，逐tile渲染

**新建文件**:
- `Sources/Rendering/TileManager.swift`

**任务**:
1. ✅ 实现TileManager类
   ```swift
   class TileManager {
       let tileSize: Int  // 64 或 128
       let imageWidth: Int
       let imageHeight: Int

       var tilesX: Int
       var tilesY: Int
       var tiles: [TileInfo]

       struct TileInfo {
           var x: Int, y: Int
           var width: Int, height: Int
           var converged: Bool
           var averageSpp: Float
       }

       init(imageWidth: Int, imageHeight: Int, tileSize: Int = 64) {
           self.imageWidth = imageWidth
           self.imageHeight = imageHeight
           self.tileSize = tileSize

           self.tilesX = (imageWidth + tileSize - 1) / tileSize
           self.tilesY = (imageHeight + tileSize - 1) / tileSize

           // 初始化tiles
           self.tiles = []
           for ty in 0..<tilesY {
               for tx in 0..<tilesX {
                   let x = tx * tileSize
                   let y = ty * tileSize
                   let w = min(tileSize, imageWidth - x)
                   let h = min(tileSize, imageHeight - y)

                   tiles.append(TileInfo(x: x, y: y, width: w, height: h,
                                        converged: false, averageSpp: 0))
               }
           }
       }

       func getTileParams(index: Int) -> TileParams {
           let tile = tiles[index]
           return TileParams(
               tileX: UInt32(tile.x),
               tileY: UInt32(tile.y),
               tileWidth: UInt32(tile.width),
               tileHeight: UInt32(tile.height),
               tileSizeX: UInt32(tileSize),
               tileSizeY: UInt32(tileSize),
               imageWidth: UInt32(imageWidth),
               imageHeight: UInt32(imageHeight)
           )
       }
   }
   ```

2. ✅ 实现Tile渲染循环
   ```swift
   func renderAllTiles(
       scene: Scene,
       camera: Camera,
       bvh: FlatBVH,
       targetSpp: Int,
       varianceThreshold: Float
   ) -> [Float] {
       let tileManager = TileManager(imageWidth: camera.imageWidth,
                                     imageHeight: camera.imageHeight,
                                     tileSize: 64)

       // 全图像素缓冲区（最终输出）
       var finalPixels = [Float](repeating: 0, count: camera.imageWidth * camera.imageHeight * 4)

       for (index, tile) in tileManager.tiles.enumerated() {
           print("Rendering tile \(index + 1)/\(tileManager.tiles.count) (\(tile.x), \(tile.y))")

           // 创建tile的AOV缓冲区
           let tilePixels = tile.width * tile.height
           let aovBuffers = createAOVBuffers(pixelCount: tilePixels)

           // 渲染tile（自适应采样）
           let tileParams = tileManager.getTileParams(index: index)
           renderTileAdaptive(
               scene: scene,
               camera: camera,
               bvh: bvh,
               tileParams: tileParams,
               aovBuffers: aovBuffers,
               targetSpp: targetSpp,
               varianceThreshold: varianceThreshold
           )

           // 读取tile结果并合并到全图
           let tilePixelData = readAOVBuffers(aovBuffers: aovBuffers, width: tile.width, height: tile.height)
           copyTileToImage(tilePixels: tilePixelData, tile: tile, destination: &finalPixels,
                          imageWidth: camera.imageWidth)
       }

       return finalPixels
   }
   ```

3. ✅ 实现Tile数据拷贝
   ```swift
   private func copyTileToImage(
       tilePixels: [Float],
       tile: TileManager.TileInfo,
       destination: inout [Float],
       imageWidth: Int
   ) {
       for y in 0..<tile.height {
           for x in 0..<tile.width {
               let tileIdx = (y * tile.width + x) * 4
               let imageIdx = ((tile.y + y) * imageWidth + (tile.x + x)) * 4

               destination[imageIdx + 0] = tilePixels[tileIdx + 0]
               destination[imageIdx + 1] = tilePixels[tileIdx + 1]
               destination[imageIdx + 2] = tilePixels[tileIdx + 2]
               destination[imageIdx + 3] = tilePixels[tileIdx + 3]
           }
       }
   }
   ```

**验收标准**:
- 能够正确分块（边缘tile尺寸正确）
- 所有tile渲染后合成的图像与全图渲染一致
- 无seam伪影（tile边界无缝）

---

### **阶段7: 实现AOV自适应采样** ⏱️ 1.5天

**目标**: 基于多通道方差的自适应采样

**文件修改**:
- `Sources/Rendering/WavefrontRenderer.swift`
- `Shaders/Kernels/AdaptiveSampling.metal`（复用并扩展）

**任务**:
1. ✅ 实现AOV缓冲区管理
   ```swift
   class AOVBuffers {
       let pixelCount: Int

       // 各通道累积缓冲区
       var beautySum: MTLBuffer
       var beautySumSq: MTLBuffer
       var diffuseSum: MTLBuffer
       var diffuseSumSq: MTLBuffer
       var specularSum: MTLBuffer
       var specularSumSq: MTLBuffer
       var transmissionSum: MTLBuffer
       var transmissionSumSq: MTLBuffer
       var volumeSum: MTLBuffer
       var volumeSumSq: MTLBuffer
       var emissionSum: MTLBuffer
       var emissionSumSq: MTLBuffer

       // 辅助通道
       var albedoSum: MTLBuffer
       var normalSum: MTLBuffer
       var depthSum: MTLBuffer

       // 采样计数和收敛
       var sampleCount: MTLBuffer
       var variance: MTLBuffer
       var convergedFlags: MTLBuffer

       init(device: MTLDevice, pixelCount: Int) {
           self.pixelCount = pixelCount

           // 分配所有缓冲区（使用storageModePrivate以提高性能）
           self.beautySum = device.makeBuffer(length: pixelCount * 3 * MemoryLayout<Float>.stride,
                                              options: .storageModePrivate)!
           // ... 其他缓冲区
       }
   }
   ```

2. ✅ 实现AOV方差计算kernel（复用并扩展AdaptiveSampling.metal）
   ```metal
   // 已存在于AdaptiveSampling.metal，验证逻辑
   kernel void compute_variance_aov(
       device const float4* diffuse_sum [[buffer(0)]],
       device const float4* diffuse_sum_sq [[buffer(1)]],
       device const float4* specular_sum [[buffer(2)]],
       device const float4* specular_sum_sq [[buffer(3)]],
       device const float4* transmission_sum [[buffer(4)]],
       device const float4* transmission_sum_sq [[buffer(5)]],
       device const uint* sample_count [[buffer(6)]],
       device float* variance [[buffer(7)]],
       device uint* converged_flags [[buffer(8)]],
       constant AdaptiveSamplingParams& params [[buffer(9)]],
       uint2 gid [[thread_position_in_grid]]
   ) {
       // 计算各通道方差
       // 使用最大通道方差判断收敛
       // ... 逻辑已存在
   }
   ```

3. ✅ 实现Tile自适应渲染循环
   ```swift
   private func renderTileAdaptive(
       scene: Scene,
       camera: Camera,
       bvh: FlatBVH,
       tileParams: TileParams,
       aovBuffers: AOVBuffers,
       targetSpp: Int,
       varianceThreshold: Float
   ) {
       let batchSize = 8
       var currentSpp = 0

       // Stage 0: Warmup（16 spp）
       while currentSpp < 16 {
           let samples = min(batchSize, 16 - currentSpp)

           wavefrontRenderer.renderTile(
               scene: scene,
               camera: camera,
               bvh: bvh,
               tileParams: tileParams,
               aovBuffers: aovBuffers,
               samplesPerPixel: samples,
               maxDepth: scene.camera.maxDepth
           )

           currentSpp += samples
       }

       // Stage 1-3: 自适应采样
       let checkpoints = [32, 64, 128, 256, targetSpp]

       for checkpoint in checkpoints {
           if currentSpp >= checkpoint { continue }

           // 渲染到检查点
           while currentSpp < checkpoint {
               // 获取未收敛像素
               let unconvergedPixels = getUnconvergedPixels(aovBuffers: aovBuffers)

               if unconvergedPixels.isEmpty {
                   print("  All pixels converged at \(currentSpp) spp")
                   return
               }

               let samples = min(batchSize, checkpoint - currentSpp)

               // TODO: 实现像素掩码版本的wavefront渲染
               wavefrontRenderer.renderTileWithMask(
                   scene: scene,
                   camera: camera,
                   bvh: bvh,
                   tileParams: tileParams,
                   aovBuffers: aovBuffers,
                   pixelMask: unconvergedPixels,
                   samplesPerPixel: samples,
                   maxDepth: scene.camera.maxDepth
               )

               currentSpp += samples
           }

           // 计算AOV方差
           computeVarianceAOV(aovBuffers: aovBuffers, varianceThreshold: varianceThreshold)

           let convergedCount = getConvergedCount(aovBuffers: aovBuffers)
           print("  Checkpoint \(checkpoint) spp: \(convergedCount)/\(aovBuffers.pixelCount) converged")
       }
   }
   ```

**验收标准**:
- AOV方差计算正确（各通道独立）
- 自适应采样节省率 > 30%（相比固定采样）
- 收敛精度提升（相比单通道方差）

---

### **阶段8: 性能优化与调试** ⏱️ 1天

**目标**: 优化性能，修复bug

**任务**:
1. ✅ 性能profiling
   - 使用Xcode Instruments分析GPU占用率
   - 识别瓶颈kernel（相交 vs 着色）
   - 检查内存带宽使用

2. ✅ 优化措施
   - [ ] 光线排序（按材质类型排序以减少分化）
   - [ ] 共享内存优化（BVH节点缓存）
   - [ ] Tile尺寸调优（64×64 vs 128×128）
   - [ ] AOV缓冲区压缩（half精度）

3. ✅ Bug修复
   - [ ] 检查边缘case（tile边界、最大深度、Russian Roulette）
   - [ ] 验证所有场景（Cornell Box, Bouncing Spheres, Final Scene）
   - [ ] 修复NaN/Inf问题

**验收标准**:
- GPU占用率 > 80%（通过Instruments验证）
- 渲染速度 vs Phase 9自适应采样的speedup > 1.2×
- 无视觉伪影，所有测试场景通过

---

### **阶段9: 集成到主渲染流程** ⏱️ 1天

**目标**: 将wavefront+AOV+tile模式集成到main.swift

**文件修改**:
- `Sources/main.swift`
- `Sources/Utils/CommandLineArgs.swift`

**任务**:
1. ✅ 添加命令行参数
   ```swift
   // CommandLineArgs.swift
   struct CommandLineArgs {
       // ... 现有参数

       var useWavefront: Bool = false      // --wavefront
       var useAOV: Bool = false            // --aov
       var tileSize: Int = 64              // --tile-size <64|128>
   }
   ```

2. ✅ 修改main.swift渲染逻辑
   ```swift
   // main.swift
   if args.useWavefront {
       // Wavefront + AOV + Tile 模式
       let tileRenderer = TileRenderer(context: context, ...)

       if args.useAOV {
           let (pixels, time, stats) = tileRenderer.renderWithAOV(
               scene: scene,
               camera: camera,
               bvh: bvh,
               targetSpp: args.samplesPerPixel,
               tileSize: args.tileSize,
               varianceThreshold: 0.0001
           )
           // ... 输出结果
       } else {
           // Wavefront + Tile（无AOV）
           let (pixels, time) = tileRenderer.render(...)
       }
   } else {
       // 原有的per-pixel模式
       let (pixels, time) = renderer.render(...)
   }
   ```

3. ✅ 实时窗口模式支持（可选）
   - Wavefront模式可能不适合实时渲染（overhead较大）
   - 保留per-pixel模式用于实时窗口

**验收标准**:
- 命令行参数正常工作
- 向后兼容（不加--wavefront时使用原有模式）
- 输出图像格式一致（PPM）

---

### **阶段10: 文档与测试** ⏱️ 1天

**目标**: 完善文档，性能对比测试

**任务**:
1. ✅ 性能对比测试
   ```bash
   # Baseline: Per-pixel + 单通道自适应采样
   time swift run raytracer --scene cornellBox --spp 100 --adaptive

   # Wavefront + AOV + Tile
   time swift run raytracer --scene cornellBox --spp 100 --wavefront --aov --tile-size 64

   # 记录对比数据：渲染时间、样本节省率、GPU占用率
   ```

2. ✅ 更新CLAUDE.md
   - 添加Phase 11章节（Wavefront + AOV + Tile）
   - 性能数据表格
   - 架构图

3. ✅ 创建完成报告
   - `docs/phase11_wavefront_aov_tile.md`
   - 包含：实现细节、性能提升、遇到的问题和解决方案

**验收标准**:
- 完整的性能对比数据（3个场景）
- 文档完整且清晰
- 代码有充分注释

---

## 📊 预期性能提升

### 渲染速度
| 场景 | Baseline (Phase 9) | Wavefront+AOV+Tile | Speedup |
|------|-------------------|-------------------|---------|
| Cornell Box (400×400, 100 spp) | 329 ms | **250 ms** | 1.3× |
| Bouncing Spheres (800×450, 10 spp) | 82 ms | **60 ms** | 1.4× |
| Final Scene (400×400, 10 spp) | 60 ms | **45 ms** | 1.3× |

### GPU占用率
- **当前**: 50-60%（严重线程分化）
- **改造后**: 75-85%（活跃光线池化）

### 自适应采样效率
- **当前**: 单通道方差，30-40%样本节省
- **改造后**: 多通道AOV方差，**40-60%样本节省**

---

## ⚠️ 风险与挑战

### 技术风险
1. **随机数生成**
   - Wavefront模式下每条光线需要独立的RNG状态
   - 解决：使用确定性RNG（基于pixelIndex和depth）

2. **内存占用**
   - AOV多通道缓冲区内存占用大（10个通道）
   - 解决：使用half精度（16-bit float），内存减半

3. **原子操作冲突**
   - 多条光线同时累加到同一像素的AOV缓冲区
   - 解决：Metal的`atomic<float>`性能足够（硬件支持）

4. **MIS复杂度**
   - 当前的Power Heuristic MIS需要光源采样
   - Wavefront模式下实现MIS更复杂
   - 解决：阶段4简化为镜面材质继续追踪，漫反射材质终止

### 工程风险
1. **代码复杂度**
   - 新增~2000行Swift + ~1500行Metal代码
   - 解决：模块化设计，充分注释

2. **向后兼容**
   - 需要保留原有per-pixel模式
   - 解决：通过命令行参数选择渲染模式

---

## 🎯 成功标准

### 功能完整性
- [ ] Wavefront path tracing正确渲染所有场景
- [ ] AOV通道分离准确（beauty = sum(all channels)）
- [ ] Tile-based渲染无seam伪影
- [ ] 自适应采样收敛精度提升

### 性能目标
- [ ] GPU占用率 > 75%
- [ ] 渲染速度提升 > 1.2×
- [ ] 自适应采样节省率 > 40%

### 代码质量
- [ ] 所有代码有注释
- [ ] 无内存泄漏（Instruments验证）
- [ ] 向后兼容，原有功能不受影响

---

## 📅 时间规划

| 阶段 | 任务 | 预估时间 | 累计时间 |
|-----|------|---------|---------|
| 0 | 代码审计与准备 | 0.5天 | 0.5天 |
| 1 | 重构GPU数据结构 | 0.5天 | 1天 |
| 2 | Wavefront光线生成与压缩 | 1天 | 2天 |
| 3 | Wavefront相交测试 | 1天 | 3天 |
| 4 | AOV着色kernel | 1.5天 | 4.5天 |
| 5 | 集成Wavefront渲染循环 | 1天 | 5.5天 |
| 6 | Tile-Based渲染管理器 | 1天 | 6.5天 |
| 7 | AOV自适应采样 | 1.5天 | 8天 |
| 8 | 性能优化与调试 | 1天 | 9天 |
| 9 | 集成到主渲染流程 | 1天 | 10天 |
| 10 | 文档与测试 | 1天 | 11天 |

**总计**: 10-12天（包含调试和优化时间）

---

## 🔄 迭代策略

### 第一轮迭代（阶段1-5）
**目标**: 实现基础的Wavefront渲染，不含AOV和Tile
- 先实现单tile全图渲染
- 仅实现beauty通道
- 验证wavefront逻辑正确性

### 第二轮迭代（阶段6-7）
**目标**: 添加Tile分块和AOV通道
- 实现tile管理器
- 添加多通道AOV
- 集成自适应采样

### 第三轮迭代（阶段8-10）
**目标**: 优化和集成
- 性能调优
- 集成到主流程
- 完善文档

---

## 📚 参考资料

### 学术论文
1. **Wavefront Path Tracing** - Laine et al. 2013
   - "Megakernels Considered Harmful: Wavefront Path Tracing on GPUs"
   - 核心思想：光线池化、depth-by-depth处理

2. **AOV for Adaptive Sampling** - Dammertz et al. 2010
   - "A Hierarchical Automatic Stopping Condition for Monte Carlo Global Illumination"
   - 多通道方差估计

3. **Stream Compaction** - Bilodeau et al. 2011
   - "Efficient Stream Compaction on Wide SIMD Many-Core Architectures"

### 代码参考
- **PBRT-v4**: Wavefront实现 (C++/CUDA)
- **Mitsuba 3**: AOV系统设计
- **现有代码**: `AdaptiveSampling.metal`（方差计算逻辑）

---

**文档版本**: v1.0
**最后更新**: 2025-12-16
**负责人**: Claude Sonnet 4.5 + 用户
