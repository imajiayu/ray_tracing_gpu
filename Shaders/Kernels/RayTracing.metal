// RayTracing.metal
// 光线追踪渲染内核

#include <metal_stdlib>
#include "../Common/Types.metal"
#include "../Common/Random.metal"
#include "../Common/Geometry.metal"
#include "../Common/Materials.metal"
#include "../Common/Acceleration.metal"
using namespace metal;

// ========== 背景颜色 ==========

/// 天空背景渐变
/// 参考 ~/ray_tracing 的天空颜色实现
inline float3 background_color(Ray r) {
    float3 unit_direction = normalize(r.direction);
    float t = 0.5f * (unit_direction.y + 1.0f);
    return (1.0f - t) * float3(1.0f, 1.0f, 1.0f) + t * float3(0.5f, 0.7f, 1.0f);
}

// ========== 光线颜色计算 ==========

/// 递归式路径追踪（迭代实现，不使用 BVH）
inline float3 ray_color_no_bvh(
    Ray r,
    device const GPUSphere* spheres,
    uint sphere_count,
    device const GPUQuad* quads,
    uint quad_count,
    device const GPUMaterial* materials,
    device const GPUTexture* textures,
    texture2d<float> image_texture,
    constant float3* perlin_randvec,
    constant int* perlin_perm_x,
    constant int* perlin_perm_y,
    constant int* perlin_perm_z,
    device const GPUTransform* transforms,
    uint max_depth,
    thread RandomState* rng,
    bool use_background
) {
    Ray current_ray = r;
    float3 accumulated_color = float3(1.0f);

    // 迭代式路径追踪（避免递归）
    for (uint depth = 0; depth < max_depth; depth++) {
        HitRecord rec;
        bool hit_anything = false;
        float closest_so_far = 1e10f;

        // 测试所有球体
        for (uint i = 0; i < sphere_count; i++) {
            HitRecord temp_rec;
            if (sphere_hit(spheres[i], transforms, current_ray, 0.001f, closest_so_far, &temp_rec)) {
                hit_anything = true;
                closest_so_far = temp_rec.t;
                rec = temp_rec;
            }
        }

        // 测试所有 Quad
        for (uint i = 0; i < quad_count; i++) {
            HitRecord temp_rec;
            if (quad_hit(quads[i], transforms, current_ray, 0.001f, closest_so_far, &temp_rec)) {
                hit_anything = true;
                closest_so_far = temp_rec.t;
                rec = temp_rec;
            }
        }

        if (hit_anything) {
            // 获取材质发光
            float3 emission = material_emitted(materials, textures, image_texture,
                                               perlin_randvec, perlin_perm_x, perlin_perm_y, perlin_perm_z,
                                               rec.material_index, rec);

            // 材质散射
            float3 attenuation;
            Ray scattered;
            if (material_scatter(materials, textures, image_texture,
                               perlin_randvec, perlin_perm_x, perlin_perm_y, perlin_perm_z,
                               rec.material_index, current_ray, rec,
                               &attenuation, &scattered, rng)) {
                accumulated_color *= attenuation;
                current_ray = scattered;
            } else {
                // 材质不散射（如发光材质），返回发光颜色
                return accumulated_color * emission;
            }
        } else {
            // 击中天空背景或黑色背景
            if (use_background) {
                accumulated_color *= background_color(current_ray);
            } else {
                accumulated_color *= float3(0.0f);
            }
            return accumulated_color;
        }
    }

    // 超过最大深度，返回黑色（能量耗尽）
    return float3(0.0f);
}

/// 递归式路径追踪（迭代实现，使用 BVH 加速）
inline float3 ray_color_bvh(
    Ray r,
    device const GPUBVHNode* bvh_nodes,
    device const uint* geometry_indices,
    device const GPUSphere* spheres,
    uint sphere_count,
    device const GPUQuad* quads,
    uint quad_count,
    device const GPUMaterial* materials,
    device const GPUTexture* textures,
    texture2d<float> image_texture,
    constant float3* perlin_randvec,
    constant int* perlin_perm_x,
    constant int* perlin_perm_y,
    constant int* perlin_perm_z,
    device const GPUTransform* transforms,
    uint max_depth,
    thread RandomState* rng,
    bool use_background
) {
    Ray current_ray = r;
    float3 accumulated_color = float3(1.0f);

    // 迭代式路径追踪（避免递归）
    for (uint depth = 0; depth < max_depth; depth++) {
        HitRecord rec;
        bool hit_anything = false;

        // 使用 BVH 加速光线相交测试
        hit_anything = bvh_hit(
            bvh_nodes, geometry_indices,
            spheres, quads, transforms,
            sphere_count,
            current_ray, 0.001f, 1e10f, &rec
        );

        if (hit_anything) {
            // 获取材质发光
            float3 emission = material_emitted(materials, textures, image_texture,
                                               perlin_randvec, perlin_perm_x, perlin_perm_y, perlin_perm_z,
                                               rec.material_index, rec);

            // 材质散射
            float3 attenuation;
            Ray scattered;
            if (material_scatter(materials, textures, image_texture,
                               perlin_randvec, perlin_perm_x, perlin_perm_y, perlin_perm_z,
                               rec.material_index, current_ray, rec,
                               &attenuation, &scattered, rng)) {
                accumulated_color *= attenuation;
                current_ray = scattered;
            } else {
                // 材质不散射（如发光材质），返回发光颜色
                return accumulated_color * emission;
            }
        } else {
            // 击中天空背景或黑色背景
            if (use_background) {
                accumulated_color *= background_color(current_ray);
            } else {
                accumulated_color *= float3(0.0f);
            }
            return accumulated_color;
        }
    }

    // 超过最大深度，返回黑色（能量耗尽）
    return float3(0.0f);
}

