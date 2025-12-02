// Materials.metal
// 材质散射函数 (GPU)

#ifndef MATERIALS_METAL
#define MATERIALS_METAL

#include <metal_stdlib>
#include "Types.metal"
#include "Random.metal"
#include "Geometry.metal"
#include "Textures.metal"
using namespace metal;

// ========== Lambertian 漫反射材质 ==========

/// Lambertian 散射（支持纹理）
/// 参考 ~/ray_tracing/include/materials/material.h:lambertian
inline bool lambertian_scatter(
    GPUMaterial mat,
    device const GPUTexture* textures,
    texture2d<float> image_texture,
    Ray r_in,
    HitRecord rec,
    thread float3* attenuation,
    thread Ray* scattered,
    thread RandomState* rng
) {
    // 余弦加权半球采样
    float3 scatter_direction = rec.normal + random_unit_vector(rng);

    // 处理退化情况（散射方向接近零）
    if (length(scatter_direction) < 1e-8f) {
        scatter_direction = rec.normal;
    }

    // 生成散射光线
    *scattered = Ray{rec.p, normalize(scatter_direction), r_in.time};

    // 获取反照率（支持纹理）
    if (mat.texture_index >= 0) {
        *attenuation = texture_value(textures[mat.texture_index], rec.u, rec.v, rec.p, image_texture, rng);
    } else {
        *attenuation = mat.albedo;
    }

    return true;
}

// ========== Metal 金属材质 ==========

/// Metal 散射
inline bool metal_scatter(
    GPUMaterial mat,
    Ray r_in,
    HitRecord rec,
    thread float3* attenuation,
    thread Ray* scattered,
    thread RandomState* rng
) {
    // 使用 Metal 标准库的 reflect 函数
    float3 reflected = metal::reflect(normalize(r_in.direction), rec.normal);

    // 添加模糊（fuzz）
    float3 scatter_direction = reflected + mat.fuzz * random_unit_vector(rng);

    *scattered = Ray{rec.p, normalize(scatter_direction), r_in.time};
    *attenuation = mat.albedo;

    // 只有反射方向在表面上方才散射
    return (dot(scattered->direction, rec.normal) > 0.0f);
}

// ========== Dielectric 电介质材质 ==========

/// Schlick 近似（菲涅尔反射率）
inline float reflectance(float cosine, float ref_idx) {
    float r0 = (1.0f - ref_idx) / (1.0f + ref_idx);
    r0 = r0 * r0;
    return r0 + (1.0f - r0) * pow((1.0f - cosine), 5.0f);
}

/// Dielectric 散射
inline bool dielectric_scatter(
    GPUMaterial mat,
    Ray r_in,
    HitRecord rec,
    thread float3* attenuation,
    thread Ray* scattered,
    thread RandomState* rng
) {
    *attenuation = float3(1.0f, 1.0f, 1.0f);  // 玻璃不吸收光线

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
    }

    *scattered = Ray{rec.p, direction, r_in.time};
    return true;
}

// ========== DiffuseLight 发光材质 ==========

/// DiffuseLight 散射（支持纹理）
/// 参考 ~/ray_tracing/include/materials/material.h:diffuse_light
/// 发光材质不散射光线，只发射光线
inline bool diffuse_light_scatter(
    GPUMaterial mat,
    device const GPUTexture* textures,
    Ray r_in,
    HitRecord rec,
    thread float3* attenuation,
    thread Ray* scattered,
    thread RandomState* rng
) {
    // 发光材质不散射
    return false;
}

// ========== Isotropic 各向同性材质（体积雾用）==========

/// Isotropic 散射（支持纹理）
/// 参考 ~/ray_tracing/include/materials/material.h:isotropic
/// 各向同性散射，用于体积雾效果
inline bool isotropic_scatter(
    GPUMaterial mat,
    device const GPUTexture* textures,
    texture2d<float> image_texture,
    Ray r_in,
    HitRecord rec,
    thread float3* attenuation,
    thread Ray* scattered,
    thread RandomState* rng
) {
    // 均匀球面散射
    *scattered = Ray{rec.p, random_unit_vector(rng), r_in.time};

    // 获取反照率（支持纹理）
    if (mat.texture_index >= 0) {
        *attenuation = texture_value(textures[mat.texture_index], rec.u, rec.v, rec.p, image_texture, rng);
    } else {
        *attenuation = mat.albedo;
    }

    return true;
}

// ========== 材质发光 ==========

/// 材质发光函数（支持纹理）
/// 只有 DiffuseLight 在正面击中时发光
inline float3 material_emitted(
    device const GPUMaterial* materials,
    device const GPUTexture* textures,
    texture2d<float> image_texture,
    uint material_index,
    HitRecord rec,
    thread RandomState* rng
) {
    GPUMaterial mat = materials[material_index];

    if (mat.type == MaterialDiffuseLight) {
        // 只有正面击中才发光
        if (rec.front_face) {
            if (mat.texture_index >= 0) {
                return texture_value(textures[mat.texture_index], rec.u, rec.v, rec.p, image_texture, rng);
            } else {
                return mat.emission;
            }
        }
    }

    return float3(0.0f);  // 其他材质不发光
}

// ========== 材质散射总入口 ==========

/// 材质散射函数（根据类型分发，支持纹理）
inline bool material_scatter(
    device const GPUMaterial* materials,
    device const GPUTexture* textures,
    texture2d<float> image_texture,
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
            return lambertian_scatter(mat, textures, image_texture, r_in, rec, attenuation, scattered, rng);
        case MaterialMetal:
            return metal_scatter(mat, r_in, rec, attenuation, scattered, rng);
        case MaterialDielectric:
            return dielectric_scatter(mat, r_in, rec, attenuation, scattered, rng);
        case MaterialDiffuseLight:
            return diffuse_light_scatter(mat, textures, r_in, rec, attenuation, scattered, rng);
        case MaterialIsotropic:
            return isotropic_scatter(mat, textures, image_texture, r_in, rec, attenuation, scattered, rng);
        default:
            return false;
    }
}

#endif // MATERIALS_METAL
