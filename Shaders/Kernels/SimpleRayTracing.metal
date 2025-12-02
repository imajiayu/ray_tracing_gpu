// SimpleRayTracing.metal
// 简单路径追踪内核

#include <metal_stdlib>
#include "../Common/Types.metal"
#include "../Common/Random.metal"
#include "../Common/Geometry.metal"
#include "../Common/Materials.metal"
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

/// 递归式路径追踪（迭代实现）
inline float3 ray_color(
    Ray r,
    device const GPUSphere* spheres,
    uint sphere_count,
    device const GPUQuad* quads,
    uint quad_count,
    device const GPUConstantMedium* constant_mediums,
    uint constant_medium_count,
    device const GPUMaterial* materials,
    device const GPUTexture* textures,
    texture2d<float> image_texture,
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

        // 测试所有体积雾
        for (uint i = 0; i < constant_medium_count; i++) {
            HitRecord temp_rec;
            if (constant_medium_hit(constant_mediums[i], spheres, quads, transforms,
                                  current_ray, 0.001f, closest_so_far, &temp_rec, rng)) {
                hit_anything = true;
                closest_so_far = temp_rec.t;
                rec = temp_rec;
            }
        }

        if (hit_anything) {
            // 获取材质发光
            float3 emission = material_emitted(materials, textures, image_texture, rec.material_index, rec, rng);

            // 材质散射
            float3 attenuation;
            Ray scattered;
            if (material_scatter(materials, textures, image_texture, rec.material_index, current_ray, rec,
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

kernel void simple_raytrace(
    texture2d<float, access::read_write> output [[texture(0)]],
    texture2d<float> image_texture [[texture(1)]],
    device const GPUSphere* spheres [[buffer(0)]],
    device const GPUMaterial* materials [[buffer(1)]],
    constant CameraParams& camera [[buffer(2)]],
    constant RenderParams& params [[buffer(3)]],
    device const GPUQuad* quads [[buffer(4)]],
    device const GPUTexture* textures [[buffer(5)]],
    device const GPUTransform* transforms [[buffer(6)]],
    device const GPUConstantMedium* constant_mediums [[buffer(7)]],
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

        // 光线方向 = pixel_sample - ray_origin
        Ray r;
        r.origin = camera.origin;
        r.direction = normalize(pixel_sample - camera.origin);
        r.time = 0.0f;

        // 累积颜色
        pixel_color += ray_color(r, spheres, params.sphere_count, quads, params.quad_count,
                                constant_mediums, params.constant_medium_count,
                                materials, textures, image_texture, transforms, params.max_depth, &rng, params.use_background != 0);
    }

    // 读取之前累积的颜色
    float4 prev_color = output.read(gid);

    // 累积新的采样（不做平均，在最后一批才平均）
    float3 accumulated = prev_color.rgb + pixel_color;

    // 写入累积结果（未 gamma 校正，在 CPU 端处理）
    output.write(float4(accumulated, 1.0f), gid);
}
