// Transform.metal
// 几何体变换（平移和旋转）

#ifndef TRANSFORM_METAL
#define TRANSFORM_METAL

#include <metal_stdlib>
#include "Types.metal"
using namespace metal;

// ========== 变换辅助函数 ==========

/// 应用旋转矩阵到向量
inline float3 apply_rotation(GPUTransform t, float3 v) {
    if (t.has_rotation == 0) {
        return v;
    }

    // 使用旋转矩阵的3行与向量做点积
    return float3(
        dot(t.rotation_row0, v),
        dot(t.rotation_row1, v),
        dot(t.rotation_row2, v)
    );
}

/// 应用旋转矩阵的转置到向量（逆旋转）
inline float3 apply_rotation_inverse(GPUTransform t, float3 v) {
    if (t.has_rotation == 0) {
        return v;
    }

    // 旋转矩阵的转置（对于正交矩阵，转置=逆）
    // 将行变为列
    return float3(
        t.rotation_row0.x * v.x + t.rotation_row1.x * v.y + t.rotation_row2.x * v.z,
        t.rotation_row0.y * v.x + t.rotation_row1.y * v.y + t.rotation_row2.y * v.z,
        t.rotation_row0.z * v.x + t.rotation_row1.z * v.y + t.rotation_row2.z * v.z
    );
}

/// 将光线变换到物体空间（逆变换）
/// 与CPU版本的逻辑相同：将光线从世界空间变换到物体空间
inline Ray transform_ray_to_object_space(GPUTransform t, Ray r) {
    // 1. 先减去平移（逆平移）
    float3 origin = r.origin - t.translation;

    // 2. 再应用逆旋转
    origin = apply_rotation_inverse(t, origin);
    float3 direction = apply_rotation_inverse(t, r.direction);

    return Ray{origin, direction, r.time};
}

/// 将点从物体空间变换到世界空间（正变换）
inline float3 transform_point_to_world_space(GPUTransform t, float3 p) {
    // 1. 先旋转
    float3 result = apply_rotation(t, p);

    // 2. 再平移
    result += t.translation;

    return result;
}

/// 将法线从物体空间变换到世界空间
/// 注意：法线需要用逆转置矩阵变换，但对于正交旋转矩阵，逆转置=原矩阵
inline float3 transform_normal_to_world_space(GPUTransform t, float3 n) {
    // 对于正交旋转矩阵，法线直接用旋转矩阵变换
    return apply_rotation(t, n);
}

#endif // TRANSFORM_METAL
