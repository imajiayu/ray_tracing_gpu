# Ray Tracing GPU - 基于 Metal 的 GPU 光线追踪渲染器

**项目类型**: 纯 Swift + Metal 实现
**目标平台**: macOS (Apple Silicon / Intel)
**技术栈**: Swift 5.9+, Metal 3, MetalKit
**参考项目**: ~/ray_tracing (C++ CPU 版本)

---

## 项目概述

使用 Swift 和 Metal 实现的 GPU 加速物理真实感光线追踪渲染器。

**核心特性**:
- ✅ **双渲染模式**: 离线图片渲染 + 实时窗口预览
- ✅ **GPU 路径追踪**: 迭代式算法 + SAH-BVH 加速
- ✅ **完整材质系统**: Lambertian / Metal / Dielectric / DiffuseLight
- ✅ **纹理支持**: 纯色 / 棋盘格 / 图像 / Perlin 噪声
- ✅ **多重重要性采样**: Power Heuristic MIS
- ✅ **实时交互**: FPS 相机控制 + 累积渲染

---

## 当前状态 (Phase 1-6 已完成)

### 渲染功能

**渲染模式**:
- 离线图片渲染 (PPM 输出)
- 实时窗口模式 (60 FPS 交互)

**核心算法**:
- GPU 路径追踪 (迭代式，无递归)
- SAH-BVH 加速结构 (O(log N) 遍历)
- Power Heuristic MIS (直接光源采样)
- PCG 随机数生成器

**材质系统**:
- Lambertian (余弦加权漫反射)
- Metal (金属反射 + 模糊度)
- Dielectric (电介质折射 + Schlick 近似)
- DiffuseLight (发光材质)

**纹理系统**:
- SolidColor (纯色)
- CheckerTexture (3D 棋盘格)
- ImageTexture (JPEG/PNG)
- NoiseTexture (Perlin 梯度噪声)

**几何体**:
- Sphere (球体)
- Quad (四边形)
- Box (由 6 个 Quad 组成)

**几何变换**:
- Translation (平移)
- RotationY (Y 轴旋转)

### 实时窗口功能 (Phase 6)

**渲染特性**:
- 累积渲染 (静止时渐进提升质量)
- 智能重置 (相机移动时自动重置)
- 质量预设 (1/2/3 键: 1/4/8 spp/frame)

**相机控制**:
- FPS 风格移动 (WASD + Space/Shift)
- 鼠标环顾 (自动捕获/ESC 释放)
- 焦距调节 (滚轮)
- 相机滚转 (Q/E 键)
- 景深调节 (+/- 键)

**HUD 显示**:
- FPS / 帧时间
- 累积采样数 (spp)
- 相机参数 (位置/焦距/光圈/FOV/滚转)
- Tab 键切换显示

### 性能表现

**离线渲染** (Phase 5 - SAH-BVH + Power Heuristic):
| 场景 | 分辨率 | spp | 深度 | 渲染时间 | vs Phase 4 |
|------|-------|-----|------|---------|-----------|
| Cornell Box | 400×400 | 100 | 50 | **329 ms** | -31.8% ⚡ |
| Bouncing Spheres | 800×450 | 10 | 50 | **82 ms** | -54.5% 🚀 |
| Final Scene | 400×400 | 10 | 10 | **60 ms** | -32.1% ⚡ |

**实时渲染** (Phase 6 - Window Mode):
- Cornell Box (600×600): **60+ FPS @ 1 spp**
- Bouncing Spheres (800×450): **60+ FPS @ 1 spp**
- Final Scene (400×400): **30+ FPS @ 1 spp**

---

## 待实现功能 (Future Roadmap)

### 体积渲染
- [ ] ConstantMedium 几何体 (边界 + 密度)
- [ ] Isotropic 材质 (各向同性散射)
- [ ] 体积散射算法 (烟雾/云层效果)

