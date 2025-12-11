// RayTracing.metal
// 光线追踪渲染内核

#include <metal_stdlib>
#include "../Common/Types.metal"
#include "../Common/Random.metal"
#include "../Common/Geometry.metal"
#include "../Common/Materials.metal"
#include "../Common/Acceleration.metal"
#include "../Common/Filter.metal"
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

/// 路径追踪（使用 BVH 加速 + MIS 多重重要性采样）
/// 参考 ~/ray_tracing/include/camera/camera.h:ray_color()
inline float3 ray_color(
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
    device const uint* light_indices,
    uint lights_count,
    uint max_depth,
    thread RandomState* rng,
    bool use_background
)  {
    Ray current_ray = r;
    float3 accumulated_throughput = float3(1.0f);  // 路径吞吐量
    float3 accumulated_radiance = float3(0.0f);    // 累积的辐射度

    // 迭代式路径追踪（避免递归）
    for (uint depth = 0; depth < max_depth; depth++) {
        HitRecord rec;
        bool hit_anything = false;

        // 使用 BVH 加速光线相交测试（支持体积雾）
        hit_anything = bvh_hit(
            bvh_nodes, geometry_indices,
            spheres, quads, transforms,
            sphere_count,
            current_ray, 0.001f, 1e10f, &rec, rng
        );

        if (hit_anything) {
            // 1. 获取材质发光，并累加到辐射度
            float3 emission = material_emitted(materials, textures, image_texture,
                                               perlin_randvec, perlin_perm_x, perlin_perm_y, perlin_perm_z,
                                               rec.material_index, rec);
            accumulated_radiance += accumulated_throughput * emission;

            // 2. 材质散射（MIS 版本）
            ScatterRecord srec;
            if (!material_scatter_mis(materials, textures, image_texture,
                                     perlin_randvec, perlin_perm_x, perlin_perm_y, perlin_perm_z,
                                     rec.material_index, current_ray, rec, &srec, rng)) {
                // 材质不散射（如发光材质），结束路径
                break;
            }

            // 3. 镜面反射快速路径（Dielectric, Perfect Metal）
            if (srec.skip_pdf) {
                accumulated_throughput *= srec.attenuation;
                current_ray = srec.skip_pdf_ray;
                continue;
            }

            // 4. 根据是否有光源选择采样策略
            if (lights_count == 0) {
                // ===== 路径 A: 无光源（天空光照）- 纯 BRDF 采样 =====

                // 4.1 从材质 PDF 生成散射方向
                float3 scattered_dir = pdf_generate(
                    srec.pdf, rec.p, rng,
                    spheres, quads, light_indices, lights_count
                );

                Ray scattered = {rec.p, scattered_dir, current_ray.time};

                // 4.2 计算 PDF 值
                float pdf_val = pdf_value(
                    srec.pdf, scattered_dir, rec.p,
                    spheres, quads, transforms, light_indices, lights_count
                );

                // 4.3 计算材质散射 PDF（BRDF）
                float scattering_pdf = material_scattering_pdf(
                    materials, rec.material_index, current_ray, rec, scattered
                );

                // 4.4 蒙特卡洛积分: color = (attenuation * scattering_pdf * sample_color) / pdf_value
                // 注意：这里我们需要递归，但 GPU 不支持递归
                // 因此我们简化为迭代式：累积 attenuation，继续追踪
                // 使用 fmax 确保 PDF 不为零（提高阈值避免数值不稳定）
                accumulated_throughput *= srec.attenuation * (scattering_pdf / fmax(1e-6f, pdf_val));
                current_ray = scattered;

            } else {
                // ===== 路径 B: 有光源 - MIS (50% 光源 + 50% BRDF) =====

                // 4.1 随机选择一个光源
                uint light_idx = uint(random_float(rng) * float(lights_count)) % lights_count;

                // 4.2 创建光源 PDF
                PDF light_pdf;
                light_pdf.type = PDF_HITTABLE;
                light_pdf.light_index = light_idx;

                // 4.3 创建混合 PDF（50% 光源 + 50% BRDF）
                float3 scattered_dir;

                if (random_float(rng) < 0.5f) {
                    // 从光源采样
                    scattered_dir = pdf_generate(
                        light_pdf, rec.p, rng,
                        spheres, quads, light_indices, lights_count
                    );
                } else {
                    // 从材质 BRDF 采样
                    scattered_dir = pdf_generate(
                        srec.pdf, rec.p, rng,
                        spheres, quads, light_indices, lights_count
                    );
                }

                Ray scattered = {rec.p, scattered_dir, current_ray.time};

                // 4.4 计算混合 PDF 值（使用 Power Heuristic）
                float light_pdf_val = pdf_value(
                    light_pdf, scattered_dir, rec.p,
                    spheres, quads, transforms, light_indices, lights_count
                );
                float brdf_pdf_val = pdf_value(
                    srec.pdf, scattered_dir, rec.p,
                    spheres, quads, transforms, light_indices, lights_count
                );

                // 使用 Power Heuristic 计算自适应权重（Phase 5 优化）
                float w_light = power_heuristic(light_pdf_val, brdf_pdf_val);
                float w_brdf = 1.0f - w_light;
                float pdf_val = w_light * light_pdf_val + w_brdf * brdf_pdf_val;

                // 4.5 计算材质散射 PDF（BRDF）
                float scattering_pdf = material_scattering_pdf(
                    materials, rec.material_index, current_ray, rec, scattered
                );

                // 4.6 蒙特卡洛积分（使用 fmax 确保 PDF 不为零）
                accumulated_throughput *= srec.attenuation * (scattering_pdf / fmax(1e-6f, pdf_val));
                current_ray = scattered;
            }


        } else {
            // 击中天空背景或黑色背景
            if (use_background) {
                accumulated_radiance += accumulated_throughput * background_color(current_ray);
            }
            break;
        }
    }

    return accumulated_radiance;
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
    device const uint* light_indices [[buffer(13)]],
    uint2 gid [[thread_position_in_grid]]
) {
    // 边界检查
    if (gid.x >= params.width || gid.y >= params.height) {
        return;
    }

    float3 pixel_color = float3(0.0f);
    float total_weight = 0.0f;  // 累积权重（用于滤波器归一化）

    // 分层采样抗锯齿（Stratified Sampling）+ 像素重建滤波器
    // 将像素分成 sqrt_spp × sqrt_spp 的网格，在每个子格子内随机采样
    // 参考 ~/ray_tracing/include/camera/camera.h:269-274
    for (uint s_j = 0; s_j < params.sqrt_spp; s_j++) {
        for (uint s_i = 0; s_i < params.sqrt_spp; s_i++) {
            // 为每个采样初始化独立的随机数种子
            // 使用像素坐标、子格子索引、batch偏移量和质数来生成更好的种子分布
            uint subpixel_index = s_j * params.sqrt_spp + s_i;
            uint global_sample_index = params.sample_offset + subpixel_index;
            uint seed = (gid.x * 1973u + gid.y * 9277u + global_sample_index * 26699u) ^ 0x6c078965u;
            RandomState rng = random_init(seed);

            // 分层采样：在子格子 (s_i, s_j) 内随机采样
            // 像素采样偏移范围 [0, 1]，用于像素位置计算
            float px_offset = (float(s_i) + random_float(&rng)) * params.recip_sqrt_spp;
            float py_offset = (float(s_j) + random_float(&rng)) * params.recip_sqrt_spp;

            // 滤波器权重参数范围 [-0.5, 0.5]，相对于像素中心的偏移
            float px_filter = px_offset - 0.5f;
            float py_filter = py_offset - 0.5f;

            // 计算滤波器权重（基于采样点到像素中心的距离）
            float filter_weight = evaluate_filter(params.filter_type, px_filter, py_filter);

            // 像素采样位置 = pixel00 + (i + offset_x) * delta_u + (j + offset_y) * delta_v
            float3 pixel_sample = camera.lower_left_corner +
                                 (float(gid.x) + px_offset) * camera.horizontal +
                                 (float(gid.y) + py_offset) * camera.vertical;

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

        // 计算光线颜色（使用 BVH + MIS）
        float3 color = ray_color(r, bvh_nodes, geometry_indices,
                                spheres, params.sphere_count, quads, params.quad_count,
                                materials, textures, image_texture,
                                perlin_randvec, perlin_perm_x, perlin_perm_y, perlin_perm_z,
                                transforms, light_indices, params.lights_count,
                                params.max_depth, &rng, params.use_background != 0);
        // 检测并替换 NaN 分量（防止 Surface Acne）
        // NaN 检测: NaN != NaN
        if (color.r != color.r) color.r = 0.0f;
        if (color.g != color.g) color.g = 0.0f;
        if (color.b != color.b) color.b = 0.0f;

        // 使用滤波器权重累积颜色
        pixel_color += color * filter_weight;
        total_weight += filter_weight;
        }
    }

    // 归一化：除以总权重（而不是采样数）
    if (total_weight > 0.0f) {
        pixel_color /= total_weight;
    }

    // 读取之前累积的颜色（离线模式：多批次累积；窗口模式：新纹理，初始为0）
    float4 prev_color = output.read(gid);

    // 累积新的采样（已经归一化为平均值）
    // 注意：这里累积的是归一化后的颜色，不再是原始累积
    float3 accumulated = prev_color.rgb + pixel_color;

    // 最终 NaN 检查（防止累积错误）
    if (accumulated.r != accumulated.r) accumulated.r = 0.0f;
    if (accumulated.g != accumulated.g) accumulated.g = 0.0f;
    if (accumulated.b != accumulated.b) accumulated.b = 0.0f;

    // 写入累积结果（未 gamma 校正，在 CPU 端处理）
    output.write(float4(accumulated, 1.0f), gid);
}

