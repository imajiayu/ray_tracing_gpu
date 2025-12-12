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

// ========== 蓝噪声采样（R2 低差异序列）==========

/// R2 低差异序列（基于黄金比例）
/// 参考：http://extremelearning.com.au/unreasonable-effectiveness-of-quasirandom-sequences/
///
/// 特点：
/// - 点分布极其均匀，避免聚集
/// - 无需预生成纹理或查找表
/// - 计算开销极低（2 个乘法 + 1 个 fract）
/// - 质量优于伪随机，接近 Sobol 序列
///
/// @param n 序列索引（0, 1, 2, ...）
/// @return 2D 点 [0, 1) × [0, 1)，均匀分布
inline float2 r2_sequence(uint n) {
    // 黄金比例 φ = 1.618033988749895
    // α₁ = 1/φ ≈ 0.618033988749895
    // α₂ = 1/φ² ≈ 0.381966011250105
    const float g = 1.6180339887498948482;  // Golden ratio
    const float a1 = 1.0 / g;
    const float a2 = 1.0 / (g * g);

    // R2 序列公式：(n·α₁ mod 1, n·α₂ mod 1)
    return fract(float2(float(n) * a1, float(n) * a2));
}

/// 蓝噪声采样（带抖动的 R2 序列）
///
/// 在 R2 序列基础上添加少量抖动，避免固定模式
/// 抖动使用 PCG 哈希保证每个像素不同
///
/// @param n 序列索引
/// @param pixel_seed 像素种子（确保不同像素有不同抖动）
/// @return 2D 点 [0, 1) × [0, 1)
inline float2 blue_noise_sample(uint n, uint pixel_seed) {
    float2 base = r2_sequence(n);

    // 使用 PCG 哈希生成小抖动（± 0.01）
    // 这样既保留 R2 的均匀性，又避免固定模式的artifacts
    uint hash = pcg_hash(pixel_seed + n);
    float jitter_x = (float(hash & 0xFFFFu) / 65535.0f - 0.5f) * 0.02f;
    float jitter_y = (float((hash >> 16u) & 0xFFFFu) / 65535.0f - 0.5f) * 0.02f;

    return fract(base + float2(jitter_x, jitter_y));
}

#endif // RANDOM_METAL
