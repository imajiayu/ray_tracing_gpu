// Textures.metal
// 纹理采样函数

#ifndef TEXTURES_METAL
#define TEXTURES_METAL

#include <metal_stdlib>
#include "Types.metal"
#include "Random.metal"
using namespace metal;

// ========== Perlin 噪声 ==========

/// Perlin 梯度噪声实现（使用 CPU 传入的数据，与 CPU 版本完全一致）
/// 参数：
///   - p: 采样点
///   - randvec: 梯度向量表 (256 个)
///   - perm_x: X 轴置换表
///   - perm_y: Y 轴置换表
///   - perm_z: Z 轴置换表
inline float perlin_noise(
    float3 p,
    constant float3* randvec,
    constant int* perm_x,
    constant int* perm_y,
    constant int* perm_z
) {
    // 整数部分
    int ix = int(floor(p.x));
    int iy = int(floor(p.y));
    int iz = int(floor(p.z));

    // 小数部分
    float fx = p.x - floor(p.x);
    float fy = p.y - floor(p.y);
    float fz = p.z - floor(p.z);

    // Hermite 平滑插值函数（与 CPU 版本一致）
    float u = fx * fx * (3.0f - 2.0f * fx);
    float v = fy * fy * (3.0f - 2.0f * fy);
    float w = fz * fz * (3.0f - 2.0f * fz);

    // 获取8个角的梯度向量
    // 使用置换表和XOR操作，完全匹配CPU版本的实现
    float3 c[2][2][2];
    for (int di = 0; di < 2; di++) {
        for (int dj = 0; dj < 2; dj++) {
            for (int dk = 0; dk < 2; dk++) {
                // CPU版本: randvec[perm_x[(i+di)&255] ^ perm_y[(j+dj)&255] ^ perm_z[(k+dk)&255]]
                int px = perm_x[(ix + di) & 255];
                int py = perm_y[(iy + dj) & 255];
                int pz = perm_z[(iz + dk) & 255];
                int index = px ^ py ^ pz;
                c[di][dj][dk] = randvec[index];
            }
        }
    }

    // Perlin 插值（与 CPU 版本一致）
    float accum = 0.0f;
    for (int i = 0; i < 2; i++) {
        for (int j = 0; j < 2; j++) {
            for (int k = 0; k < 2; k++) {
                float3 weight_v = float3(fx - float(i), fy - float(j), fz - float(k));
                accum += (float(i) * u + (1.0f - float(i)) * (1.0f - u)) *
                         (float(j) * v + (1.0f - float(j)) * (1.0f - v)) *
                         (float(k) * w + (1.0f - float(k)) * (1.0f - w)) *
                         dot(c[i][j][k], weight_v);
            }
        }
    }

    return accum;
}

/// 湍流噪声（多层Perlin噪声叠加）
inline float turb(
    float3 p,
    int depth,
    constant float3* randvec,
    constant int* perm_x,
    constant int* perm_y,
    constant int* perm_z
) {
    float accum = 0.0f;
    float3 temp_p = p;
    float weight = 1.0f;

    for (int i = 0; i < depth; i++) {
        accum += weight * perlin_noise(temp_p, randvec, perm_x, perm_y, perm_z);
        weight *= 0.5f;
        temp_p *= 2.0f;
    }

    return abs(accum);
}

// ========== 纹理采样 ==========

/// 纹理采样函数
/// 根据纹理类型返回对应的颜色值
inline float3 texture_value(
    GPUTexture tex,
    float u,
    float v,
    float3 p,
    texture2d<float> image_texture,
    constant float3* perlin_randvec,
    constant int* perlin_perm_x,
    constant int* perlin_perm_y,
    constant int* perlin_perm_z
) {
    switch (tex.type) {
        case TextureSolidColor:
            // 纯色纹理
            return tex.albedo;

        case TextureChecker:
            // 棋盘格纹理
            {
                int xInteger = int(floor(tex.inv_scale * p.x));
                int yInteger = int(floor(tex.inv_scale * p.y));
                int zInteger = int(floor(tex.inv_scale * p.z));

                bool isEven = (xInteger + yInteger + zInteger) % 2 == 0;
                return isEven ? tex.albedo : tex.odd_color;
            }

        case TextureNoise:
            // Perlin噪声纹理（大理石效果）
            // CPU 版本: color(0.5, 0.5, 0.5) * (1.0 + sin(scale * p.z + 10.0 * turb(p, 7)))
            // 关键：turb() 接收原始 p，不是 scale * p！
            {
                float noise_val = turb(p, 7, perlin_randvec, perlin_perm_x, perlin_perm_y, perlin_perm_z);
                float sine_val = sin(tex.scale * p.z + 10.0f * noise_val);
                // 注意：CPU 版本直接乘以 (1.0 + sine_val)，不额外除以 2
                // sine_val 范围 [-1, 1]，所以 (1.0 + sine_val) 范围 [0, 2]
                // 最终颜色范围: [0, 1] (因为 tex.albedo = 0.5)
                return tex.albedo * (1.0f + sine_val);
            }

        case TextureImage:
            // 图像纹理（目前只支持 index 0）
            {
                if (tex.image_index != 0) {
                    return float3(1.0f, 0.0f, 1.0f); // 只支持第一个纹理
                }

                // 使用线性采样器
                constexpr sampler textureSampler(mag_filter::linear,
                                                  min_filter::linear,
                                                  address::clamp_to_edge);

                // 采样图片纹理（注意：v需要翻转，因为图片坐标系与UV不同）
                float2 texCoord = float2(u, 1.0f - v);
                float4 color = image_texture.sample(textureSampler, texCoord);

                return color.rgb;
            }

        default:
            return float3(1.0f, 0.0f, 1.0f); // 错误颜色
    }
}

#endif // TEXTURES_METAL
