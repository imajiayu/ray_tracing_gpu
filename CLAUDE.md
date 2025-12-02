# Ray Tracing GPU - 基于 Metal 的 GPU 光线追踪渲染器

**项目类型**: 从零开始的 Swift + Metal 原生实现
**目标平台**: macOS (Apple Silicon / Intel)
**技术栈**: Swift 5.9+, Metal 3, MetalKit
**参考项目**: ~/ray_tracing (C++ CPU/GPU 混合渲染器)

---

## 项目概述

本项目是对原 C++ 光线追踪项目的完全重写，使用 Swift 语言和 Metal 原生窗口实现 GPU 加速的物理真实感光线追踪渲染器。

**核心设计目标**:
- ✅ **纯 Swift/Metal 实现**: 无 C++ 依赖，充分利用 Swift 语言特性
- 🔄 **双渲染模式**: 静态图片渲染 + 实时交互窗口
- ✅ **GPU 优先架构**: Metal 计算着色器为核心，CPU 仅负场景管理
- 🔄 **物理真实感**: 路径追踪、多重重要性采样、完整材质系统
- ✅ **高性能**: BVH 加速结构、内存对齐优化

---

## 项目进度

### Phase 1: 核心基础设施 ✅ (已完成)

**完成日期**: 2025-11-26
**状态**: 全部完成

**已实现**:
- ✅ Swift Package Manager 项目结构
- ✅ 核心数学库 (Vec3, Ray, Color, Interval)
- ✅ Metal 上下文管理 (MetalContext)
- ✅ GPU 数据结构定义 (内存对齐到 16 字节)
- ✅ Metal 着色器编译系统 (compile_shaders.sh)
- ✅ 球体几何 + Lambertian 材质
- ✅ GPU 路径追踪内核 (迭代式，无递归)
- ✅ PCG 随机数生成器 (GPU)

**渲染成果**:
- 场景: 3 球体 (红、黄、蓝 Lambertian)
- 分辨率: 800×450 @ 10 spp @ 50 depth
- 性能: **13.79 ms** (261 M rays/s)
- 加速比: **9.6× vs CPU 版本**

**详细文档**: `docs/phase1_completed.md`

---

### Phase 2: 完整材质与几何 ✅ (已完成)

**完成日期**: 2025-11-27
**状态**: 全部完成

**已实现**:
1. **材质系统**
   - ✅ Lambertian (漫反射)
   - ✅ Metal (金属反射，支持模糊度)
   - ✅ Dielectric (电介质折射)
   - ✅ DiffuseLight (发光材质)
   - ✅ Isotropic (各向同性散射，用于体积雾)

2. **几何体**
   - ✅ Sphere (球体，支持变换)
   - ✅ Quad (四边形)
   - ✅ Box (长方体，由6个Quad组成)
   - ✅ ConstantMedium (体积雾，已实现但待调试)

3. **纹理系统**
   - ✅ SolidColor (纯色)
   - ✅ CheckerTexture (3D棋盘纹理)
   - ✅ ImageTexture (图像纹理，JPEG/PNG支持)
   - ✅ NoiseTexture (Perlin梯度噪声，大理石效果)

4. **测试场景**
   - ✅ Cornell Box (完整实现)
   - ✅ Bouncing Spheres (488球体)
   - ✅ Texture Test (纹理展示)
   - ✅ Final Scene (最终演示场景，1006球体+2401四边形)

5. **变换系统**
   - ✅ Translation (平移)
   - ✅ Rotation (旋转，Y轴)

**渲染成果**:
- Cornell Box: 600×600 @ 100 spp @ 50 depth
- Final Scene: 800×800 @ 10 spp @ 10 depth ≈ 9.1 秒
- Bouncing Spheres: 800×450 @ 10 spp @ 50 depth
- 性能: 0.7-0.9 M rays/s (无BVH加速)

**已知问题**:
- ⚠️ ConstantMedium (体积雾) 实现有bug，已临时注释
- ⚠️ 大场景性能较低，急需BVH加速

**详细文档**: `docs/phase2_completed.md`

---

### Phase 3: BVH 加速结构 📋 (准备开始)

