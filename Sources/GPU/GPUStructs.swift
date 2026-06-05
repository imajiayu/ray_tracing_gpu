// GPUStructs.swift
// GPU 数据结构定义（必须与 Metal 着色器对齐）

import simd

// MARK: - 变换

/// GPU 变换（64 bytes 对齐）
struct GPUTransform {
    var translation: SIMD3<Float>   // 12 bytes
    var hasRotation: UInt32         // 4 bytes (0 = no rotation, 1 = has rotation)
    var rotationRow0: SIMD3<Float>  // 12 bytes (旋转矩阵第1行)
    var padding0: Float             // 4 bytes
    var rotationRow1: SIMD3<Float>  // 12 bytes (旋转矩阵第2行)
    var padding1: Float             // 4 bytes
    var rotationRow2: SIMD3<Float>  // 12 bytes (旋转矩阵第3行)
    var padding2: Float             // 4 bytes
}  // Total: 64 bytes

// MARK: - 几何体

/// GPU 球体（48 bytes 对齐，支持变换和体积雾）
struct GPUSphere {
    var center: SIMD3<Float>    // 12 bytes
    var radius: Float           // 4 bytes
    var materialIndex: UInt32   // 4 bytes
    var transformIndex: Int32   // 4 bytes (-1 = 无变换)
    var negInvDensity: Float    // 4 bytes (体积雾: -1/density, 0 = 非体积)
    var isotropicMatIndex: UInt32 // 4 bytes (体积雾材质索引, 0xFFFFFFFF = 无)
}  // Total: 32 bytes + 8 bytes padding to 48 bytes

/// GPU Quad 四边形（支持变换）
struct GPUQuad {
    var corner: SIMD3<Float>    // 12 bytes
    var padding1: Float         // 4 bytes
    var sideA: SIMD3<Float>     // 12 bytes
    var padding2: Float         // 4 bytes
    var sideB: SIMD3<Float>     // 12 bytes
    var padding3: Float         // 4 bytes
    var normal: SIMD3<Float>    // 12 bytes
    var D: Float                // 4 bytes
    var w: SIMD3<Float>         // 12 bytes
    var materialIndex: UInt32   // 4 bytes
    var transformIndex: Int32   // 4 bytes (-1 = 无变换)
    var padding4: SIMD2<Float>  // 8 bytes
}  // Total: 96 bytes -> 112 bytes (16-byte aligned)

// MARK: - 纹理

/// GPU 纹理（48 bytes 对齐）
struct GPUTexture {
    var type: UInt32            // 4 bytes (TextureType)
    var padding1: SIMD3<UInt32> // 12 bytes
    var albedo: SIMD3<Float>    // 12 bytes (solid color / even color)
    var invScale: Float         // 4 bytes (checker texture)
    var scale: Float            // 4 bytes (noise texture)
    var oddColor: SIMD3<Float>  // 12 bytes (checker texture odd color)
    var imageIndex: Int32       // 4 bytes (image texture index, -1 = 无图片)
    var padding2: SIMD3<Float>  // 12 bytes
}  // Total: 64 bytes

// MARK: - 材质

/// GPU 材质（64 bytes 对齐，支持纹理）
struct GPUMaterial {
    var type: UInt32            // 4 bytes (MaterialType)
    var padding1: SIMD3<UInt32> // 12 bytes
    var albedo: SIMD3<Float>    // 12 bytes (仅用于非纹理材质)
    var fuzz: Float             // 4 bytes
    var refractionIndex: Float  // 4 bytes
    var textureIndex: Int32     // 4 bytes (-1 表示无纹理，否则为纹理索引)
    var padding2: SIMD2<Float>  // 8 bytes
    var emission: SIMD3<Float>  // 12 bytes (发光材质)
    var padding3: Float         // 4 bytes
}  // Total: 64 bytes

// MARK: - 相机

/// GPU 相机参数
struct GPUCameraParams {
    var origin: SIMD3<Float>
    var lowerLeftCorner: SIMD3<Float>
    var horizontal: SIMD3<Float>
    var vertical: SIMD3<Float>
    var defocusDiskU: SIMD3<Float>  // 景深盘 U 向量
    var defocusDiskV: SIMD3<Float>  // 景深盘 V 向量
    var defocusAngle: Float         // 散焦角度（用于判断是否启用景深）
    var padding: SIMD3<Float>       // 对齐填充
}

// MARK: - BVH 加速结构

