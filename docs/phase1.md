# Phase 1: 核心基础设施 (Week 1-2)

**目标**: 建立 Swift 项目基础，实现核心数学库和 Metal 上下文，渲染第一个球体

**时间**: Day 1-7 (预计 7 天)

**状态**: 🚀 进行中

---

## 任务分解

### Task 1.1: 项目初始化 (Day 1)

**目标**: 创建 Swift Package Manager 项目结构

**具体步骤**:
- [x] 创建 `docs/` 目录
- [ ] 初始化 Swift Package (executable)
- [ ] 配置 `Package.swift` (依赖 MetalKit, AppKit)
- [ ] 创建核心目录结构 (Sources/, Shaders/, Resources/, Tests/)
- [ ] 配置 `.gitignore`
- [ ] 初始 Git commit

**验收标准**:
- ✅ `swift build` 成功编译
- ✅ 目录结构完整
- ✅ Git 仓库初始化

---

### Task 1.2: 核心数学库 (Day 2-3)

**目标**: 实现基础数学类型和工具函数

**参考文件**:
- `~/ray_tracing/include/core/vec3.h` - Vec3 实现参考
- `~/ray_tracing/include/core/ray.h` - Ray 实现参考
- `~/ray_tracing/include/core/color.h` - Color 实现参考

**具体步骤**:

#### 1.2.1 Vec3.swift (基础向量类型)
```swift
// Sources/Core/Vec3.swift
import simd

// 使用 Swift SIMD 类型别名（简单清晰）
typealias Vec3 = SIMD3<Float>
typealias Point3 = SIMD3<Float>

// 扩展方法
extension SIMD3 where Scalar == Float {
    // 长度相关
    var length: Float { simd_length(self) }
    var lengthSquared: Float { simd_length_squared(self) }

    // 归一化
    var normalized: SIMD3<Float> { simd_normalize(self) }

    // 随机向量（参考 vec3_random.h）
    static func random() -> SIMD3<Float> {
        SIMD3<Float>(Float.random(in: 0..<1),
                     Float.random(in: 0..<1),
                     Float.random(in: 0..<1))
    }

    static func random(in range: Range<Float>) -> SIMD3<Float> {
        SIMD3<Float>(Float.random(in: range),
                     Float.random(in: range),
                     Float.random(in: range))
    }

    // 随机单位向量（半球采样）
    static func randomUnitVector() -> SIMD3<Float> {
        // 参考 vec3_random.h:random_unit_vector()
        while true {
            let p = SIMD3<Float>.random(in: -1..<1)
            let lensq = simd_length_squared(p)
            if lensq < 1 && lensq > 1e-8 {
                return p / sqrt(lensq)
            }
        }
    }

    static func randomOnHemisphere(_ normal: SIMD3<Float>) -> SIMD3<Float> {
        let onUnitSphere = randomUnitVector()
        if simd_dot(onUnitSphere, normal) > 0.0 {
            return onUnitSphere
        } else {
            return -onUnitSphere
        }
    }

    // 反射（参考 vec3.h:reflect）
    func reflect(n: SIMD3<Float>) -> SIMD3<Float> {
        return self - 2 * simd_dot(self, n) * n
    }

    // 折射（参考 vec3.h:refract）
    func refract(n: SIMD3<Float>, etaiOverEtat: Float) -> SIMD3<Float> {
        let cosTheta = min(simd_dot(-self, n), 1.0)
        let rOutPerp = etaiOverEtat * (self + cosTheta * n)
        let rOutParallel = -sqrt(abs(1.0 - simd_length_squared(rOutPerp))) * n
        return rOutPerp + rOutParallel
    }

    // 近零检测
    var isNearZero: Bool {
        let s: Float = 1e-8
        return abs(x) < s && abs(y) < s && abs(z) < s
    }
}
```

#### 1.2.2 Ray.swift
```swift
// Sources/Core/Ray.swift
import simd

struct Ray {
    var origin: Point3
    var direction: Vec3
    var time: Float

    init(origin: Point3, direction: Vec3, time: Float = 0.0) {
        self.origin = origin
        self.direction = direction
        self.time = time
    }

    func at(_ t: Float) -> Point3 {
        return origin + t * direction
    }
}
```