**目标**: 实现 GPU 友好的 BVH 加速，大幅提升复杂场景性能

**待实现**:
1. **AABB 包围盒**
   - ⏳ Sphere AABB 计算
   - ⏳ Quad AABB 计算
   - ⏳ AABB 相交测试

2. **BVH 构建 (CPU)**
   - ⏳ SAH (Surface Area Heuristic) 分割
   - ⏳ 递归构建二叉树
   - ⏳ FlatBVH 扁平化（线性数组）

3. **GPU BVH 遍历**
   - ⏳ 迭代式遍历（32层固定栈）
   - ⏳ AABB快速拒绝
   - ⏳ 叶节点几何体测试

4. **数据结构优化**
   - ⏳ BVH节点内存对齐（16字节）
   - ⏳ 几何体数据分离存储

**性能目标**:
- Final Scene (1006球+2401四边形): 9.1s → < 500ms (18× 加速)
- Bouncing Spheres (488球): < 15ms @ 10 spp

**详细文档**: `docs/phase3.md`

---

### Phase 4: 多重重要性采样 ⏳ (待开始)

**目标**: 实现 MIS 采样策略，显著降低噪声

**待实现**:
- PDF 系统 (CosinePDF, HittablePDF, MixturePDF)
- ONB 正交基变换
- GPU MIS 实现
- Next Event Estimation (NEE)
- 俄罗斯轮盘赌 (RR)

**目标**: Cornell Box 噪声降低 70-80%

---

### Phase 5: 实时渲染窗口 ⏳ (待开始)

**目标**: 实现交互式实时渲染窗口

**待实现**:
- MTKView 窗口 (Metal 原生)
- 累积渲染缓冲区
- FPS 相机控制 (WASD + 鼠标)
- 质量预设控制 (Preview/Medium/High)
- 实时 HUD 显示

**性能目标**: 1080p @ 4 spp @ 60 FPS

---

### Phase 6: 静态图片渲染 ⏳ (待开始)

**目标**: 实现高质量离线渲染模式

**待实现**:
- CLI 命令行接口
- 批次渲染 (大场景分批上传 GPU)
- 进度条显示
- PNG/EXR 输出
- 后处理 (Gamma 校正, Tone mapping)

**性能目标**: 4K @ 10000 spp 离线渲染

---

### Phase 7: 润色与优化 ⏳ (待开始)

**目标**: 性能调优、文档完善、最终测试

**待实现**:
- Metal 性能分析器测试
- 线程组大小调优
- 内存访问优化
- 完整的场景库 (BouncingSpheres, CornellBox, FinalScene)
- API 文档 (Swift DocC)

---

## 技术架构

### 目录结构

```
ray_tracing_gpu/
├── Sources/
│   ├── Core/           # 核心数学库 (Vec3, Ray, Color)
│   ├── Geometry/       # 几何图元 (Sphere, Quad, Box, Triangle)
│   ├── Materials/      # 材质系统 (Lambertian, Metal, Dielectric)
│   ├── Textures/       # 纹理系统 (Solid, Checker, Image, Noise)
│   ├── Acceleration/   # 加速结构 (AABB, BVH, FlatBVH)
│   ├── GPU/            # Metal 上下文和 GPU 数据结构
│   └── Main/           # 主程序
├── Shaders/
│   ├── Common/         # 通用 Metal 函数 (Types, Random, Geometry, Materials)
│   └── Kernels/        # 光线追踪内核 (SimpleRayTracing)
├── Resources/          # 编译后的 .metallib
├── docs/               # 开发文档
│   ├── phase1_completed.md  # Phase 1 完成总结
│   └── phase2.md            # Phase 2 任务规划
├── CLAUDE.md           # 本文档
└── README.md           # 用户文档
```

### GPU 数据结构设计

**关键原则**: 所有结构体对齐到 16 字节倍数

**示例**:
```swift
// Swift 端
struct GPUSphere {
    var center: SIMD3<Float>    // 12 bytes
    var radius: Float           // 4 bytes
    var materialIndex: UInt32   // 4 bytes
    var padding: SIMD3<Float>   // 12 bytes
}  // Total: 32 bytes

// Metal 端（完全对应）
struct GPUSphere {
    float3 center;
    float radius;
    uint material_index;
    float3 padding;
};
```

