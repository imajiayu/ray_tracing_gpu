# Ray Tracing GPU - 基于 Metal 的 GPU 光线追踪渲染器

**项目类型**: 纯 Swift + Metal 实现
**目标平台**: macOS (Apple Silicon / Intel)
**技术栈**: Swift 5.9+, Metal 3, MetalKit
**参考项目**: ~/ray_tracing (C++ CPU 版本)

---

## 项目概述

使用 Swift 和 Metal 实现的 GPU 加速物理真实感光线追踪渲染器。

**核心特性**:
- ✅ **纯 Swift/Metal 实现**: 无 C++ 依赖
- ✅ **GPU 优先架构**: Metal 计算着色器为核心
- ✅ **BVH 加速结构**: 支持大规模复杂场景
- ✅ **完整材质系统**: Lambertian, Metal, Dielectric, DiffuseLight
- ✅ **纹理支持**: 纯色、棋盘格、图像、Perlin 噪声
- ✅ **几何变换**: 平移、旋转

---

## 当前状态

### ✅ 已实现功能 (Phase 1-3)

**渲染核心**:
- GPU 路径追踪内核 (迭代式，无递归)
- PCG 随机数生成器
- BVH 加速结构 (SAH 分割)
- 离线图片渲染模式 (PPM 输出)

**材质系统**:
- Lambertian (漫反射)
- Metal (金属反射 + 模糊度)
- Dielectric (电介质折射)
- DiffuseLight (发光材质)

**几何体**:
- Sphere (球体)
- Quad (四边形)
- Box (长方体，由 6 个 Quad 组成)

**纹理系统**:
- SolidColor (纯色)
- CheckerTexture (3D 棋盘格)
- ImageTexture (JPEG/PNG 支持)
- NoiseTexture (Perlin 梯度噪声)

**变换系统**:
- Translation (平移)
- RotationY (Y 轴旋转)

**测试场景**:
- Cornell Box (600×600)
- Bouncing Spheres (485 球体)
- Texture Test (地球纹理)
- Final Scene (1006 球体 + 2401 四边形)

**性能表现**:
| 场景 | 分辨率 | spp | 深度 | 渲染时间 | 性能 |
|------|-------|-----|------|---------|------|
| Bouncing Spheres | 800×450 | 10 | 50 | ~180 ms | 19.9 M rays/s |
| Cornell Box | 400×400 | 10 | 50 | ~116 ms | - |
| Final Scene | 400×400 | 10 | 10 | ~88 ms | 18.1 M rays/s |

---

## 未实现功能

### ⏳ Phase 4: 多重重要性采样 (MIS)

**目标**: 显著降低渲染噪声

**待实现**:
- PDF 系统 (CosinePDF, HittablePDF, MixturePDF)
- ONB 正交基变换
- Next Event Estimation (NEE)
- 俄罗斯轮盘赌 (Russian Roulette)

**预期效果**: Cornell Box 噪声降低 70-80%

---

### ⏳ Phase 5: 实时窗口模式

**目标**: 交互式实时渲染

**待实现**:
- MTKView 窗口 (Metal 原生)
- 累积渲染缓冲区 (Progressive Rendering)
- FPS 相机控制 (WASD + 鼠标)
- 质量预设切换 (Preview/Medium/High)
- 实时 HUD 显示 (FPS, spp, camera info)

**性能目标**: 1080p @ 4 spp @ 60 FPS (简单场景)

**预留代码**:
- `Shaders/Kernels/Accumulation.metal` - 累积渲染内核
- `Shaders/Kernels/ColorConversion.metal` - RGBA → BGRA8 转换

---

### ⏳ Phase 6: 体积雾效果 (ConstantMedium)

**目标**: 实现烟雾、云层等体积散射效果

**待实现**:
- ConstantMedium 几何体 (边界 + 密度)
- Isotropic 材质 (各向同性散射)
- GPU 端体积散射算法

**参考**: CPU 版本已实现，需移植到 GPU

---

### ⏳ Phase 7: 高级功能

**图片格式支持**:
- PNG 输出 (当前仅支持 PPM)
- EXR 输出 (HDR)

**后处理**:
- Tone Mapping (Reinhard, ACES)
- Bloom 效果
- 降噪 (AI-based Denoiser)

**几何体扩展**:
- Triangle Mesh (三角面片)
- OBJ 文件加载
- 法线贴图

**性能优化**:
- Wavefront Path Tracing (更高 GPU 利用率)
- 双向路径追踪 (BDPT)