#### 1.2.3 Color.swift
```swift
// Sources/Core/Color.swift
import simd

typealias Color = SIMD3<Float>

extension Color {
    // Gamma 校正 (gamma = 2)
    var gammaCorrected: Color {
        return Color(sqrt(x), sqrt(y), sqrt(z))
    }

    // 转换为 0-255 整数
    func toRGB255() -> (r: UInt8, g: UInt8, b: UInt8) {
        let corrected = self.gammaCorrected
        let r = UInt8(256 * corrected.x.clamped(to: 0..<0.999))
        let g = UInt8(256 * corrected.y.clamped(to: 0..<0.999))
        let b = UInt8(256 * corrected.z.clamped(to: 0..<0.999))
        return (r, g, b)
    }
}

// Float clamping 工具
extension Float {
    func clamped(to range: Range<Float>) -> Float {
        return max(range.lowerBound, min(self, range.upperBound - Float.ulpOfOne))
    }
}
```

#### 1.2.4 Interval.swift
```swift
// Sources/Core/Interval.swift
struct Interval {
    var min: Float
    var max: Float

    static let empty = Interval(min: Float.infinity, max: -Float.infinity)
    static let universe = Interval(min: -Float.infinity, max: Float.infinity)

    init(min: Float, max: Float) {
        self.min = min
        self.max = max
    }

    func contains(_ x: Float) -> Bool {
        return min <= x && x <= max
    }

    func surrounds(_ x: Float) -> Bool {
        return min < x && x < max
    }

    func clamp(_ x: Float) -> Float {
        if x < min { return min }
        if x > max { return max }
        return x
    }
}
```

**验收标准**:
- ✅ 所有类型编译通过
- ✅ Vec3 扩展方法工作正常
- ✅ 单元测试通过 (可选)

---

### Task 1.3: Metal 基础设施 (Day 4-5)

**目标**: 建立 Metal 设备管理和着色器编译系统

**参考文件**:
- `~/ray_tracing/include/gpu/metal_context.h`
- `~/ray_tracing/src/gpu/metal_context.mm`

**具体步骤**:

#### 1.3.1 MetalContext.swift
```swift
// Sources/GPU/MetalContext.swift
import Metal
import MetalKit

class MetalContext {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue

    init?() {
        // 获取默认 Metal 设备
        guard let device = MTLCreateSystemDefaultDevice() else {
            print("[Metal] ❌ Failed to create Metal device")
            return nil
        }

        guard let commandQueue = device.makeCommandQueue() else {
            print("[Metal] ❌ Failed to create command queue")
            return nil
        }

        self.device = device
        self.commandQueue = commandQueue

        print("[Metal] ✓ Device: \(device.name)")
    }

    // 创建计算管线
    func makeComputePipeline(functionName: String, library: MTLLibrary) -> MTLComputePipelineState? {
        guard let function = library.makeFunction(name: functionName) else {
            print("[Metal] ❌ Failed to find function: \(functionName)")
            return nil
        }

        do {
            let pipeline = try device.makeComputePipelineState(function: function)
            print("[Metal] ✓ Pipeline created: \(functionName)")
            return pipeline
        } catch {
            print("[Metal] ❌ Failed to create pipeline: \(error)")
            return nil
        }
    }

    // 创建纹理
    func makeTexture(width: Int, height: Int, pixelFormat: MTLPixelFormat = .rgba32Float) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor()
        descriptor.pixelFormat = pixelFormat
        descriptor.width = width
        descriptor.height = height
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .shared

        return device.makeTexture(descriptor: descriptor)
    }

    // 创建缓冲区
    func makeBuffer<T>(array: [T]) -> MTLBuffer? {
        let size = MemoryLayout<T>.stride * array.count
        return device.makeBuffer(bytes: array, length: size, options: .storageModeShared)
    }
}
```

#### 1.3.2 Shaders/Common/Types.metal
```metal
// Shaders/Common/Types.metal
#ifndef TYPES_METAL
#define TYPES_METAL

#include <metal_stdlib>
using namespace metal;

// ========== 基础数据结构 ==========

struct Ray {
    float3 origin;
    float3 direction;
    float time;
};

// 光线在参数 t 处的位置
inline float3 ray_at(Ray r, float t) {
    return r.origin + t * r.direction;
}

// ========== 相机参数 ==========

struct CameraParams {
    float3 origin;
    float3 lower_left_corner;
    float3 horizontal;
    float3 vertical;
};

// ========== 渲染参数 ==========

struct RenderParams {
    uint width;
    uint height;
    uint samples_per_pixel;
    uint max_depth;
};

#endif // TYPES_METAL
```

