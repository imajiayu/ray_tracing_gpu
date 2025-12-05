// Materials.metal
// 材质散射函数 (GPU)

#ifndef MATERIALS_METAL
#define MATERIALS_METAL

#include <metal_stdlib>
#include "Types.metal"
#include "Random.metal"
#include "Geometry.metal"
#include "Textures.metal"
#include "PDF.metal"
using namespace metal;

// ========== ScatterRecord 结构 ==========

/// 散射记录结构 - 用于 MIS 采样
/// 参考: ~/ray_tracing/include/materials/material.h:scatter_record
struct ScatterRecord {
    float3 attenuation;  // BRDF 衰减系数
    PDF pdf;             // 材质的 PDF（值语义）
    bool skip_pdf;       // 镜面反射快速路径标志
    Ray skip_pdf_ray;    // 镜面反射光线
};

// ========== Lambertian 漫反射材质 ==========

/// Lambertian 散射（MIS 版本）
/// 参考 ~/ray_tracing/include/materials/material.h:lambertian::scatter()
inline bool lambertian_scatter_mis(
    GPUMaterial mat,
    device const GPUTexture* textures,
    texture2d<float> image_texture,
    constant float3* perlin_randvec,
    constant int* perlin_perm_x,
    constant int* perlin_perm_y,
    constant int* perlin_perm_z,
    Ray r_in,
    HitRecord rec,
    thread ScatterRecord* srec
) {
    // 获取反照率（支持纹理）
    if (mat.texture_index >= 0) {
        srec->attenuation = texture_value(textures[mat.texture_index], rec.u, rec.v, rec.p, image_texture,
                                         perlin_randvec, perlin_perm_x, perlin_perm_y, perlin_perm_z);
    } else {
        srec->attenuation = mat.albedo;
    }

    // 设置余弦加权 PDF
    srec->pdf.type = PDF_COSINE;
    srec->pdf.w = rec.normal;
    srec->skip_pdf = false;

    return true;
}

/// Lambertian 散射 PDF 值
/// 参考 ~/ray_tracing/include/materials/material.h:lambertian::scattering_pdf()
/// BRDF = albedo * cos(θ) / π
inline float lambertian_scattering_pdf(HitRecord rec, Ray scattered) {
    float cos_theta = dot(rec.normal, normalize(scattered.direction));
    return (cos_theta < 0.0f) ? 0.0f : cos_theta / M_PI_F;
}

// ========== Metal 金属材质 ==========

/// Metal 散射（MIS 版本）
/// 参考 ~/ray_tracing/include/materials/material.h:metal::scatter()
inline bool metal_scatter_mis(
    GPUMaterial mat,
    Ray r_in,
    HitRecord rec,
    thread ScatterRecord* srec
) {
    // 计算反射方向
    float3 reflected = metal::reflect(normalize(r_in.direction), rec.normal);

    srec->attenuation = mat.albedo;

    // 对于完美镜面反射 (fuzz=0)，使用 skip_pdf 快速路径
    if (mat.fuzz < 1e-8f) {
        srec->skip_pdf = true;
        srec->skip_pdf_ray = Ray{rec.p, reflected, r_in.time};
    } else {
        // 对于模糊反射，使用 specular_pdf
        srec->skip_pdf = false;
        srec->pdf.type = PDF_SPECULAR;
        srec->pdf.w = reflected;
        srec->pdf.fuzz = mat.fuzz;
    }

    return true;
}

/// Metal 散射 PDF 值
/// 参考 ~/ray_tracing/include/materials/material.h:metal::scattering_pdf()
inline float metal_scattering_pdf(GPUMaterial mat, HitRecord rec, Ray r_in, Ray scattered) {
    float3 reflected = metal::reflect(normalize(r_in.direction), rec.normal);

    if (mat.fuzz < 1e-8f) {
        // 完美镜面反射: delta 分布（不应被调用）
        return 0.0f;
    }

    // 使用与 specular_pdf 相同的公式
    float cosine_theta = dot(normalize(scattered.direction), normalize(reflected));

    if (cosine_theta < 0.0f) {
        return 0.0f;
    }

    float exponent = 1.0f / (mat.fuzz * mat.fuzz + 0.01f);
    float normalizer = (exponent + 1.0f) / (2.0f * M_PI_F);

    return normalizer * pow(cosine_theta, exponent);
}

// ========== Dielectric 电介质材质 ==========

/// Schlick 近似（菲涅尔反射率）
inline float reflectance(float cosine, float ref_idx) {
    float r0 = (1.0f - ref_idx) / (1.0f + ref_idx);
    r0 = r0 * r0;
    return r0 + (1.0f - r0) * pow((1.0f - cosine), 5.0f);
}

