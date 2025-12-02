# Phase 2: 完整材质与几何体

**目标**: 实现所有材质类型和基础几何体
**时间**: 预计 3-4 天
**状态**: 📋 准备开始

---

## 概述

Phase 2 将在 Phase 1 的基础上，完成完整的材质系统和扩展几何体，为渲染 Cornell Box 等复杂场景做准备。

**核心任务**:
1. 测试 Metal 和 Dielectric 材质（GPU 端已实现）
2. 实现 DiffuseLight 发光材质
3. 实现 Quad/Box/Triangle 几何体
4. 实现基础纹理系统（SolidColor, CheckerTexture）
5. 渲染 Cornell Box 场景验证

---

## 任务分解

### Task 2.1: 测试 Metal 材质 (Day 8)

**目标**: 验证 GPU 端 Metal 材质的正确性

**参考文件**:
- `~/ray_tracing/include/materials/material.h:metal`
- `Shaders/Common/Materials.metal:metal_scatter` (已实现)

**具体步骤**:

1. **创建测试场景** - 更新 `main.swift`
   - 3 个球体：Lambertian、Metal(fuzz=0)、Metal(fuzz=0.5)
   - 验证镜面反射效果
   - 验证模糊反射效果

2. **渲染参数**
   - 分辨率: 800×450
   - 采样: 50 spp（Metal 材质需要更多采样）
   - 最大深度: 50

**验收标准**:
- ✅ Metal(fuzz=0) 显示清晰镜面反射
- ✅ Metal(fuzz=0.5) 显示模糊反射
- ✅ 性能: < 50 ms @ 50 spp

---

### Task 2.2: 测试 Dielectric 材质 (Day 9)

**目标**: 验证 GPU 端 Dielectric 材质的正确性

**参考文件**:
- `~/ray_tracing/include/materials/material.h:dielectric`
- `Shaders/Common/Materials.metal:dielectric_scatter` (已实现)

**具体步骤**:

1. **创建测试场景**
   - 3 个球体：Dielectric(1.5)、Dielectric(1.5 负半径)、Lambertian
   - 验证折射效果
   - 验证全内反射
   - 验证空心玻璃球效果

2. **渲染参数**
   - 分辨率: 800×450
   - 采样: 100 spp（玻璃材质噪声大）
   - 最大深度: 50

**验收标准**:
- ✅ 玻璃球显示透明折射效果
- ✅ 负半径球显示空心玻璃效果
- ✅ 性能: < 100 ms @ 100 spp

---

### Task 2.3: 实现 DiffuseLight 材质 (Day 10)

**目标**: 实现发光材质，为 Cornell Box 做准备

**参考文件**:
- `~/ray_tracing/include/materials/material.h:diffuse_light`

**具体步骤**:

1. **更新 CPU 端** - `Materials/Material.swift`
```swift
extension Material {
    static func diffuseLight(emit: Color) -> Material {
        return Material(
            type: .diffuseLight,
            albedo: emit,
            fuzz: 0,
            refractionIndex: 1.0
        )
    }
}
```

2. **更新 GPU 端** - `Shaders/Common/Materials.metal`
```metal
// DiffuseLight 不散射，只发光
inline bool diffuse_light_scatter(...) {
    return false;  // 吸收所有入射光线
}

// 更新 material_scatter
case MaterialDiffuseLight:
    return diffuse_light_scatter(mat, r_in, rec, attenuation, scattered, rng);
```

3. **更新路径追踪内核** - `Shaders/Kernels/SimpleRayTracing.metal`
```metal
// 在 hit_anything 分支中添加发光检测
if (hit_anything) {
    // 检查是否是发光材质
    GPUMaterial mat = materials[rec.material_index];
    if (mat.type == MaterialDiffuseLight) {
        // 返回发光颜色（不继续追踪）
        accumulated_color *= mat.albedo;
        return accumulated_color;
    }

    // 原有的散射逻辑...
}
```

4. **创建测试场景**
   - 1 个发光球体 + 2 个 Lambertian 球体
   - 黑色背景（验证只有光源发光）