---

## 技术架构

### 项目结构

```
ray_tracing_gpu/
├── Sources/
│   ├── Core/           # 核心数学 (Vec3, Ray, Color, Interval)
│   ├── Geometry/       # 几何图元 (Sphere, Quad)
│   ├── Materials/      # 材质系统 (Material, Texture)
│   ├── Acceleration/   # BVH 加速结构 (AABB, FlatBVH)
│   ├── Transforms/     # 几何变换 (Transform)
│   ├── Camera/         # 相机 (Camera, CameraConfig)
│   ├── Rendering/      # 渲染器 (Renderer)
│   ├── Scene/          # 场景管理 (Scene, GeometryList)
│   ├── Scenes/         # 场景定义 (BouncingSpheres, CornellBox, ...)
│   ├── GPU/            # Metal 管理 (MetalContext, GPUStructs)
│   ├── Utils/          # 工具类 (CommandLineArgs, ImageLoader, ImageWriter)
│   └── main.swift      # 主程序入口
├── Shaders/
│   ├── Common/
│   │   ├── Types.metal         # GPU 数据结构
│   │   ├── Random.metal        # PCG 随机数生成器
│   │   ├── Geometry.metal      # 几何相交测试
│   │   ├── Materials.metal     # 材质散射
│   │   ├── Textures.metal      # 纹理采样
│   │   ├── Transform.metal     # 几何变换
│   │   └── Acceleration.metal  # BVH 遍历
│   └── Kernels/
│       ├── RayTracing.metal       # 主渲染内核
│       ├── Accumulation.metal     # 累积渲染 (预留)
│       └── ColorConversion.metal  # 颜色转换 (预留)
├── Resources/
│   ├── images/         # 纹理图片 (earthmap.jpg)
│   └── default.metallib  # 编译后的着色器
├── docs/               # 开发文档
└── compile_shaders.sh  # 着色器编译脚本
```

**代码规模**:
- Swift 文件: 27 个 (~3000 行)
- Metal 文件: 10 个 (~1400 行)
- 总计: ~4400 行

---

## GPU 数据结构设计

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

**内存对齐验证**: 使用 `MemoryLayout<T>.stride` 确保正确性

---

## 关键技术要点

### 1. Swift 与 Metal 互操作

- **类型映射**: `SIMD3<Float>` ↔ `float3`
- **手动填充**: 确保 16 字节对齐
- **缓冲区传输**: `.storageModeShared` 零拷贝

### 2. BVH 加速结构

- **CPU 构建**: SAH (Surface Area Heuristic) 分割
- **扁平化**: 线性数组存储 (GPU 友好)
- **GPU 遍历**: 迭代式 (32 层固定栈)

### 3. 路径追踪算法

- **迭代式实现**: 避免递归 (Metal 限制)
- **Russian Roulette**: 动态终止光线
- **材质采样**: 余弦加权半球采样

### 4. 纹理采样

- **图像纹理**: Metal texture2d + 线性采样
- **Perlin 噪声**: GPU 端哈希函数生成置换表
- **UV 坐标**: 自动计算 (球体、四边形)

---

## 使用方法

### 编译着色器
```bash
./compile_shaders.sh
```

### 渲染场景
```bash
# Cornell Box (600×600, 100 spp)
swift run raytracer --scene cornellBox --spp 100 --width 600

# Final Scene (800×800, 10 spp)
swift run raytracer --scene finalScene --spp 10 --width 800 --output final.ppm

# 完整参数
swift run raytracer \
  --scene <sceneName> \
  --spp <samplesPerPixel> \
  --max-depth <maxDepth> \
  --width <imageWidth> \
  --output <filename>
```

**可用场景**:
- `bouncingSpheres` - 485 个随机球体
- `cornellBox` - Cornell 盒子
- `textureTest` - 地球纹理测试
- `finalScene` - 完整演示场景

---

## 参考资源

**原项目**:
- ~/ray_tracing/CLAUDE.md - CPU 版本技术文档

**官方文档**:
- [Metal Programming Guide](https://developer.apple.com/metal/)
- [Metal Shading Language Specification](https://developer.apple.com/metal/Metal-Shading-Language-Specification.pdf)

**学术资源**:
- Peter Shirley - "Ray Tracing in One Weekend" 系列
- PBRT - "Physically Based Rendering"

---

**文档版本**: v3.0
**最后更新**: 2025-12-02
**当前状态**: Phase 1-3 ✅ 完成 → Phase 4 ⏳ 待开始