### 几何体扩展
- [ ] Triangle Mesh (三角面片)
- [ ] OBJ 文件加载
- [ ] 法线贴图支持

### 图片格式
- [ ] PNG 输出 (替代 PPM)
- [ ] EXR 输出 (HDR)

### 后处理
- [ ] Tone Mapping (Reinhard / ACES)
- [ ] Bloom 效果
- [ ] AI-based 降噪器

### 性能优化
- [ ] Wavefront Path Tracing (更高 GPU 占用率)
- [ ] 双向路径追踪 (BDPT)
- [ ] 自适应采样 (快速收敛区域减少采样)

### UI 增强
- [ ] ImGui 集成 (参数编辑面板)
- [ ] 场景层次树显示
- [ ] 材质编辑器

---

## 技术架构

### 项目结构

```
ray_tracing_gpu/
├── Sources/
│   ├── Core/           # 核心数学 (Vec3, Ray, Color, Interval)
│   ├── Geometry/       # 几何图元 (Sphere, Quad)
│   ├── Materials/      # 材质系统 (Material, Texture, PerlinData)
│   ├── Acceleration/   # BVH 加速结构 (AABB, FlatBVH - SAH)
│   ├── Transforms/     # 几何变换 (Transform)
│   ├── Camera/         # 相机 (Camera, CameraConfig)
│   ├── Rendering/      # 渲染器 (Renderer - 双模式)
│   ├── Scene/          # 场景管理 (Scene, GeometryList)
│   ├── Scenes/         # 场景定义 (4 个测试场景)
│   ├── GPU/            # Metal 管理 (MetalContext, GPUStructs)
│   ├── Window/         # 实时窗口 (AppDelegate, RealtimeRenderer, InputController, HUDRenderer)
│   ├── Utils/          # 工具类 (CommandLineArgs, ImageLoader, ImageWriter, RenderStats)
│   └── main.swift      # 主程序入口
├── Shaders/
│   ├── Common/
│   │   ├── Types.metal         # GPU 数据结构
│   │   ├── Random.metal        # PCG 随机数生成器
│   │   ├── Geometry.metal      # 几何相交测试
│   │   ├── Materials.metal     # 材质散射
│   │   ├── Textures.metal      # 纹理采样
│   │   ├── Transform.metal     # 几何变换
│   │   ├── Acceleration.metal  # BVH 遍历
│   │   └── PDF.metal           # MIS PDF 系统
│   └── Kernels/
│       ├── RayTracing.metal    # 主渲染内核 (离线 + 实时)
│       ├── Accumulation.metal  # 累积渲染内核
│       ├── Blit.metal          # 显示到屏幕
│       └── HUD.metal           # HUD 文字渲染
├── Resources/
│   ├── images/         # 纹理图片 (earthmap.jpg)
│   └── default.metallib  # 编译后的着色器
├── docs/               # 开发文档
└── compile_shaders.sh  # 着色器编译脚本
```

**代码规模**:
- Swift 文件: 33 个 (~5250 行)
- Metal 文件: 12 个 (~2065 行)
- 总计: ~7315 行

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

### 1. 双渲染模式架构

**离线模式** (Image Mode):
- 命令行参数: `--mode image` (默认)
- 批次渲染: 可配置 batch_size (默认 10)
- 输出格式: PPM 文件
- 统计信息: 渲染时间、性能分析

**实时模式** (Window Mode):
- 命令行参数: `--mode window`
- 累积渲染: GPU 端累积纹理 (RGBA32Float)
- 帧率: 60 FPS 目标 @ 1-8 spp/frame
- 交互控制: WASD + 鼠标 + HUD

### 2. Swift 与 Metal 互操作

- **类型映射**: `SIMD3<Float>` ↔ `float3`
- **手动填充**: 确保 16 字节对齐 (`MemoryLayout<T>.stride`)
- **缓冲区传输**: `.storageModeShared` 零拷贝

### 3. BVH 加速结构