#### 1.3.3 Shaders/Common/Random.metal
```metal
// Shaders/Common/Random.metal
// PCG 随机数生成器（参考 ~/ray_tracing 实现）

#ifndef RANDOM_METAL
#define RANDOM_METAL

#include <metal_stdlib>
using namespace metal;

// PCG 随机数状态
struct RandomState {
    uint state;
};

// 初始化随机数种子
inline RandomState random_init(uint seed) {
    RandomState rng;
    rng.state = seed;
    return rng;
}

// 生成随机 uint32
inline uint random_uint(thread RandomState* rng) {
    uint oldstate = rng->state;
    rng->state = oldstate * 747796405u + 2891336453u;
    uint word = ((oldstate >> ((oldstate >> 28u) + 4u)) ^ oldstate) * 277803737u;
    return (word >> 22u) ^ word;
}

// 生成 [0, 1) 随机浮点数
inline float random_float(thread RandomState* rng) {
    return float(random_uint(rng)) / 4294967296.0f;
}

// 生成 [min, max) 随机浮点数
inline float random_float_range(thread RandomState* rng, float min_val, float max_val) {
    return min_val + (max_val - min_val) * random_float(rng);
}

// 生成随机 float3 (0-1)
inline float3 random_vec3(thread RandomState* rng) {
    return float3(random_float(rng), random_float(rng), random_float(rng));
}

// 生成随机单位向量
inline float3 random_unit_vector(thread RandomState* rng) {
    while (true) {
        float3 p = random_vec3(rng) * 2.0f - 1.0f;
        float lensq = dot(p, p);
        if (lensq < 1.0f && lensq > 1e-8f) {
            return p / sqrt(lensq);
        }
    }
}

// 生成半球随机向量
inline float3 random_on_hemisphere(thread RandomState* rng, float3 normal) {
    float3 on_unit_sphere = random_unit_vector(rng);
    if (dot(on_unit_sphere, normal) > 0.0f) {
        return on_unit_sphere;
    } else {
        return -on_unit_sphere;
    }
}

#endif // RANDOM_METAL
```

#### 1.3.4 Shaders/Kernels/TestGradient.metal
```metal
// Shaders/Kernels/TestGradient.metal
// 测试着色器：渲染简单渐变

#include <metal_stdlib>
using namespace metal;

kernel void test_gradient(
    texture2d<float, access::write> output [[texture(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint width = output.get_width();
    uint height = output.get_height();

    if (gid.x >= width || gid.y >= height) {
        return;
    }

    // 归一化坐标 [0, 1]
    float u = float(gid.x) / float(width);
    float v = float(gid.y) / float(height);

    // 渐变颜色：左下蓝色 → 右上白色
    float3 color = float3(u, v, 0.5f);

    output.write(float4(color, 1.0f), gid);
}
```

#### 1.3.5 CMakeLists.txt (Metal 着色器编译)
```cmake
# 注意：Swift 项目使用 Swift Package Manager，不需要 CMake
# 但需要在 Package.swift 中配置 Metal 着色器编译
# 参考 Package.swift 配置
```

**验收标准**:
- ✅ MetalContext 初始化成功
- ✅ 编译测试着色器成功
- ✅ 渲染简单渐变到纹理
- ✅ 保存为 PNG 图片

---

### Task 1.4: 简单几何与材质 (Day 6-7)

**目标**: 实现球体和 Lambertian 材质，渲染第一个场景

**参考文件**:
- `~/ray_tracing/include/geometry/sphere.h`
- `~/ray_tracing/include/materials/material.h`
- `~/ray_tracing/shaders/common.metal` (球体相交函数)

**具体步骤**:

#### 1.4.1 Sphere.swift (CPU 端)
```swift
// Sources/Geometry/Sphere.swift
import simd

struct Sphere {
    var center: Point3
    var radius: Float
    var materialIndex: UInt32  // 材质索引

    init(center: Point3, radius: Float, materialIndex: UInt32 = 0) {
        self.center = center
        self.radius = radius
        self.materialIndex = materialIndex
    }
}
```