---

## CPU vs GPU SIMD 优化策略

### 关键理解：纯 GPU 渲染不需要 CPU SIMD

**本项目（纯 GPU）策略**:
- ✅ **热路径 100% 在 GPU**: 光线追踪、材质评估、BVH 遍历全在 GPU
- ✅ **CPU 只做场景管理**: BVH 构建（一次性）、数据传输（带宽瓶颈）
- ✅ **Metal 自动 SIMD 化**: GPU 编译器自动向量化 float3 操作
- ✅ **简化代码**: 使用 Swift SIMD3<Float> 类型别名即可

**Swift 端实现**:
```swift
typealias Vec3 = SIMD3<Float>  // 简单、类型安全、零开销
```

**Metal 端自动优化**:
- GPU 自动 SIMD 化（Warp/Wavefront 32-64 线程锁步执行）
- float3 操作自动编译为向量指令
- 无需手动优化

**唯一关键：GPU 内存对齐**（16 字节倍数）

---

## 关键技术挑战与解决方案

### 1. Swift 与 Metal 互操作

**挑战**: Swift 结构体内存布局与 Metal 对齐规则不同

**解决方案**:
- 所有 GPU 结构体手动填充到 16 字节倍数
- 单元测试验证内存布局 (sizeof, alignment)

### 2. Metal 坐标系差异

**挑战**: Metal 纹理原点在左上角，与传统图像坐标系不同

**解决方案**:
- 翻转 Y 坐标: `v = (height - 1 - gid.y) / height`

### 3. Metal 标准库函数冲突

**挑战**: 自定义 `reflect` 和 `refract` 与 Metal 标准库冲突

**解决方案**:
- 使用 `metal::reflect()` 和 `metal::refract()` 显式调用

### 4. BVH 栈深度限制

**挑战**: Metal 不支持动态栈，递归深度有限

**解决方案**:
- 迭代式 BVH 遍历（32-64 层固定栈）
- 栈溢出时终止光线（返回背景颜色）

---

## 性能目标

### 静态图片渲染

| 场景 | 分辨率 | spp | 深度 | 目标时间 | 当前 | 对比 CPU |
|------|-------|-----|------|---------|------|---------|
| 3 Spheres | 800×450 | 10 | 50 | < 100 ms | **13.79 ms** ✅ | 9.6× 加速 |
| Bouncing Spheres | 800×450 | 10 | 50 | < 15 ms | 待测试 | 20× 加速 |
| Cornell Box | 800×800 | 100 | 50 | < 500 ms | 待测试 | 15× 加速 |

### 实时渲染

| 分辨率 | spp | 深度 | 目标 FPS | 场景复杂度 |
|-------|-----|------|---------|-----------|
| 1920×1080 | 1 | 10 | 60 | 简单 (< 100 图元) |
| 1920×1080 | 4 | 10 | 60 | 中等 (< 500 图元) |

---

## 参考资源

**原项目**:
- ~/ray_tracing/CLAUDE.md - 完整技术文档
- ~/ray_tracing/shaders/common.metal - GPU 实现参考

**官方文档**:
- [Metal Programming Guide](https://developer.apple.com/metal/)
- [Metal Shading Language Specification](https://developer.apple.com/metal/Metal-Shading-Language-Specification.pdf)
- [Swift SIMD Documentation](https://developer.apple.com/documentation/swift/simd)

**学术资源**:
- Peter Shirley - "Ray Tracing in One Weekend" 系列
- PBRT - "Physically Based Rendering"

---

## 下一步行动

**当前重点**: Phase 2 - 完整材质与几何

**立即任务**:
1. 测试 Metal 和 Dielectric 材质
2. 实现 Quad/Box/Triangle 几何体
3. 实现纹理系统
4. 渲染 Cornell Box 场景

**详细规划**: 参见 `docs/phase2.md`

---

**文档版本**: v2.0
**最后更新**: 2025-11-26
**当前状态**: Phase 1 ✅ 完成 → Phase 2 🔄 进行中