/// GPU AABB（32 bytes，使用 SIMD4 避免对齐问题）
struct GPUAABB {
    var minx_miny_minz_pad1: SIMD4<Float>  // 16 bytes (min.xyz, padding)
    var maxx_maxy_maxz_pad2: SIMD4<Float>  // 16 bytes (max.xyz, padding)

    init(min: SIMD3<Float>, max: SIMD3<Float>) {
        self.minx_miny_minz_pad1 = SIMD4<Float>(min.x, min.y, min.z, 0)
        self.maxx_maxy_maxz_pad2 = SIMD4<Float>(max.x, max.y, max.z, 0)
    }
}  // Total: 32 bytes

/// GPU BVH 节点（48 bytes）
struct GPUBVHNode {
    var bbox: GPUAABB           // 32 bytes
    var leftChildOrFirst: UInt32  // 4 bytes (内部节点：左子节点索引；叶节点：首个几何体索引)
    var rightChild: UInt32      // 4 bytes (内部节点：右子节点索引；叶节点：unused)
    var geometryCount: UInt32   // 4 bytes (内部节点：0；叶节点：几何体数量)
    var splitAxis: UInt32       // 4 bytes (分割轴: 0=X, 1=Y, 2=Z)
}  // Total: 48 bytes

// MARK: - 光源管理

/// 光源类型
enum GPULightType: UInt32 {
    case quad = 0
    case sphere = 1
}

/// GPU 光源信息（16 bytes，对齐）
struct GPULightInfo {
    var type: UInt32           // 4 bytes - 光源类型（0=Quad, 1=Sphere）
    var geometryIndex: UInt32  // 4 bytes - 在对应几何数组中的索引
    var padding: SIMD2<Float>  // 8 bytes - 对齐到 16 bytes

    init(type: GPULightType, geometryIndex: UInt32) {
        self.type = type.rawValue
        self.geometryIndex = geometryIndex
        self.padding = SIMD2<Float>(0, 0)
    }
}  // Total: 16 bytes

// MARK: - 渲染参数

/// GPU 渲染参数
struct GPURenderParams {
    var width: UInt32
    var height: UInt32
    var samplesPerPixel: UInt32
    var maxDepth: UInt32
    var sphereCount: UInt32
    var quadCount: UInt32
    var useBackground: UInt32  // 0 = black, 1 = sky gradient
    var sampleOffset: UInt32   // 当前batch的样本偏移量
    var useBVH: UInt32  // 0 = 禁用 BVH, 1 = 启用 BVH
    var bvhNodeCount: UInt32  // BVH 节点数量
    var lightsCount: UInt32  // 光源数量（用于 MIS）
    var useMIS: UInt32  // 0 = 禁用 MIS, 1 = 启用 MIS
    var sqrtSpp: UInt32  // sqrt(samplesPerPixel) - 分层采样网格大小
    var filterType: UInt32  // 像素重建滤波器类型 (0=box, 1=tent, 2=gaussian, 3=mitchell, 4=lanczos)
    var useBlueNoise: UInt32  // 0 = 伪随机采样, 1 = 蓝噪声采样（R2 序列）
    var recipSqrtSpp: Float  // 1.0 / sqrtSpp - 避免 GPU 除法
    var padding2: SIMD2<Float>  // 对齐填充（16字节对齐）
}

// MARK: - 自适应采样

/// 自适应采样参数（64 bytes 对齐）
struct AdaptiveSamplingParams {
    var minSamples: UInt32          // 最小采样数（如 16）
    var targetSpp: UInt32           // 目标总采样数（用户设置的 --spp）
    var varianceThreshold: Float    // 方差阈值（如 0.0001）
    var adaptiveBatchSize: UInt32   // 每批次增量（如 8）
    var width: UInt32               // 图像宽度
    var height: UInt32              // 图像高度
    var currentPass: UInt32         // 当前采样轮次
    var adaptiveRelativeThreshold: Float  // 相对误差阈值（如 0.01 = 1%）
    var totalBudget: UInt64         // 总采样预算 = width × height × targetSpp
    var usedBudget: UInt64          // 已使用的采样数
}  // Total: 64 bytes

/// 全局统计数据（用于进度跟踪，32 bytes）
struct AdaptiveGlobalStats {
    var totalConvergedPixels: UInt32    // 已收敛像素数
    var padding1: UInt32                // 对齐
    var totalSamplesUsed: UInt64        // 总采样数
    var averageVariance: Float          // 平均方差
    var maxVariance: Float              // 最大方差
    var padding2: SIMD2<Float>          // 对齐到 32 bytes
}  // Total: 32 bytes