/// 实时窗口模式渲染内核
/// 与 raytrace 的区别：输出平均值而不是累积值，适合外部累积器
kernel void raytrace_realtime(
    texture2d<float, access::write> output [[texture(0)]],
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
    device const uint* light_indices [[buffer(13)]],
    uint2 gid [[thread_position_in_grid]]
) {
    // 边界检查
    if (gid.x >= params.width || gid.y >= params.height) {
        return;
    }

    float3 pixel_color = float3(0.0f);
    float total_weight = 0.0f;  // 累积权重（用于滤波器归一化）

    // 分层采样抗锯齿（Stratified Sampling）+ 像素重建滤波器
    // 将像素分成 sqrt_spp × sqrt_spp 的网格，在每个子格子内随机采样
    for (uint s_j = 0; s_j < params.sqrt_spp; s_j++) {
        for (uint s_i = 0; s_i < params.sqrt_spp; s_i++) {
            // 为每个采样初始化独立的随机数种子
            uint subpixel_index = s_j * params.sqrt_spp + s_i;
            uint global_sample_index = params.sample_offset + subpixel_index;
            uint seed = (gid.x * 1973u + gid.y * 9277u + global_sample_index * 26699u) ^ 0x6c078965u;
            RandomState rng = random_init(seed);

            // 分层采样：在子格子 (s_i, s_j) 内随机采样
            // 像素采样偏移范围 [0, 1]，用于像素位置计算
            float px_offset = (float(s_i) + random_float(&rng)) * params.recip_sqrt_spp;
            float py_offset = (float(s_j) + random_float(&rng)) * params.recip_sqrt_spp;

            // 滤波器权重参数范围 [-0.5, 0.5]，相对于像素中心的偏移
            float px_filter = px_offset - 0.5f;
            float py_filter = py_offset - 0.5f;

            // 计算滤波器权重（基于采样点到像素中心的距离）
            float filter_weight = evaluate_filter(params.filter_type, px_filter, py_filter);

            // 像素采样位置
            float3 pixel_sample = camera.lower_left_corner +
                                 (float(gid.x) + px_offset) * camera.horizontal +
                                 (float(gid.y) + py_offset) * camera.vertical;

        // 计算光线起点（景深效果）
        float3 ray_origin = camera.origin;
        if (camera.defocus_angle > 0.0f) {
            float3 p = random_in_unit_disk(&rng);
            ray_origin = camera.origin + camera.defocus_disk_u * p.x + camera.defocus_disk_v * p.y;
        }

        // 光线方向
        Ray r;
        r.origin = ray_origin;
        r.direction = normalize(pixel_sample - ray_origin);
        r.time = 0.0f;

        // 计算光线颜色（使用 BVH + MIS）
        float3 color = ray_color(r, bvh_nodes, geometry_indices,
                                spheres, params.sphere_count, quads, params.quad_count,
                                materials, textures, image_texture,
                                perlin_randvec, perlin_perm_x, perlin_perm_y, perlin_perm_z,
                                transforms, light_indices, params.lights_count,
                                params.max_depth, &rng, params.use_background != 0);

        // NaN 检测
        if (color.r != color.r) color.r = 0.0f;
        if (color.g != color.g) color.g = 0.0f;
        if (color.b != color.b) color.b = 0.0f;

        // 使用滤波器权重累积颜色
        pixel_color += color * filter_weight;
        total_weight += filter_weight;
        }
    }

    // 计算平均颜色（窗口模式：输出平均值，由外部累积器累加）
    // 归一化：除以总权重（而不是采样数）
    float3 averaged = float3(0.0f);
    if (total_weight > 0.0f) {
        averaged = pixel_color / total_weight;
    }

    // 最终 NaN 检查
    if (averaged.r != averaged.r) averaged.r = 0.0f;
    if (averaged.g != averaged.g) averaged.g = 0.0f;
    if (averaged.b != averaged.b) averaged.b = 0.0f;

    // 写入平均结果（未 gamma 校正，在显示端处理）
    output.write(float4(averaged, 1.0f), gid);
}
