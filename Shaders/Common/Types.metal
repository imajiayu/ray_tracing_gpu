// Types.metal
// GPU 数据结构定义（与 Swift 端对齐）

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

/// 光线在参数 t 处的位置
inline float3 ray_at(Ray r, float t) {
    return r.origin + t * r.direction;
}

// ========== 变换 ==========

/// GPU 变换（64 bytes，与 Swift GPUTransform 对齐）
struct GPUTransform {
    float3 translation;         // 12 bytes
    uint has_rotation;          // 4 bytes (0 = no rotation, 1 = has rotation)
    float3 rotation_row0;       // 12 bytes (旋转矩阵第1行)
    float padding0;             // 4 bytes
    float3 rotation_row1;       // 12 bytes (旋转矩阵第2行)
    float padding1;             // 4 bytes
    float3 rotation_row2;       // 12 bytes (旋转矩阵第3行)
    float padding2;             // 4 bytes
};  // Total: 64 bytes

// ========== 几何体 ==========

/// GPU 球体（支持变换和体积雾，32 bytes）
struct GPUSphere {
    float3 center;              // 12 bytes
    float radius;               // 4 bytes
    uint material_index;        // 4 bytes
    int transform_index;        // 4 bytes (-1 = 无变换)
    float neg_inv_density;      // 4 bytes (体积雾: -1/density, 0 = 非体积)
    uint isotropic_mat_index;   // 4 bytes (体积雾材质索引, 0xFFFFFFFF = 无)
};  // Total: 32 bytes

/// GPU Quad 四边形（支持变换，112 bytes）
struct GPUQuad {
    float3 corner;              // 12 bytes
    float padding1;             // 4 bytes
    float3 side_A;              // 12 bytes
    float padding2;             // 4 bytes
    float3 side_B;              // 12 bytes
    float padding3;             // 4 bytes
    float3 normal;              // 12 bytes
    float D;                    // 4 bytes
    float3 w;                   // 12 bytes
    uint material_index;        // 4 bytes
    int transform_index;        // 4 bytes (-1 = 无变换)
    float2 padding4;            // 8 bytes
};  // Total: 96 bytes -> 112 bytes (16-byte aligned)

// ========== 纹理 ==========

enum TextureType : uint {
    TextureSolidColor = 0,
    TextureChecker = 1,
    TextureImage = 2,
    TextureNoise = 3
};

/// GPU 纹理（与 Swift GPUTexture 对齐）
struct GPUTexture {
    uint type;                  // 4 bytes
    uint3 padding1;             // 12 bytes
    float3 albedo;              // 12 bytes (solid color / even color)
    float inv_scale;            // 4 bytes (checker texture)
    float scale;                // 4 bytes (noise texture)
    float3 odd_color;           // 12 bytes (checker texture odd color)
    int image_index;            // 4 bytes (image texture index, -1 = no image)
    float3 padding2;            // 12 bytes
};  // Total: 64 bytes

// ========== 材质 ==========

enum MaterialType : uint {
    MaterialLambertian = 0,
    MaterialMetal = 1,
    MaterialDielectric = 2,
    MaterialDiffuseLight = 3,
    MaterialIsotropic = 4
};

/// GPU 材质（与 Swift GPUMaterial 对齐）
struct GPUMaterial {
    uint type;                  // 4 bytes
    uint3 padding1;             // 12 bytes
    float3 albedo;              // 12 bytes (仅用于非纹理材质)
    float fuzz;                 // 4 bytes
    float refraction_index;     // 4 bytes
    int texture_index;          // 4 bytes (-1 表示无纹理)
    float2 padding2;            // 8 bytes
    float3 emission;            // 12 bytes (发光材质)
    float padding3;             // 4 bytes
};  // Total: 64 bytes

// ========== 相机 ==========

struct CameraParams {
    float3 origin;
    float3 lower_left_corner;
    float3 horizontal;
    float3 vertical;
    float3 defocus_disk_u;  // 景深盘 U 向量
    float3 defocus_disk_v;  // 景深盘 V 向量
    float defocus_angle;    // 散焦角度
    float3 padding;         // 对齐填充
};

// ========== 渲染参数 ==========

