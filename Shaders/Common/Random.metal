// Random.metal
// PCG 随机数生成器（GPU 版本）

#ifndef RANDOM_METAL
#define RANDOM_METAL

#include <metal_stdlib>
using namespace metal;

// ========== PCG 随机数状态 ==========

struct RandomState {
    uint state;
};

// ========== 初始化 ==========

/// 初始化随机数种子
inline RandomState random_init(uint seed) {
    RandomState rng;
    rng.state = seed;
    return rng;
}

// ========== 基础随机数生成 ==========

/// 生成随机 uint32 (PCG 算法)
inline uint random_uint(thread RandomState* rng) {
    uint oldstate = rng->state;
    rng->state = oldstate * 747796405u + 2891336453u;
    uint word = ((oldstate >> ((oldstate >> 28u) + 4u)) ^ oldstate) * 277803737u;
    return (word >> 22u) ^ word;
}

/// 生成 [0, 1) 随机浮点数
inline float random_float(thread RandomState* rng) {
    return float(random_uint(rng)) / 4294967296.0f;
}

/// 生成 [min, max) 随机浮点数
inline float random_float_range(thread RandomState* rng, float min_val, float max_val) {
    return min_val + (max_val - min_val) * random_float(rng);
}

// ========== 向量随机数 ==========

/// 生成随机 float3 [0, 1)
inline float3 random_vec3(thread RandomState* rng) {
    return float3(random_float(rng), random_float(rng), random_float(rng));
}

/// 生成随机 float3 [min, max)
inline float3 random_vec3_range(thread RandomState* rng, float min_val, float max_val) {
    return float3(
        random_float_range(rng, min_val, max_val),
        random_float_range(rng, min_val, max_val),
        random_float_range(rng, min_val, max_val)
    );
}

// ========== 高级采样 ==========

/// 生成随机单位向量（均匀分布在单位球面上）
/// 使用 rejection sampling（更高质量的分布）
inline float3 random_unit_vector(thread RandomState* rng) {
    // Rejection sampling in unit sphere
    while (true) {
        float3 p = random_vec3_range(rng, -1.0f, 1.0f);
        float lensq = dot(p, p);
        // 避免除零和长度过小的向量（提高阈值避免数值不稳定）
        if (1e-6f < lensq && lensq <= 1.0f) {
            return p / sqrt(lensq);
        }
    }
}

/// 生成半球上的随机向量
inline float3 random_on_hemisphere(thread RandomState* rng, float3 normal) {
    float3 on_unit_sphere = random_unit_vector(rng);
    if (dot(on_unit_sphere, normal) > 0.0f) {
        return on_unit_sphere;
    } else {
        return -on_unit_sphere;
    }
}

/// 生成单位圆盘上的随机点
/// 使用 rejection sampling
inline float3 random_in_unit_disk(thread RandomState* rng) {
    while (true) {
        float3 p = float3(
            random_float_range(rng, -1.0f, 1.0f),
            random_float_range(rng, -1.0f, 1.0f),
            0.0f
        );
        if (dot(p, p) < 1.0f) {
            return p;
        }
    }
}

// ========== PCG 哈希函数（无状态版本）==========

/// PCG 哈希（用于体积雾等需要单次哈希的场景）
inline uint pcg_hash(uint input) {
    uint state = input * 747796405u + 2891336453u;
    uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}

/// PCG 哈希转浮点数 [0, 1)
inline float pcg_hash_float(uint input) {
    return float(pcg_hash(input)) / 4294967296.0f;
}

#endif // RANDOM_METAL
