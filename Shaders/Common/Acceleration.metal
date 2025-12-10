// Acceleration.metal
// BVH 加速结构相关函数

#ifndef ACCELERATION_METAL
#define ACCELERATION_METAL

#include "Types.metal"

// MARK: - GPU AABB

/// GPU AABB（32 bytes，使用 float4 避免对齐问题）
struct GPUAABB {
    float4 minx_miny_minz_pad1;  // 16 bytes (min.xyz, padding)
    float4 maxx_maxy_maxz_pad2;  // 16 bytes (max.xyz, padding)
};  // Total: 32 bytes

/// 光线-AABB 相交测试（优化版）
/// 参考：Amy Williams et al. "An Efficient and Robust Ray–Box Intersection Algorithm"
inline bool aabb_hit(
    GPUAABB box,
    Ray r,
    float t_min,
    float t_max
) {
    // 提取 min 和 max（前3个分量）
    float3 box_min = box.minx_miny_minz_pad1.xyz;
    float3 box_max = box.maxx_maxy_maxz_pad2.xyz;

    // 使用倒数避免除法（Metal 会自动优化）
    float3 inv_dir = 1.0f / r.direction;

    // 对每个轴计算交点参数
    float3 t0 = (box_min - r.origin) * inv_dir;
    float3 t1 = (box_max - r.origin) * inv_dir;

    // 处理负方向（无分支）
    float3 tmin = min(t0, t1);
    float3 tmax = max(t0, t1);

    // 找到所有轴的交集
    float t_enter = max(max(tmin.x, tmin.y), max(tmin.z, t_min));
    float t_exit = min(min(tmax.x, tmax.y), min(tmax.z, t_max));

    // 检查是否有效相交
    return t_enter <= t_exit;
}

// MARK: - GPU BVH 节点

/// GPU BVH 节点（与 Swift 对齐）
struct GPUBVHNode {
    GPUAABB bbox;
    uint left_child_or_first;
    uint right_child;
    uint geometry_count;
    uint split_axis;  // 分割轴: 0=X, 1=Y, 2=Z
};

// MARK: - BVH 遍历（迭代式，固定栈）

/// BVH 遍历（迭代式，无递归）
/// 参考 CPU 版本的 flat_bvh.h，采用近端优先遍历
inline bool bvh_hit(
    device const GPUBVHNode* nodes,
    device const uint* geometry_indices,
    device const GPUSphere* spheres,
    device const GPUQuad* quads,
    device const GPUTransform* transforms,
    uint sphere_count,
    Ray r,
    float t_min,
    float t_max,
    thread HitRecord* rec,
    thread RandomState* rng
) {
    const int MAX_STACK_SIZE = 64;
    const int MAX_ITERATIONS = 1000;  // 防止无限循环
    uint stack[MAX_STACK_SIZE];
    int stack_ptr = 0;

    stack[stack_ptr++] = 0;  // 从根节点开始

    bool hit_anything = false;
    float closest_so_far = t_max;

    // 预计算光线方向符号（避免循环内分支）
    bool dir_is_neg[3] = {
        r.direction.x < 0.0f,
        r.direction.y < 0.0f,
        r.direction.z < 0.0f
    };

    int iteration_count = 0;
    while (stack_ptr > 0 && iteration_count < MAX_ITERATIONS) {
        iteration_count++;

        uint node_idx = stack[--stack_ptr];
        GPUBVHNode node = nodes[node_idx];

        // AABB 快速拒绝（注意：使用 closest_so_far 而不是固定的 t_max）
        if (!aabb_hit(node.bbox, r, t_min, closest_so_far)) {
            continue;
        }

        if (node.geometry_count > 0) {
            // 叶节点：测试所有几何体
            for (uint i = 0; i < node.geometry_count; i++) {
                uint geom_idx = geometry_indices[node.left_child_or_first + i];

                HitRecord temp_rec;
                bool hit = false;

                if (geom_idx < sphere_count) {
                    // Sphere (支持体积雾)
                    hit = sphere_hit_constant_medium(spheres[geom_idx], transforms, r, t_min, closest_so_far, &temp_rec, rng);
                } else {
                    // Quad
                    uint quad_idx = geom_idx - sphere_count;
                    hit = quad_hit(quads[quad_idx], transforms, r, t_min, closest_so_far, &temp_rec);
                }

                if (hit) {
                    hit_anything = true;
                    closest_so_far = temp_rec.t;
                    *rec = temp_rec;
                }
            }
        } else {
            // 内部节点：近端优先遍历
            uint left_idx = node.left_child_or_first;
            uint right_idx = node.right_child;

            // 使用存储的分割轴
            int axis = int(node.split_axis);

            // 根据光线方向确定遍历顺序（近端优先）
            uint first = dir_is_neg[axis] ? right_idx : left_idx;
            uint second = dir_is_neg[axis] ? left_idx : right_idx;

            // 栈溢出检查（确保有足够空间存放两个子节点）
            if (stack_ptr + 2 <= MAX_STACK_SIZE) {
                // 远端子节点先入栈（后访问），近端后入栈（先访问）
                stack[stack_ptr++] = second;
                stack[stack_ptr++] = first;
            }
            // 注意：如果栈溢出，我们跳过这些子节点（可能漏掉某些相交）
            // 这是一个保守的做法，避免崩溃。正确的解决方案是使用更大的栈或动态栈。
        }
    }

    return hit_anything;
}

#endif // ACCELERATION_METAL
