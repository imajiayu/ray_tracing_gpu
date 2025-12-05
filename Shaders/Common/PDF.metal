// PDF.metal
// 概率密度函数 (Probability Density Function) 系统
// 用于多重重要性采样 (Multiple Importance Sampling, MIS)

#ifndef PDF_METAL
#define PDF_METAL

#include <metal_stdlib>
#include "Types.metal"
#include "Random.metal"
using namespace metal;

// ========== ONB (Orthonormal Basis) 正交基系统 ==========

/// 正交基结构 - 用于局部坐标系到世界坐标系的变换
/// 参考: ~/ray_tracing/include/sampling/onb.h
struct ONB {
    float3 u;  // 切线向量 (tangent)
    float3 v;  // 副法线 (bitangent)
    float3 w;  // 法线 (normal)
};

/// 从法线构建正交基
/// 参考 CPU 版本: onb::onb(const vec3& n)
inline ONB onb_build(float3 n) {
    ONB uvw;
    uvw.w = normalize(n);

    // 选择一个不平行于 w 的向量作为参考
    float3 a = (abs(uvw.w.x) > 0.9f) ? float3(0, 1, 0) : float3(1, 0, 0);

    // Gram-Schmidt 正交化
    uvw.v = normalize(cross(uvw.w, a));
    uvw.u = cross(uvw.w, uvw.v);

    return uvw;
}

/// 将局部坐标系向量变换到世界坐标系
/// 参考 CPU 版本: onb::transform(const vec3& v)
/// result = v.x * u + v.y * v + v.z * w
inline float3 onb_transform(ONB uvw, float3 v) {
    // Metal 编译器会自动 SIMD 优化这个运算
    return v.x * uvw.u + v.y * uvw.v + v.z * uvw.w;
}

// ========== MIS 辅助函数 ==========

/// Power Heuristic for Multiple Importance Sampling
/// Veach and Guibas 1995 - "Optimally Combining Sampling Techniques for Monte Carlo Rendering"
/// 公式: w_a = (pdf_a^beta) / (pdf_a^beta + pdf_b^beta)
/// 参数 beta=2 通常是最优的（平衡 variance 和 bias）
inline float power_heuristic(float pdf_a, float pdf_b, int beta = 2) {
    float a = pow(pdf_a, float(beta));
    float b = pow(pdf_b, float(beta));
    return a / fmax(a + b, 1e-6f);  // 防止除零
}

/// Balance Heuristic (beta=1 的特殊情况)
inline float balance_heuristic(float pdf_a, float pdf_b) {
    return pdf_a / fmax(pdf_a + pdf_b, 1e-6f);
}

// ========== 随机采样辅助函数 ==========

/// 在单位半球上生成余弦加权的随机方向
/// 参考: ~/ray_tracing/include/core/vec3_simd.h:random_cosine_direction()
inline float3 random_cosine_direction(thread RandomState* rng) {
    float r1 = random_float(rng);
    float r2 = random_float(rng);

    float phi = 2.0f * M_PI_F * r1;
    float sqrt_r2 = sqrt(r2);
    float sqrt_1_r2 = sqrt(1.0f - r2);

    // 局部坐标系中的方向 (z 轴为法线)
    float x = cos(phi) * sqrt_r2;
    float y = sin(phi) * sqrt_r2;
    float z = sqrt_1_r2;

    return float3(x, y, z);
}

// ========== PDF 类型枚举 ==========

enum PDFType : uint {
    PDF_COSINE = 0,      // 余弦加权半球采样 (Lambertian BRDF)
    PDF_HITTABLE = 1,    // 光源采样 (Next Event Estimation)
    PDF_MIXTURE = 2,     // 混合采样 (MIS)
    PDF_SPECULAR = 3     // 镜面反射采样 (Metal fuzz)
};

// ========== 统一 PDF 结构 ==========

/// 统一的 PDF 结构（32 字节对齐）
/// 使用 type 字段区分不同的 PDF 类型，避免虚函数
struct PDF {
    PDFType type;        // 4 bytes - PDF 类型
    float3 w;            // 12 bytes - ONB 的 w 轴（法线或反射方向）
    float fuzz;          // 4 bytes - specular_pdf 参数
    uint light_index;    // 4 bytes - hittable_pdf 光源索引
    uint padding[2];     // 8 bytes - 对齐到 32 字节
};

// ========== CosinePDF - 余弦加权半球采样 ==========

/// 计算余弦 PDF 的值
/// 参考 CPU 版本: cosine_pdf::value()
/// PDF = cos(θ) / π
inline float cosine_pdf_value(float3 w, float3 direction) {
    ONB uvw = onb_build(w);
    float cosine_theta = dot(normalize(direction), uvw.w);
    return fmax(0.0f, cosine_theta / M_PI_F);
}