// ========== 主内核 ==========

kernel void raytrace(
    texture2d<float, access::read_write> output [[texture(0)]],
    texture2d<float> image_texture [[texture(1)]],
    device const GPUSphere* spheres [[buffer(0)]],
    device const GPUMaterial* materials [[buffer(1)]],
    constant CameraParams& camera [[buffer(2)]],
    constant RenderParams& params [[buffer(3)]],
    device const GPUQuad* quads [[buffer(4)]],
    device const GPUTexture* textures [[buffer(5)]],
    device const GPUTransform* transforms [[buffer(6)]],
    device const GPUBVHNode* bvh_nodes [[buffer(7)]],
    device const uint* geometry_indices [[buffer(8)]],
    constant float3* perlin_randvec [[buffer(9)]],
    constant int* perlin_perm_x [[buffer(10)]],
    constant int* perlin_perm_y [[buffer(11)]],
    constant int* perlin_perm_z [[buffer(12)]],
    uint2 gid [[thread_position_in_grid]]
) {
    // 边界检查
    if (gid.x >= params.width || gid.y >= params.height) {
        return;
    }

    float3 pixel_color = float3(0.0f);

    // 多重采样抗锯齿
    for (uint s = 0; s < params.samples_per_pixel; s++) {
        // 为每个采样初始化独立的随机数种子
        // 使用像素坐标、采样索引、batch偏移量和质数来生成更好的种子分布
        uint global_sample_index = params.sample_offset + s;
        uint seed = (gid.x * 1973u + gid.y * 9277u + global_sample_index * 26699u) ^ 0x6c078965u;
        RandomState rng = random_init(seed);
        // 生成光线（与 CPU 版本完全一致）
        // camera.lower_left_corner 是 pixel00 的中心位置
        // camera.horizontal 是 pixel_delta_u（每个像素的 X 增量）
        // camera.vertical 是 pixel_delta_v（每个像素的 Y 增量）

        // 随机偏移（抗锯齿）
        float offset_x = random_float(&rng);
        float offset_y = random_float(&rng);

        // 像素采样位置 = pixel00 + i * delta_u + j * delta_v + random_offset
        float3 pixel_sample = camera.lower_left_corner +
                             (float(gid.x) + offset_x) * camera.horizontal +
                             (float(gid.y) + offset_y) * camera.vertical;

        // 计算光线起点（景深效果）
        float3 ray_origin = camera.origin;
        if (camera.defocus_angle > 0.0f) {
            // 在散焦盘上采样随机点
            float3 p = random_in_unit_disk(&rng);
            ray_origin = camera.origin + camera.defocus_disk_u * p.x + camera.defocus_disk_v * p.y;
        }

        // 光线方向 = pixel_sample - ray_origin
        Ray r;
        r.origin = ray_origin;
        r.direction = normalize(pixel_sample - ray_origin);
        r.time = 0.0f;

        // 累积颜色
        float3 color;
        if (params.use_bvh != 0) {
            // 使用 BVH 加速
            color = ray_color_bvh(r, bvh_nodes, geometry_indices,
                                 spheres, params.sphere_count, quads, params.quad_count,
                                 materials, textures, image_texture,
                                 perlin_randvec, perlin_perm_x, perlin_perm_y, perlin_perm_z,
                                 transforms, params.max_depth, &rng, params.use_background != 0);
        } else {
            // 不使用 BVH（fallback）
            color = ray_color_no_bvh(r, spheres, params.sphere_count, quads, params.quad_count,
                                    materials, textures, image_texture,
                                    perlin_randvec, perlin_perm_x, perlin_perm_y, perlin_perm_z,
                                    transforms, params.max_depth, &rng, params.use_background != 0);
        }
        // 检测并替换 NaN 分量（防止 Surface Acne）
        // NaN 检测: NaN != NaN
        if (color.r != color.r) color.r = 0.0f;
        if (color.g != color.g) color.g = 0.0f;
        if (color.b != color.b) color.b = 0.0f;

        pixel_color += color;
    }

    // 读取之前累积的颜色
    float4 prev_color = output.read(gid);

    // 累积新的采样（不做平均，在最后一批才平均）
    float3 accumulated = prev_color.rgb + pixel_color;

    // 最终 NaN 检查（防止累积错误）
    if (accumulated.r != accumulated.r) accumulated.r = 0.0f;
    if (accumulated.g != accumulated.g) accumulated.g = 0.0f;
    if (accumulated.b != accumulated.b) accumulated.b = 0.0f;

    // 写入累积结果（未 gamma 校正，在 CPU 端处理）
    output.write(float4(accumulated, 1.0f), gid);
}