**验收标准**:
- ✅ 发光球体正确显示
- ✅ 其他物体被照亮
- ✅ 黑色背景不受天空影响

---

### Task 2.4: 实现 Quad 几何体 (Day 11)

**目标**: 实现四边形，为 Cornell Box 做准备

**参考文件**:
- `~/ray_tracing/include/geometry/quad.h`

**具体步骤**:

1. **CPU 端** - `Geometry/Quad.swift`
```swift
struct Quad {
    var Q: Point3           // 角点
    var u: Vec3             // 第一条边
    var v: Vec3             // 第二条边
    var materialIndex: UInt32

    // 计算法线和平面常数
    var normal: Vec3 {
        simd_cross(u, v).normalized
    }

    var D: Float {
        -simd_dot(normal, Q)
    }

    func toGPU() -> GPUQuad {
        return GPUQuad(
            Q: Q,
            u: u,
            v: v,
            normal: normal,
            D: D,
            materialIndex: materialIndex,
            padding: .zero
        )
    }
}
```

2. **GPU 数据结构** - `GPU/GPUStructs.swift`
```swift
struct GPUQuad {
    var Q: SIMD3<Float>
    var u: SIMD3<Float>
    var v: SIMD3<Float>
    var normal: SIMD3<Float>
    var D: Float
    var materialIndex: UInt32
    var padding: SIMD2<Float>
}  // 64 bytes
```

3. **GPU 端** - `Shaders/Common/Geometry.metal`
```metal
struct GPUQuad {
    float3 Q;
    float3 u;
    float3 v;
    float3 normal;
    float D;
    uint material_index;
    float2 padding;
};

inline bool quad_hit(
    GPUQuad quad,
    Ray r,
    float t_min,
    float t_max,
    thread HitRecord* rec
) {
    // 光线-平面相交
    float denom = dot(quad.normal, r.direction);
    if (fabs(denom) < 1e-8f) {
        return false;  // 光线平行于平面
    }

    // 计算交点参数 t
    float t = -(dot(quad.normal, r.origin) + quad.D) / denom;
    if (t < t_min || t > t_max) {
        return false;
    }

    // 计算交点位置
    float3 intersection = ray_at(r, t);
    float3 planar_hitpt_vector = intersection - quad.Q;

    // 计算平面坐标 (alpha, beta)
    float alpha = dot(quad.w, cross(planar_hitpt_vector, quad.v));
    float beta = dot(quad.w, cross(quad.u, planar_hitpt_vector));

    // 检查是否在四边形内
    if (alpha < 0.0f || alpha > 1.0f || beta < 0.0f || beta > 1.0f) {
        return false;
    }

    // 记录命中信息
    rec->t = t;
    rec->p = intersection;
    rec->material_index = quad.material_index;
    set_face_normal(rec, r, quad.normal);

    return true;
}
```

4. **测试场景**
   - 1 个 Quad 作为墙面 + 2 个球体
   - 验证光线-平面相交

**验收标准**:
- ✅ Quad 正确渲染
- ✅ 光线平面相交测试正确

---

### Task 2.5: 实现 Box 几何体 (Day 12)

**目标**: 使用 6 个 Quad 组合成长方体

**参考文件**:
- `~/ray_tracing/include/geometry/quad.h:box()`

**具体步骤**:

1. **CPU 端** - `Geometry/Box.swift`
```swift
struct Box {
    var minPoint: Point3
    var maxPoint: Point3
    var materialIndex: UInt32

    // 生成 6 个面的 Quad
    func toQuads() -> [Quad] {
        let dx = SIMD3<Float>(maxPoint.x - minPoint.x, 0, 0)
        let dy = SIMD3<Float>(0, maxPoint.y - minPoint.y, 0)
        let dz = SIMD3<Float>(0, 0, maxPoint.z - minPoint.z)

        return [
            // 前后面
            Quad(Q: minPoint, u: dx, v: dy, materialIndex: materialIndex),
            Quad(Q: SIMD3(maxPoint.x, minPoint.y, maxPoint.z), u: -dx, v: dy, materialIndex: materialIndex),
            // 左右面
            Quad(Q: minPoint, u: dz, v: dy, materialIndex: materialIndex),
            Quad(Q: SIMD3(maxPoint.x, minPoint.y, minPoint.z), u: -dz, v: dy, materialIndex: materialIndex),
            // 上下面
            Quad(Q: minPoint, u: dx, v: dz, materialIndex: materialIndex),
            Quad(Q: SIMD3(minPoint.x, maxPoint.y, minPoint.z), u: dx, v: -dz, materialIndex: materialIndex)
        ]
    }
}
```

2. **测试场景**
   - 1 个 Box + 2 个球体
   - 验证 6 个面正确渲染

**验收标准**:
- ✅ Box 所有 6 个面正确显示
- ✅ 面的朝向正确

---

### Task 2.6: 实现基础纹理系统 (Day 13)

**目标**: 实现 SolidColor 和 CheckerTexture

**参考文件**:
- `~/ray_tracing/include/materials/texture.h`

**具体步骤**:

1. **CPU 端** - `Textures/Texture.swift`
```swift
enum TextureType: UInt32 {
    case solid = 0
    case checker = 1
    case image = 2
    case noise = 3
}

struct Texture {
    var type: TextureType
    var color1: Color       // 主颜色 / 棋盘颜色1
    var color2: Color       // 次颜色 / 棋盘颜色2
    var scale: Float        // 棋盘/噪声缩放

    static func solid(color: Color) -> Texture {
        return Texture(type: .solid, color1: color, color2: .zero, scale: 1.0)
    }

    static func checker(even: Color, odd: Color, scale: Float = 1.0) -> Texture {
        return Texture(type: .checker, color1: even, color2: odd, scale: scale)
    }
}
```

2. **更新 Material** - 添加纹理索引
```swift
struct Material {
    var type: MaterialType
    var textureIndex: UInt32  // 新增
    var albedo: Color         // 纯色时使用
    var fuzz: Float
    var refractionIndex: Float
}
```

3. **GPU 端** - `Shaders/Common/Textures.metal`
```metal
struct GPUTexture {
    uint type;
    float3 color1;
    float3 color2;
    float scale;
};

inline float3 texture_value(
    GPUTexture tex,
    float2 uv,
    float3 p
) {
    switch (tex.type) {
        case TextureSolid:
            return tex.color1;

        case TextureChecker: {
            // 3D 棋盘纹理
            int3 sines = int3(
                floor(tex.scale * p.x),
                floor(tex.scale * p.y),
                floor(tex.scale * p.z)
            );
            bool is_even = ((sines.x + sines.y + sines.z) % 2) == 0;
            return is_even ? tex.color1 : tex.color2;
        }

        default:
            return float3(1, 0, 1);  // 洋红色表示错误
    }
}
```

4. **测试场景**
   - 棋盘纹理地面 + 纯色球体
   - 验证 3D 棋盘效果

**验收标准**:
- ✅ SolidColor 正确显示
- ✅ CheckerTexture 3D 棋盘效果正确

---

### Task 2.7: 渲染 Cornell Box (Day 14)

**目标**: 综合测试所有材质和几何体

**参考文件**:
- `~/ray_tracing/src/scenes/cornell_box.cc`

**具体步骤**:

1. **创建场景** - `Scene/CornellBox.swift`
```swift
func createCornellBox() -> ([Quad], [Sphere], [Material], Camera) {
    var quads: [Quad] = []
    var spheres: [Sphere] = []
    var materials: [Material] = []

    // 材质索引
    let redIdx: UInt32 = 0
    let whiteIdx: UInt32 = 1
    let greenIdx: UInt32 = 2
    let lightIdx: UInt32 = 3

    materials = [
        Material.lambertian(albedo: Color(0.65, 0.05, 0.05)),  // 红墙
        Material.lambertian(albedo: Color(0.73, 0.73, 0.73)),  // 白墙
        Material.lambertian(albedo: Color(0.12, 0.45, 0.15)),  // 绿墙
        Material.diffuseLight(emit: Color(15, 15, 15))         // 光源
    ]

    // 5 面墙 (左、右、下、上、后)
    quads.append(Quad(Q: Point3(555, 0, 0), u: Vec3(0, 555, 0), v: Vec3(0, 0, 555), materialIndex: greenIdx))  // 左绿墙
    quads.append(Quad(Q: Point3(0, 0, 0), u: Vec3(0, 555, 0), v: Vec3(0, 0, 555), materialIndex: redIdx))     // 右红墙
    quads.append(Quad(Q: Point3(0, 0, 0), u: Vec3(555, 0, 0), v: Vec3(0, 0, 555), materialIndex: whiteIdx))   // 底
    quads.append(Quad(Q: Point3(555, 555, 555), u: Vec3(-555, 0, 0), v: Vec3(0, 0, -555), materialIndex: whiteIdx))  // 顶
    quads.append(Quad(Q: Point3(0, 0, 555), u: Vec3(555, 0, 0), v: Vec3(0, 555, 0), materialIndex: whiteIdx)) // 后墙

    // 光源
    quads.append(Quad(Q: Point3(213, 554, 227), u: Vec3(130, 0, 0), v: Vec3(0, 0, 105), materialIndex: lightIdx))

    // 2 个球体
    spheres.append(Sphere(center: Point3(190, 90, 190), radius: 90, materialIndex: whiteIdx))
    spheres.append(Sphere(center: Point3(370, 165, 375), radius: 90, materialIndex: whiteIdx))

    return (quads, spheres, materials, camera)
}
```

2. **更新渲染内核** - 支持 Quad 和 Sphere 混合场景

3. **渲染参数**
   - 分辨率: 600×600 (1:1)
   - 采样: 100 spp
   - 最大深度: 50
   - 背景: 黑色

**验收标准**:
- ✅ 红绿墙面正确显示
- ✅ 白色天花板和地面
- ✅ 顶部光源照亮场景
- ✅ 两个球体被正确照亮
- ✅ 性能: < 500 ms @ 100 spp

---

## 里程碑验收

**Phase 2 完成标准**:
- ✅ Metal 和 Dielectric 材质测试通过
- ✅ DiffuseLight 发光材质实现
- ✅ Quad 几何体实现
- ✅ Box 几何体实现
- ✅ SolidColor 和 CheckerTexture 实现
- ✅ Cornell Box 场景渲染成功
- ✅ 性能达标 (Cornell Box < 500 ms @ 100 spp)

**下一步**: Phase 3 - BVH 加速结构

---

## 技术要点

### 1. 发光材质处理

**关键**: 发光材质不散射，直接返回发光颜色
```metal
if (mat.type == MaterialDiffuseLight) {
    accumulated_color *= mat.albedo;
    return accumulated_color;
}
```

### 2. Quad 相交测试

**算法**:
1. 计算光线与平面的交点 (t)
2. 计算交点的平面坐标 (alpha, beta)
3. 检查是否在 [0,1]×[0,1] 范围内

### 3. 纹理采样

**策略**:
- SolidColor: 直接返回颜色
- CheckerTexture: 基于世界坐标 3D 棋盘
- 后续: ImageTexture 和 NoiseTexture

### 4. 混合几何场景

**处理**:
- 分别测试所有 Sphere 和 Quad
- 记录最近的命中点
- 统一处理材质散射

---

## 性能优化建议

1. **减少分支分歧**
   - 材质类型分支尽量合并
   - 使用 switch-case 而非多个 if-else

2. **内存访问优化**
   - 球体和四边形数据连续存储
   - 减少缓冲区数量

3. **采样优化**
   - 发光材质场景使用更少采样
   - Dielectric 材质需要更多采样

---

**文档版本**: v1.0
**创建日期**: 2025-11-26
**状态**: 📋 准备开始