struct RenderParams {
    uint width;
    uint height;
    uint samples_per_pixel;
    uint max_depth;
    uint sphere_count;
    uint quad_count;
    uint use_background;  // 0 = black, 1 = sky gradient
    uint sample_offset;   // 当前batch的样本偏移量
    uint use_bvh;         // 0 = 禁用 BVH, 1 = 启用 BVH
    uint bvh_node_count;  // BVH 节点数量
    uint lights_count;    // 光源数量（用于 MIS）
    uint use_mis;         // 0 = 禁用 MIS, 1 = 启用 MIS
    uint sqrt_spp;        // sqrt(samples_per_pixel) - 分层采样网格大小
    uint filter_type;     // 像素重建滤波器类型 (0=box, 1=tent, 2=gaussian, 3=mitchell, 4=lanczos)
    uint use_blue_noise;  // 0 = 伪随机采样, 1 = 蓝噪声采样（R2 序列）
    float recip_sqrt_spp; // 1.0 / sqrt_spp - 避免 GPU 除法
    float2 padding2;      // 对齐填充（16字节对齐）
};

// 滤波器类型枚举
enum FilterType : uint {
    FILTER_BOX = 0,
    FILTER_TENT = 1,
    FILTER_GAUSSIAN = 2,
    FILTER_MITCHELL = 3,
    FILTER_LANCZOS = 4
};

// ========== 自适应采样 ==========

/// 自适应采样参数（64 bytes 对齐）
struct AdaptiveSamplingParams {
    uint min_samples;               // 最小采样数（如 16）
    uint target_spp;                // 目标总采样数（用户设置的 --spp）
    float variance_threshold;       // 方差阈值（如 0.0001）
    uint adaptive_batch_size;       // 每批次增量（如 8）
    uint width;                     // 图像宽度
    uint height;                    // 图像高度
    uint current_pass;              // 当前采样轮次
    float adaptive_relative_threshold;  // 相对误差阈值（如 0.01 = 1%）
    uint64_t total_budget;          // 总采样预算 = width × height × target_spp
    uint64_t used_budget;           // 已使用的采样数
};  // Total: 64 bytes

/// 全局统计数据（32 bytes）
struct AdaptiveGlobalStats {
    uint total_converged_pixels;    // 已收敛像素数
    uint padding1;                  // 对齐
    uint64_t total_samples_used;    // 总采样数（需要 Metal 3.0+）
    float average_variance;         // 平均方差
    float max_variance;             // 最大方差
    float2 padding2;                // 对齐到 32 bytes
};  // Total: 32 bytes

// ========== AOV (Arbitrary Output Variables) ==========

/// AOV通道枚举
enum AOVChannel : uint {
    // 渲染AOV（用于自适应采样方差计算）
    AOV_BEAUTY = 0,         // 最终合成图像（所有通道之和）
    AOV_DIFFUSE = 1,        // Lambertian 漫反射
    AOV_SPECULAR = 2,       // Metal 镜面反射
    AOV_TRANSMISSION = 3,   // Dielectric 透射/折射
    AOV_VOLUME = 4,         // Isotropic 体积散射
    AOV_EMISSION = 5,       // DiffuseLight 自发光

    // 辅助AOV（用于降噪）
    AOV_ALBEDO = 6,         // 表面反照率（首次bounce）
    AOV_NORMAL = 7,         // 表面法线（首次bounce）
    AOV_DEPTH = 8,          // 深度（首次相交距离）

    // 调试AOV
    AOV_SAMPLE_COUNT = 9,   // 每像素采样数（存储在单独的buffer）

    AOV_COUNT = 10          // 总通道数
};

/// AOV输出结构（用于路径追踪kernel的单次采样）
/// 实际存储在多个texture中以减少带宽
struct AOVOutput {
    // Beauty channel (最终合成图像)
    float3 beauty;          // diffuse + specular + transmission + volume + emission

    // 分解通道（用于自适应采样的精确方差计算）
    float3 diffuse;         // Lambertian贡献
    float3 specular;        // Metal贡献
    float3 transmission;    // Dielectric贡献
    float3 volume;          // Isotropic贡献
    float3 emission;        // 自发光

    // 辅助通道（用于降噪）
    float3 albedo;          // 首次bounce的材质反照率
    float3 normal;          // 首次bounce的表面法线
    float depth;            // 首次相交的深度值
};

#endif // TYPES_METAL