#### 1.4.2 Material.swift (CPU 端)
```swift
// Sources/Materials/Material.swift
import simd

enum MaterialType: UInt32 {
    case lambertian = 0
    case metal = 1
    case dielectric = 2
    case diffuseLight = 3
}

struct Material {
    var type: MaterialType
    var albedo: Color
    var fuzz: Float         // Metal 材质用
    var refractionIndex: Float  // Dielectric 材质用

    static func lambertian(albedo: Color) -> Material {
        return Material(type: .lambertian, albedo: albedo, fuzz: 0, refractionIndex: 1.0)
    }
}
```

#### 1.4.3 GPUStructs.swift (GPU 数据结构)
```swift
// Sources/GPU/GPUStructs.swift
import simd

// GPU 球体（32 bytes 对齐）
struct GPUSphere {
    var center: SIMD3<Float>    // 12 bytes
    var radius: Float           // 4 bytes
    var materialIndex: UInt32   // 4 bytes
    var padding: SIMD3<Float>   // 12 bytes
}

// GPU 材质（32 bytes 对齐）
struct GPUMaterial {
    var type: UInt32            // 4 bytes (MaterialType)
    var padding1: SIMD3<UInt32> // 12 bytes
    var albedo: SIMD3<Float>    // 12 bytes
    var fuzz: Float             // 4 bytes
    var refractionIndex: Float  // 4 bytes
    var padding2: SIMD2<Float>  // 8 bytes
}

// GPU 相机参数
struct GPUCameraParams {
    var origin: SIMD3<Float>
    var lowerLeftCorner: SIMD3<Float>
    var horizontal: SIMD3<Float>
    var vertical: SIMD3<Float>
}
```

#### 1.4.4 Shaders/Common/Geometry.metal
```metal
// Shaders/Common/Geometry.metal
#ifndef GEOMETRY_METAL
#define GEOMETRY_METAL

#include <metal_stdlib>
#include "Types.metal"
using namespace metal;

// GPU 球体结构（与 Swift 端对齐）
struct GPUSphere {
    float3 center;
    float radius;
    uint material_index;
    float3 padding;
};

// 光线-球体相交测试
struct HitRecord {
    float3 p;           // 交点位置
    float3 normal;      // 法线
    float t;            // 光线参数
    bool front_face;    // 是否正面
    uint material_index; // 材质索引
};

inline bool sphere_hit(
    GPUSphere sphere,
    Ray r,
    float t_min,
    float t_max,
    thread HitRecord* rec
) {
    float3 oc = r.origin - sphere.center;
    float a = dot(r.direction, r.direction);
    float half_b = dot(oc, r.direction);
    float c = dot(oc, oc) - sphere.radius * sphere.radius;

    float discriminant = half_b * half_b - a * c;
    if (discriminant < 0.0f) {
        return false;
    }

    float sqrtd = sqrt(discriminant);

    // 找最近的根
    float root = (-half_b - sqrtd) / a;
    if (root < t_min || t_max < root) {
        root = (-half_b + sqrtd) / a;
        if (root < t_min || t_max < root) {
            return false;
        }
    }

    rec->t = root;
    rec->p = ray_at(r, rec->t);
    float3 outward_normal = (rec->p - sphere.center) / sphere.radius;

    // 设置法线方向
    rec->front_face = dot(r.direction, outward_normal) < 0.0f;
    rec->normal = rec->front_face ? outward_normal : -outward_normal;
    rec->material_index = sphere.material_index;

    return true;
}

#endif // GEOMETRY_METAL
```