/// 从余弦 PDF 生成采样方向
/// 参考 CPU 版本: cosine_pdf::generate()
inline float3 cosine_pdf_generate(float3 w, thread RandomState* rng) {
    ONB uvw = onb_build(w);
    return onb_transform(uvw, random_cosine_direction(rng));
}

// ========== HittablePDF - 光源采样 ==========

/// 球体光源随机方向采样
/// 参考: ~/ray_tracing/include/geometry/sphere.h:random()
inline float3 sphere_random_direction(
    GPUSphere sphere,
    float3 origin,
    thread RandomState* rng
) {
    // 向球体中心方向构建坐标系
    float3 direction = sphere.center - origin;

    ONB uvw = onb_build(direction);
    return onb_transform(uvw, random_unit_vector(rng));
}

/// 球体光源 PDF 值计算
/// 参考: ~/ray_tracing/include/geometry/sphere.h:pdf_value()
inline float sphere_pdf_value(
    GPUSphere sphere,
    float3 origin,
    float3 direction,
    device const GPUTransform* transforms
) {
    Ray r;
    r.origin = origin;
    r.direction = normalize(direction);
    r.time = 0.0f;

    HitRecord rec;
    if (!sphere_hit(sphere, transforms, r, 0.001f, 1e10f, &rec)) {
        return 0.0f;
    }

    // 计算立体角
    float distance_squared = rec.t * rec.t;
    float cosine = abs(dot(direction, rec.normal));

    // PDF = (distance² / (4π * radius²))，简化为基于立体角的公式
    // 这里使用更精确的基于面积的公式
    float radius = sphere.radius;
    float area = 4.0f * M_PI_F * radius * radius;

    return distance_squared / (cosine * area + 1e-10f);
}

/// 四边形光源随机方向采样
/// 参考: ~/ray_tracing/include/geometry/quad.h:random()
inline float3 quad_random_direction(
    GPUQuad quad,
    float3 origin,
    thread RandomState* rng
) {
    // 在四边形表面随机采样一点
    float r1 = random_float(rng);
    float r2 = random_float(rng);
    float3 p = quad.corner + r1 * quad.side_A + r2 * quad.side_B;

    // 返回从 origin 到采样点的归一化方向
    return normalize(p - origin);
}

/// 四边形光源 PDF 值计算
/// 参考: ~/ray_tracing/include/geometry/quad.h:pdf_value()
inline float quad_pdf_value(
    GPUQuad quad,
    float3 origin,
    float3 direction,
    device const GPUTransform* transforms
) {
    Ray r;
    r.origin = origin;
    r.direction = normalize(direction);
    r.time = 0.0f;

    HitRecord rec;
    if (!quad_hit(quad, transforms, r, 0.001f, 1e10f, &rec)) {
        return 0.0f;
    }

    // PDF = distance² / (cos(θ) * area)
    float distance_squared = rec.t * rec.t;
    float cosine = abs(dot(direction, rec.normal));
    float area = length(cross(quad.side_A, quad.side_B));

    return distance_squared / (cosine * area + 1e-10f);
}

// ========== SpecularPDF - 镜面反射采样 ==========

/// 镜面反射 PDF 值计算
/// 参考: ~/ray_tracing/include/sampling/pdf.h:specular_pdf::value()
/// 使用 von Mises-Fisher 分布的近似
inline float specular_pdf_value(float3 reflected_dir, float fuzz, float3 direction) {
    if (fuzz < 1e-8f) {
        // 完美镜面反射: delta 分布
        float cosine_theta = dot(normalize(direction), normalize(reflected_dir));
        return (cosine_theta > (1.0f - 1e-8f)) ? 1.0f / (M_PI_F * fuzz * fuzz + 1e-10f) : 0.0f;
    }

    // 模糊反射: 幂余弦分布 cos^n(θ)
    float cosine_theta = dot(normalize(direction), normalize(reflected_dir));

    if (cosine_theta < 0.0f) {
        return 0.0f;
    }

    // n = 1/fuzz² 控制锐度
    float exponent = 1.0f / (fuzz * fuzz + 0.01f);
    float normalizer = (exponent + 1.0f) / (2.0f * M_PI_F);

    return normalizer * pow(cosine_theta, exponent);
}

/// 镜面反射 PDF 生成方向
/// 参考: ~/ray_tracing/include/sampling/pdf.h:specular_pdf::generate()
inline float3 specular_pdf_generate(float3 reflected_dir, float fuzz, thread RandomState* rng) {
    // 在反射方向周围的单位球内采样
    float3 in_unit_sphere = random_unit_vector(rng) * fuzz;
    float3 direction = reflected_dir + in_unit_sphere;

    return normalize(direction);
}