- **CPU 构建**: SAH (Surface Area Heuristic) 16-bin 分割
- **扁平化**: 线性数组存储 (GPU 友好)
- **GPU 遍历**: 迭代式 (32 层固定栈)
- **性能**: O(log N) 遍历，-39.5% 平均加速

### 4. 路径追踪算法

- **迭代式实现**: 避免递归 (Metal 限制)
- **Russian Roulette**: 动态终止光线
- **Power Heuristic MIS**: 自适应光源/BRDF 权重
- **Next Event Estimation**: 直接光源采样

### 5. 实时渲染技术

**累积渲染**:
- GPU 端累积缓冲区 (RGBA32Float)
- 智能重置 (相机变化检测)
- 渐进式质量提升 (静止时累积到高质量)

**输入控制**:
- FPS 相机系统 (yaw/pitch/roll)
- WASD 移动 + 鼠标环顾
- 鼠标捕获 (自动隐藏光标)
- 实时参数调节 (焦距/景深/质量)

**显示流水线**:
1. Compute Shader → RGBA32Float 中间纹理
2. Accumulation Shader → 累积纹理
3. Blit Render Pipeline → BGRA8Unorm drawable
4. HUD Overlay → 透明文字叠加

---

## 使用方法

### 编译着色器
```bash
./compile_shaders.sh
```

### 离线图片渲染
```bash
# Cornell Box (600×600, 100 spp)
swift run raytracer --mode image --scene cornellBox --spp 100 --width 600

# Final Scene (800×800, 10 spp)
swift run raytracer --mode image --scene finalScene --spp 10 --width 800 --output final.ppm

# 完整参数
swift run raytracer \
  --mode image \
  --scene <sceneName> \
  --spp <samplesPerPixel> \
  --max-depth <maxDepth> \
  --width <imageWidth> \
  --batch-size <batchSize> \
  --output <filename>
```

### 实时窗口模式
```bash
# 默认窗口模式 (Cornell Box)
swift run raytracer --mode window --scene cornellBox

# 自定义分辨率和质量
swift run raytracer --mode window --scene bouncingSpheres --width 800 --batch-size 4

# 完整参数
swift run raytracer \
  --mode window \
  --scene <sceneName> \
  --width <imageWidth> \
  --batch-size <sppPerFrame> \
  --max-depth <maxDepth>
```

**实时窗口控制**:
- **WASD**: 前后左右移动
- **Space/Shift**: 上升/下降
- **鼠标**: 环顾视角 (自动捕获)
- **ESC**: 释放鼠标 / 退出
- **滚轮**: 调节焦距
- **+/-**: 调节景深光圈
- **Q/E**: 相机滚转
- **1/2/3**: 质量预设 (1/4/8 spp/frame)
- **Tab**: 切换 HUD 显示

**可用场景**:
- `bouncingSpheres` - 485 个随机球体
- `cornellBox` - Cornell 盒子 + 玻璃球 + 镜面盒子
- `finalScene` - 完整演示场景 (1006 球体 + 2401 四边形)

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
- Veach & Guibas 1995 - "Optimally Combining Sampling Techniques for Monte Carlo Rendering"

---

**文档版本**: v6.0
**最后更新**: 2025-12-09
**当前状态**: Phase 1-6 ✅ 全部完成

**项目里程碑**:
- Phase 1-3: 基础渲染器 (GPU 路径追踪 + BVH + 材质纹理)
- Phase 4: 多重重要性采样 (3.4× 收敛加速)
- Phase 5: SAH-BVH + Power Heuristic (39.5% 性能提升)
- Phase 6: 实时窗口模式 (60 FPS 交互 + 累积渲染)

**技术成就**:
- ✅ 纯 Swift/Metal 实现 (~7315 行代码)
- ✅ 双渲染模式 (离线 + 实时)
- ✅ 完整的物理材质和纹理系统
- ✅ SAH-BVH 加速结构
- ✅ Power Heuristic MIS
- ✅ FPS 相机控制 + HUD 显示