#### 1.4.5 Shaders/Common/Materials.metal
```metal
// Shaders/Common/Materials.metal
#ifndef MATERIALS_METAL
#define MATERIALS_METAL

#include <metal_stdlib>
#include "Types.metal"
#include "Random.metal"
using namespace metal;

// GPU 材质结构
struct GPUMaterial {
    uint type;
    uint3 padding1;
    float3 albedo;
    float fuzz;
    float refraction_index;
    float2 padding2;
};

enum MaterialType : uint {
    MaterialLambertian = 0,
    MaterialMetal = 1,
    MaterialDielectric = 2,
    MaterialDiffuseLight = 3
};

// Lambertian 散射
inline bool lambertian_scatter(
    GPUMaterial mat,
    Ray r_in,
    HitRecord rec,
    thread float3* attenuation,
    thread Ray* scattered,
    thread RandomState* rng
) {
    float3 scatter_direction = rec.normal + random_unit_vector(rng);

    // 处理退化情况
    if (length(scatter_direction) < 1e-8f) {
        scatter_direction = rec.normal;
    }

    *scattered = Ray{rec.p, normalize(scatter_direction), r_in.time};
    *attenuation = mat.albedo;
    return true;
}

// 材质散射总入口
inline bool material_scatter(
    device const GPUMaterial* materials,
    uint material_index,
    Ray r_in,
    HitRecord rec,
    thread float3* attenuation,
    thread Ray* scattered,
    thread RandomState* rng
) {
    GPUMaterial mat = materials[material_index];

    switch (mat.type) {
        case MaterialLambertian:
            return lambertian_scatter(mat, r_in, rec, attenuation, scattered, rng);
        default:
            return false;
    }
}

#endif // MATERIALS_METAL
```

#### 1.4.6 Shaders/Kernels/SimpleRayTracing.metal
```metal
// Shaders/Kernels/SimpleRayTracing.metal
// 简单路径追踪内核

#include <metal_stdlib>
#include "../Common/Types.metal"
#include "../Common/Random.metal"
#include "../Common/Geometry.metal"
#include "../Common/Materials.metal"
using namespace metal;

// 背景颜色（天空渐变）
inline float3 background_color(Ray r) {
    float3 unit_direction = normalize(r.direction);
    float t = 0.5f * (unit_direction.y + 1.0f);
    return (1.0f - t) * float3(1.0f, 1.0f, 1.0f) + t * float3(0.5f, 0.7f, 1.0f);
}

// 光线颜色计算
inline float3 ray_color(
    Ray r,
    device const GPUSphere* spheres,
    uint sphere_count,
    device const GPUMaterial* materials,
    uint max_depth,
    thread RandomState* rng
) {
    Ray current_ray = r;
    float3 accumulated_color = float3(1.0f);

    for (uint depth = 0; depth < max_depth; depth++) {
        HitRecord rec;
        bool hit_anything = false;
        float closest_so_far = 1e10f;

        // 测试所有球体
        for (uint i = 0; i < sphere_count; i++) {
            if (sphere_hit(spheres[i], current_ray, 0.001f, closest_so_far, &rec)) {
                hit_anything = true;
                closest_so_far = rec.t;
            }
        }

        if (hit_anything) {
            // 材质散射
            float3 attenuation;
            Ray scattered;
            if (material_scatter(materials, rec.material_index, current_ray, rec,
                               &attenuation, &scattered, rng)) {
                accumulated_color *= attenuation;
                current_ray = scattered;
            } else {
                return float3(0.0f);
            }
        } else {
            // 击中天空
            accumulated_color *= background_color(current_ray);
            return accumulated_color;
        }
    }

    // 超过最大深度，返回黑色
    return float3(0.0f);
}

// 主内核
kernel void simple_raytrace(
    texture2d<float, access::write> output [[texture(0)]],
    device const GPUSphere* spheres [[buffer(0)]],
    device const GPUMaterial* materials [[buffer(1)]],
    constant CameraParams& camera [[buffer(2)]],
    constant RenderParams& params [[buffer(3)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= params.width || gid.y >= params.height) {
        return;
    }

    // 初始化随机数
    uint seed = gid.x + gid.y * params.width + 12345u;
    RandomState rng = random_init(seed);

    float3 pixel_color = float3(0.0f);

    // 多重采样
    for (uint s = 0; s < params.samples_per_pixel; s++) {
        // 计算光线方向（带抗锯齿抖动）
        float u = (float(gid.x) + random_float(&rng)) / float(params.width);
        float v = (float(gid.y) + random_float(&rng)) / float(params.height);

        Ray r;
        r.origin = camera.origin;
        r.direction = normalize(camera.lower_left_corner + u * camera.horizontal + v * camera.vertical - camera.origin);
        r.time = 0.0f;

        // 累积颜色
        pixel_color += ray_color(r, spheres, 3, materials, params.max_depth, &rng);
    }

    // 平均
    pixel_color /= float(params.samples_per_pixel);

    output.write(float4(pixel_color, 1.0f), gid);
}
```