// ========== 通用 PDF 接口函数 ==========

// 前向声明（用于 mixture_pdf 递归调用）
inline float pdf_value(
    PDF pdf,
    float3 direction,
    float3 origin,
    device const GPUSphere* spheres,
    device const GPUQuad* quads,
    device const GPUTransform* transforms,
    device const uint* light_indices,
    uint lights_count
);

inline float3 pdf_generate(
    PDF pdf,
    float3 origin,
    thread RandomState* rng,
    device const GPUSphere* spheres,
    device const GPUQuad* quads,
    device const uint* light_indices,
    uint lights_count
);

// ========== MixturePDF - 混合采样 (MIS 核心) ==========

/// 混合 PDF 值计算
/// 参考: ~/ray_tracing/include/sampling/pdf.h:mixture_pdf::value()
/// PDF = 0.5 * pdf1 + 0.5 * pdf2
inline float mixture_pdf_value(
    PDF pdf1,
    PDF pdf2,
    float3 direction,
    float3 origin,
    device const GPUSphere* spheres,
    device const GPUQuad* quads,
    device const GPUTransform* transforms,
    device const uint* light_indices,
    uint lights_count
) {
    float v1 = pdf_value(pdf1, direction, origin, spheres, quads, transforms, light_indices, lights_count);
    float v2 = pdf_value(pdf2, direction, origin, spheres, quads, transforms, light_indices, lights_count);
    return 0.5f * v1 + 0.5f * v2;
}

/// 混合 PDF 生成方向
/// 参考: ~/ray_tracing/include/sampling/pdf.h:mixture_pdf::generate()
/// 50% 概率选择 pdf1，50% 选择 pdf2
inline float3 mixture_pdf_generate(
    PDF pdf1,
    PDF pdf2,
    float3 origin,
    thread RandomState* rng,
    device const GPUSphere* spheres,
    device const GPUQuad* quads,
    device const uint* light_indices,
    uint lights_count
) {
    if (random_float(rng) < 0.5f) {
        return pdf_generate(pdf1, origin, rng, spheres, quads, light_indices, lights_count);
    } else {
        return pdf_generate(pdf2, origin, rng, spheres, quads, light_indices, lights_count);
    }
}

// ========== 通用 PDF 接口实现 ==========

/// 计算 PDF 值（多态分发）
inline float pdf_value(
    PDF pdf,
    float3 direction,
    float3 origin,
    device const GPUSphere* spheres,
    device const GPUQuad* quads,
    device const GPUTransform* transforms,
    device const uint* light_indices,
    uint lights_count
) {
    switch (pdf.type) {
        case PDF_COSINE:
            return cosine_pdf_value(pdf.w, direction);

        case PDF_HITTABLE: {
            // 获取光源索引
            uint light_idx = pdf.light_index;
            if (light_idx >= lights_count) return 0.0f;

            uint geom_idx = light_indices[light_idx];

            // 假设光源是 Quad（Phase 4 暂不支持 Sphere 光源）
            // TODO: 添加光源类型字段区分 Quad/Sphere
            return quad_pdf_value(quads[geom_idx], origin, direction, transforms);
        }

        case PDF_SPECULAR:
            return specular_pdf_value(pdf.w, pdf.fuzz, direction);

        case PDF_MIXTURE:
            // mixture_pdf 需要存储两个子 PDF
            // 暂不支持嵌套 mixture（Phase 4 限制）
            // TODO: Phase 5 支持完整的嵌套
            return 0.0f;

        default:
            return 0.0f;
    }
}

/// 生成采样方向（多态分发）
inline float3 pdf_generate(
    PDF pdf,
    float3 origin,
    thread RandomState* rng,
    device const GPUSphere* spheres,
    device const GPUQuad* quads,
    device const uint* light_indices,
    uint lights_count
) {
    switch (pdf.type) {
        case PDF_COSINE:
            return cosine_pdf_generate(pdf.w, rng);

        case PDF_HITTABLE: {
            uint light_idx = pdf.light_index;
            if (light_idx >= lights_count) {
                return random_unit_vector(rng);  // fallback
            }

            uint geom_idx = light_indices[light_idx];

            // 假设光源是 Quad
            return quad_random_direction(quads[geom_idx], origin, rng);
        }

        case PDF_SPECULAR:
            return specular_pdf_generate(pdf.w, pdf.fuzz, rng);

        case PDF_MIXTURE:
            // 暂不支持
            return random_unit_vector(rng);

        default:
            return random_unit_vector(rng);
    }
}

#endif // PDF_METAL
