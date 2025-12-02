// Acceleration.metal
// BVH 加速结构相关函数

#ifndef ACCELERATION_METAL
#define ACCELERATION_METAL

#include "Types.metal"

// MARK: - GPU AABB

/// GPU AABB（与 Swift 对齐）
struct GPUAABB {
    float3 min;
    float padding1;
    float3 max;
    float padding2;
};

/// 光线-AABB 相交测试（优化版）
/// 参考：Amy Williams et al. "An Efficient and Robust Ray–Box Intersection Algorithm"
inline bool aabb_hit(
    GPUAABB box,
    Ray r,
    float t_min,
    float t_max
) {
    // 使用倒数避免除法（Metal 会自动优化）
    float3 inv_dir = 1.0f / r.direction;

    // 对每个轴计算交点参数
    float3 t0 = (box.min - r.origin) * inv_dir;
    float3 t1 = (box.max - r.origin) * inv_dir;

    // 处理负方向（无分支）
    float3 tmin = min(t0, t1);
    float3 tmax = max(t0, t1);

    // 找到所有轴的交集
    float t_enter = max(max(tmin.x, tmin.y), max(tmin.z, t_min));
    float t_exit = min(min(tmax.x, tmax.y), min(tmax.z, t_max));

    // 检查是否有效相交
    return t_enter < t_exit;
}

// MARK: - GPU BVH 节点

/// GPU BVH 节点（与 Swift 对齐）
struct GPUBVHNode {
    GPUAABB bbox;
    uint left_child_or_first;
    uint right_child;
    uint geometry_count;
    uint padding;
};

#endif // ACCELERATION_METAL