#### 1.4.7 测试程序 (main.swift)
```swift
// Sources/Main/main.swift
import Foundation
import Metal
import MetalKit

// 创建简单场景：3 个球体
func createSimpleScene() -> ([Sphere], [Material]) {
    let spheres = [
        Sphere(center: SIMD3<Float>(0, 0, -1), radius: 0.5, materialIndex: 0),      // 中心球
        Sphere(center: SIMD3<Float>(0, -100.5, -1), radius: 100, materialIndex: 1), // 地面
        Sphere(center: SIMD3<Float>(1, 0, -1), radius: 0.5, materialIndex: 2)       // 右侧球
    ]

    let materials = [
        Material.lambertian(albedo: SIMD3<Float>(0.7, 0.3, 0.3)),  // 红色
        Material.lambertian(albedo: SIMD3<Float>(0.8, 0.8, 0.0)),  // 黄色地面
        Material.lambertian(albedo: SIMD3<Float>(0.3, 0.3, 0.7))   // 蓝色
    ]

    return (spheres, materials)
}

// 主函数
func main() {
    print("=== Ray Tracing GPU - Phase 1 Test ===\n")

    // 1. 初始化 Metal
    guard let context = MetalContext() else {
        print("Failed to initialize Metal")
        return
    }

    // 2. 加载着色器库
    guard let library = context.device.makeDefaultLibrary() else {
        print("Failed to create shader library")
        return
    }

    // 3. 创建计算管线
    guard let pipeline = context.makeComputePipeline(functionName: "simple_raytrace", library: library) else {
        return
    }

    // 4. 创建场景
    let (spheres, materials) = createSimpleScene()

    // 5. 转换为 GPU 数据
    let gpuSpheres = spheres.map { sphere in
        GPUSphere(center: sphere.center, radius: sphere.radius,
                 materialIndex: sphere.materialIndex, padding: .zero)
    }

    let gpuMaterials = materials.map { mat in
        GPUMaterial(type: mat.type.rawValue, padding1: .zero,
                   albedo: mat.albedo, fuzz: mat.fuzz,
                   refractionIndex: mat.refractionIndex, padding2: .zero)
    }

    // 6. 创建缓冲区
    guard let sphereBuffer = context.makeBuffer(array: gpuSpheres),
          let materialBuffer = context.makeBuffer(array: gpuMaterials) else {
        print("Failed to create buffers")
        return
    }

    // 7. 设置相机
    let camera = GPUCameraParams(
        origin: SIMD3<Float>(0, 0, 0),
        lowerLeftCorner: SIMD3<Float>(-2, -1, -1),
        horizontal: SIMD3<Float>(4, 0, 0),
        vertical: SIMD3<Float>(0, 2, 0)
    )

    // 8. 渲染参数
    let width = 800
    let height = 600
    let params = RenderParams(width: UInt32(width), height: UInt32(height),
                             samplesPerPixel: 10, maxDepth: 50)

    // 9. 创建输出纹理
    guard let outputTexture = context.makeTexture(width: width, height: height) else {
        print("Failed to create texture")
        return
    }

    // 10. 执行渲染
    // TODO: 实现 GPU dispatch 和结果保存

    print("\n✅ Phase 1 完成！")
}

main()
```

**验收标准**:
- ✅ 渲染 3 个 Lambertian 球体
- ✅ 天空背景渐变正确
- ✅ 输出 PNG 图片 (800×600)
- ✅ 性能: < 100 ms @ 10 spp

---

## 里程碑验收

**Phase 1 完成标准**:
- ✅ Swift Package 项目结构完整
- ✅ 核心数学库实现（Vec3, Ray, Color, Interval）
- ✅ Metal 上下文管理正常
- ✅ 简单着色器编译成功
- ✅ 渲染单个 Lambertian 球体
- ✅ 输出 PNG 图片
- ✅ 性能达标 (< 100 ms @ 800×600 @ 10 spp)

**下一步**: Phase 2 - 完整材质与几何

---

**更新日志**:
- 2025-11-26: 创建 Phase 1 任务文档