/// Dielectric 散射（MIS 版本）
/// 参考 ~/ray_tracing/include/materials/material.h:dielectric::scatter()
inline bool dielectric_scatter_mis(
    GPUMaterial mat,
    Ray r_in,
    HitRecord rec,
    thread ScatterRecord* srec,
    thread RandomState* rng
) {
    srec->attenuation = float3(1.0f, 1.0f, 1.0f);  // 玻璃不吸收光线
    srec->skip_pdf = true;  // 玻璃使用完美反射/折射

    float refraction_ratio = rec.front_face ? (1.0f / mat.refraction_index) : mat.refraction_index;

    float3 unit_direction = normalize(r_in.direction);
    float cos_theta = min(dot(-unit_direction, rec.normal), 1.0f);
    float sin_theta = sqrt(1.0f - cos_theta * cos_theta);

    bool cannot_refract = refraction_ratio * sin_theta > 1.0f;
    float3 direction;

    // 全内反射或 Schlick 近似决定反射
    if (cannot_refract || reflectance(cos_theta, refraction_ratio) > random_float(rng)) {
        direction = metal::reflect(unit_direction, rec.normal);
    } else {
        direction = metal::refract(unit_direction, rec.normal, refraction_ratio);

        // 验证折射结果（metal::refract 在全内反射时返回零向量）
        float len_sq = dot(direction, direction);
        if (len_sq < 1e-6f) {
            // 折射失败，退回到反射
            direction = metal::reflect(unit_direction, rec.normal);
        }
    }

    srec->skip_pdf_ray = Ray{rec.p, direction, r_in.time};
    return true;
}

/// Dielectric 散射 PDF 值（始终返回 0，因为使用 skip_pdf）
inline float dielectric_scattering_pdf(GPUMaterial mat, HitRecord rec, Ray r_in, Ray scattered) {
    return 0.0f;  // Dielectric 使用 delta 分布，不参与 PDF 计算
}

// ========== DiffuseLight 发光材质 ==========

/// DiffuseLight 散射（MIS 版本）
/// 参考 ~/ray_tracing/include/materials/material.h:diffuse_light::scatter()
/// 发光材质不散射光线，只发射光线
inline bool diffuse_light_scatter_mis(
    GPUMaterial mat,
    Ray r_in,
    HitRecord rec,
    thread ScatterRecord* srec
) {
    // 发光材质不散射
    return false;
}

/// DiffuseLight 散射 PDF 值（始终返回 0）
inline float diffuse_light_scattering_pdf(GPUMaterial mat, HitRecord rec, Ray r_in, Ray scattered) {
    return 0.0f;  // 发光材质不散射
}

// ========== 材质发光 ==========

/// 材质发光函数（支持纹理）
/// 只有 DiffuseLight 在正面击中时发光
inline float3 material_emitted(
    device const GPUMaterial* materials,
    device const GPUTexture* textures,
    texture2d<float> image_texture,
    constant float3* perlin_randvec,
    constant int* perlin_perm_x,
    constant int* perlin_perm_y,
    constant int* perlin_perm_z,
    uint material_index,
    HitRecord rec
) {
    GPUMaterial mat = materials[material_index];

    if (mat.type == MaterialDiffuseLight) {
        // 只有正面击中才发光
        if (rec.front_face) {
            if (mat.texture_index >= 0) {
                return texture_value(textures[mat.texture_index], rec.u, rec.v, rec.p, image_texture,
                                    perlin_randvec, perlin_perm_x, perlin_perm_y, perlin_perm_z);
            } else {
                return mat.emission;
            }
        }
    }

    return float3(0.0f);  // 其他材质不发光
}

// ========== 材质散射总入口（MIS 版本）==========

/// 材质散射函数（MIS 版本，返回 ScatterRecord）
/// 参考 ~/ray_tracing/include/materials/material.h:material::scatter()
inline bool material_scatter_mis(
    device const GPUMaterial* materials,
    device const GPUTexture* textures,
    texture2d<float> image_texture,
    constant float3* perlin_randvec,
    constant int* perlin_perm_x,
    constant int* perlin_perm_y,
    constant int* perlin_perm_z,
    uint material_index,
    Ray r_in,
    HitRecord rec,
    thread ScatterRecord* srec,
    thread RandomState* rng
) {
    GPUMaterial mat = materials[material_index];

    switch (mat.type) {
        case MaterialLambertian:
            return lambertian_scatter_mis(mat, textures, image_texture,
                                         perlin_randvec, perlin_perm_x, perlin_perm_y, perlin_perm_z,
                                         r_in, rec, srec);
        case MaterialMetal:
            return metal_scatter_mis(mat, r_in, rec, srec);
        case MaterialDielectric:
            return dielectric_scatter_mis(mat, r_in, rec, srec, rng);
        case MaterialDiffuseLight:
            return diffuse_light_scatter_mis(mat, r_in, rec, srec);
        default:
            return false;
    }
}

/// 材质散射 PDF 值
/// 参考 ~/ray_tracing/include/materials/material.h:material::scattering_pdf()
inline float material_scattering_pdf(
    device const GPUMaterial* materials,
    uint material_index,
    Ray r_in,
    HitRecord rec,
    Ray scattered
) {
    GPUMaterial mat = materials[material_index];

    switch (mat.type) {
        case MaterialLambertian:
            return lambertian_scattering_pdf(rec, scattered);
        case MaterialMetal:
            return metal_scattering_pdf(mat, rec, r_in, scattered);
        case MaterialDielectric:
            return dielectric_scattering_pdf(mat, rec, r_in, scattered);
        case MaterialDiffuseLight:
            return diffuse_light_scattering_pdf(mat, rec, r_in, scattered);
        default:
            return 0.0f;
    }
}

// ========== 向后兼容接口（用于旧版本 ray_color）==========

/// 旧版本材质散射函数（向后兼容）
/// 这个函数保留用于现有的 RayTracing.metal，Phase 4 完成后将删除
#endif // MATERIALS_METAL
