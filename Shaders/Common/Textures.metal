// Textures.metal
// 纹理采样函数

#ifndef TEXTURES_METAL
#define TEXTURES_METAL

#include <metal_stdlib>
#include "Types.metal"
#include "Random.metal"
using namespace metal;

// ========== Perlin 噪声 ==========

/// 生成伪随机梯度向量（使用哈希函数）
/// 参考 CPU 版本的实现，使用梯度噪声而不是值噪声
inline float3 perlin_random_gradient(int ix, int iy, int iz) {
    // 使用哈希函数生成伪随机向量
    // 确保相同的输入总是产生相同的输出
    const uint h = (uint(ix) * 1973u + uint(iy) * 9277u + uint(iz) * 26699u) ^ 0x6c078965u;

    // 生成单位向量（使用 PCG 哈希）
    uint h1 = h * 747796405u + 2891336453u;
    uint h2 = h1 * 747796405u + 2891336453u;
    uint h3 = h2 * 747796405u + 2891336453u;

    float x = float(h1) / 4294967296.0f * 2.0f - 1.0f;
    float y = float(h2) / 4294967296.0f * 2.0f - 1.0f;
    float z = float(h3) / 4294967296.0f * 2.0f - 1.0f;

    return normalize(float3(x, y, z));
}

/// Perlin 梯度噪声实现（参考 CPU 版本）
/// 使用梯度向量和三线性插值
inline float perlin_noise(float3 p, thread RandomState* rng) {
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
    float3 c[2][2][2];
    for (int di = 0; di < 2; di++) {
        for (int dj = 0; dj < 2; dj++) {
            for (int dk = 0; dk < 2; dk++) {
                // 使用位运算模拟 CPU 版本的 perm_x/y/z 和异或操作
                int hash_x = (ix + di) & 255;
                int hash_y = (iy + dj) & 255;
                int hash_z = (iz + dk) & 255;
                c[di][dj][dk] = perlin_random_gradient(hash_x, hash_y, hash_z);
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
inline float turb(float3 p, int depth, thread RandomState* rng) {
    float accum = 0.0f;
    float3 temp_p = p;
    float weight = 1.0f;

    for (int i = 0; i < depth; i++) {
        accum += weight * perlin_noise(temp_p, rng);
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
    thread RandomState* rng
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
            {
                float noise_val = turb(tex.scale * p, 7, rng);
                float sine_val = sin(tex.scale * p.z + 10.0f * noise_val);
                // sine_val 范围 [-1, 1]，归一化到 [0, 1]
                // (1.0 + sine_val) / 2.0 => [0, 1]
                return tex.albedo * 0.5f * (1.0f + sine_val);
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
