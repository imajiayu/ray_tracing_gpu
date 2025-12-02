# Ray Tracing GPU

基于 Swift + Metal 的 GPU 光线追踪渲染器

## 项目状态

**当前阶段**: Phase 2 ✅ 完成

### Phase 1 已完成 ✅
- ✅ Swift Package 项目结构
- ✅ 核心数学库 (Vec3, Ray, Color, Interval)
- ✅ Metal 上下文管理
- ✅ GPU 数据结构定义 (内存对齐)
- ✅ Metal 着色器编译系统
- ✅ 球体几何 + Lambertian 材质
- ✅ GPU 路径追踪内核
- ✅ **成功渲染 3 球场景** (800×450 @ 10 spp @ 13.79 ms)

### Phase 2 已完成 ✅
- ✅ Metal 材质 (镜面反射 + 模糊反射)
- ✅ Dielectric 材质 (玻璃折射 + Schlick 近似)
- ✅ DiffuseLight 发光材质
- ✅ Quad 几何体 (平面矩形)
- ✅ **Cornell Box** (600×600 @ 1000 spp @ 576 ms @ 625 M rays/s)
- ✅ **Bouncing Spheres** (800×450 @ 500 spp @ 51 ms @ 3553 M rays/s, 487 球体)

### Phase 3 计划
- BVH 加速结构
- 多重要性采样 (MIS)
- 实时渲染窗口

## 快速开始

### 环境要求
- macOS 13.0+
- Xcode 15.0+
- Swift 5.9+
- Apple Silicon 或 Intel Mac (支持 Metal)

### 编译运行

```bash
# 1. 编译 Metal 着色器
./compile_shaders.sh

# 2. 编译 Swift 代码
swift build

# 3. 运行测试
.build/debug/raytracer
```

### 可用场景

在 `Sources/Main/main.swift` 中修改 `currentScene` 来切换场景：

```swift
let currentScene: SceneType = .cornellBox  // 选择场景
```

**可用场景**:
- `.simple3Spheres` - 简单 3 球测试 (10 spp)
- `.metalMaterialTest` - Metal 材质测试 (50 spp)
- `.dielectricTest` - Dielectric 测试 (100 spp)
- `.diffuseLightTest` - 发光材质测试 (100 spp)
- `.simpleCornellBox` - 简化 Cornell Box (200 spp)
- `.bouncingSpheres` - 经典 Bouncing Spheres (500 spp, 487 球体)
- `.cornellBox` - 标准 Cornell Box (1000 spp)

### 性能数据

| 场景 | 分辨率 | SPP | 时间 | 性能 |
|------|--------|-----|------|------|
| Cornell Box | 600×600 | 1000 | 170 ms | 2115 M rays/s |
| Bouncing Spheres | 800×450 | 500 | 86 ms | 2088 M rays/s |
| Simple Cornell Box | 800×450 | 200 | 695 ms | 104 M rays/s |
| DiffuseLight Test | 800×450 | 100 | 67 ms | 535 M rays/s |

**测试环境**: Apple M2 Pro

## 项目结构

```
ray_tracing_gpu/
├── Sources/
│   ├── Core/           # 核心数学库 (Vec3, Ray, Color)
│   ├── GPU/            # Metal 上下文和 GPU 数据结构
│   ├── Geometry/       # 几何体定义 (Sphere, Quad)
│   ├── Materials/      # 材质定义 (Lambertian, Metal, Dielectric, DiffuseLight)
│   ├── Scene/          # 场景定义
│   └── Main/           # 主程序
├── Shaders/
│   ├── Common/         # 通用 Metal 函数 (Types, Random, Geometry, Materials)
│   └── Kernels/        # 光线追踪内核
├── Resources/          # 编译后的 .metallib
├── docs/               # 开发文档
├── CLAUDE.md           # 完整技术文档
└── README.md           # 本文档
```

## 技术特性

### 渲染能力
- **4 种材质**: Lambertian (漫反射), Metal (镜面), Dielectric (玻璃), DiffuseLight (发光)
- **2 种几何体**: Sphere (球体), Quad (平面矩形)
- **路径追踪**: 迭代式路径追踪 (无递归)
- **物理光照**: 菲涅尔反射、折射、漫反射

### 技术实现
- **纯 GPU 渲染**: 所有光线追踪计算在 Metal GPU 上进行
- **Swift 原生**: 无 C++ 依赖，充分利用 Swift 语言特性
- **SIMD 类型**: 使用 Swift SIMD3<Float> 简化向量运算
- **GPU 内存对齐**: 所有结构体对齐到 16 字节倍数
- **PCG 随机数**: 高质量伪随机数生成器
- **动态相机**: 支持 look-at 相机系统，可调 FOV

## 参考项目

本项目参考了 `~/ray_tracing` (C++ CPU/GPU 混合渲染器)

## License

教育用途
