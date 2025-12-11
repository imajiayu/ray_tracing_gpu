// Bloom.metal
// Bloom 后处理效果 (Kawase Blur 优化)
//
// Phase 7 - Post-Processing
//
// 流程：
// 1. Bright Pass - 提取亮度 > threshold 的像素
// 2. Downsample - 多级降采样（模糊优化）
// 3. Upsample - 上采样并混合
// 4. Final Blend - 与原图混合

#include <metal_stdlib>
using namespace metal;

// ========== Bright Pass Kernel ==========
// 提取高亮像素（亮度 > threshold）
kernel void bright_pass(
    texture2d<float, access::read> inputTexture [[texture(0)]],
    texture2d<float, access::write> outputTexture [[texture(1)]],
    constant float& threshold [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= inputTexture.get_width() || gid.y >= inputTexture.get_height()) {
        return;
    }

    float4 color = inputTexture.read(gid);

    // 计算亮度（相对亮度）
    float luminance = dot(color.rgb, float3(0.2126, 0.7152, 0.0722));

    // 如果亮度超过阈值，保留；否则输出黑色
    if (luminance > threshold) {
        // 保持原色，但可以选择性增强
        outputTexture.write(color, gid);
    } else {
        outputTexture.write(float4(0.0), gid);
    }
}

// ========== Downsample Kernel (13-tap Kawase Blur) ==========
// 降采样 + Kawase 模糊（13 个采样点：对角线 + 十字 + 中心）
kernel void downsample(
    texture2d<float, access::read> inputTexture [[texture(0)]],
    texture2d<float, access::write> outputTexture [[texture(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) {
        return;
    }

    // 对应输入纹理的位置（2x 放大）
    int2 srcPos = int2(gid) * 2;

    int width = int(inputTexture.get_width());
    int height = int(inputTexture.get_height());

    // 13-tap Kawase Blur（保证采样在有效范围内）
    float4 color = float4(0.0);
    float totalWeight = 0.0;

    // 中心采样（最高权重）
    color += inputTexture.read(uint2(clamp(srcPos.x, 0, width-1), clamp(srcPos.y, 0, height-1))) * 4.0;
    totalWeight += 4.0;

    // 2x2 邻居（次高权重）
    color += inputTexture.read(uint2(clamp(srcPos.x + 1, 0, width-1), clamp(srcPos.y, 0, height-1))) * 2.0;
    color += inputTexture.read(uint2(clamp(srcPos.x, 0, width-1), clamp(srcPos.y + 1, 0, height-1))) * 2.0;
    color += inputTexture.read(uint2(clamp(srcPos.x + 1, 0, width-1), clamp(srcPos.y + 1, 0, height-1))) * 2.0;
    totalWeight += 6.0;

    // 对角线采样（低权重，扩散模糊）
    color += inputTexture.read(uint2(clamp(srcPos.x - 1, 0, width-1), clamp(srcPos.y - 1, 0, height-1))) * 1.0;
    color += inputTexture.read(uint2(clamp(srcPos.x + 2, 0, width-1), clamp(srcPos.y - 1, 0, height-1))) * 1.0;
    color += inputTexture.read(uint2(clamp(srcPos.x - 1, 0, width-1), clamp(srcPos.y + 2, 0, height-1))) * 1.0;
    color += inputTexture.read(uint2(clamp(srcPos.x + 2, 0, width-1), clamp(srcPos.y + 2, 0, height-1))) * 1.0;
    totalWeight += 4.0;

    // 十字扩展采样（更低权重，进一步扩散）
    color += inputTexture.read(uint2(clamp(srcPos.x, 0, width-1), clamp(srcPos.y - 1, 0, height-1))) * 0.5;
    color += inputTexture.read(uint2(clamp(srcPos.x, 0, width-1), clamp(srcPos.y + 2, 0, height-1))) * 0.5;
    color += inputTexture.read(uint2(clamp(srcPos.x - 1, 0, width-1), clamp(srcPos.y, 0, height-1))) * 0.5;
    color += inputTexture.read(uint2(clamp(srcPos.x + 2, 0, width-1), clamp(srcPos.y, 0, height-1))) * 0.5;
    totalWeight += 2.0;

    color /= totalWeight;
    outputTexture.write(color, gid);
}

// ========== Upsample Kernel (9-tap Tent Filter) ==========
// 上采样 + 真正的 Tent Filter（9 个采样点 + 加权混合）
kernel void upsample(
    texture2d<float, access::sample> inputTexture [[texture(0)]],
    texture2d<float, access::read> higherResTexture [[texture(1)]],  // 上一级更高分辨率纹理
    texture2d<float, access::write> outputTexture [[texture(2)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) {
        return;
    }

    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear, address::clamp_to_edge);

    // 计算归一化纹理坐标
    float2 outputSize = float2(outputTexture.get_width(), outputTexture.get_height());
    float2 inputSize = float2(inputTexture.get_width(), inputTexture.get_height());
    float2 uv = (float2(gid) + 0.5) / outputSize;

    // 9-tap Tent Filter（采样 3×3 区域）
    float2 texelSize = 1.0 / inputSize;
    float4 color = float4(0.0);

    // 中心（最高权重）
    color += inputTexture.sample(textureSampler, uv) * 4.0;

    // 四周（中等权重）
    color += inputTexture.sample(textureSampler, uv + float2(-texelSize.x, 0.0)) * 2.0;
    color += inputTexture.sample(textureSampler, uv + float2(texelSize.x, 0.0)) * 2.0;
    color += inputTexture.sample(textureSampler, uv + float2(0.0, -texelSize.y)) * 2.0;
    color += inputTexture.sample(textureSampler, uv + float2(0.0, texelSize.y)) * 2.0;

    // 对角线（低权重）
    color += inputTexture.sample(textureSampler, uv + float2(-texelSize.x, -texelSize.y)) * 1.0;
    color += inputTexture.sample(textureSampler, uv + float2(texelSize.x, -texelSize.y)) * 1.0;
    color += inputTexture.sample(textureSampler, uv + float2(-texelSize.x, texelSize.y)) * 1.0;
    color += inputTexture.sample(textureSampler, uv + float2(texelSize.x, texelSize.y)) * 1.0;

    float4 upsampledColor = color / 16.0;

    // 与上一级更高分辨率纹理混合（加权混合，不是简单相加）
    float4 higherResColor = higherResTexture.read(gid);

    // 混合权重：0.6 低分辨率（模糊）+ 1.0 高分辨率（细节）
    // 这样可以保留细节同时添加平滑的光晕
    float4 blended = upsampledColor * 0.6 + higherResColor * 1.0;

    outputTexture.write(blended, gid);
}

// ========== Final Blend Kernel ==========
// 将 Bloom 纹理与原始渲染混合
kernel void blend_bloom(
    texture2d<float, access::read> originalTexture [[texture(0)]],
    texture2d<float, access::read> bloomTexture [[texture(1)]],
    texture2d<float, access::write> outputTexture [[texture(2)]],
    constant float& bloomStrength [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) {
        return;
    }

    float4 original = originalTexture.read(gid);
    float4 bloom = bloomTexture.read(gid);

    // Additive Blending（加法混合）
    float4 result = original + bloom * bloomStrength;

    outputTexture.write(result, gid);
}

// ========== Gaussian Blur Kernel (备用方案) ==========
// 如果 Kawase 效果不够好，可以使用传统高斯模糊
kernel void gaussian_blur_horizontal(
    texture2d<float, access::read> inputTexture [[texture(0)]],
    texture2d<float, access::write> outputTexture [[texture(1)]],
    constant float* weights [[buffer(0)]],
    constant int& radius [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) {
        return;
    }

    float4 color = float4(0.0);
    float weightSum = 0.0;

    for (int i = -radius; i <= radius; i++) {
        int x = int(gid.x) + i;
        if (x >= 0 && x < int(inputTexture.get_width())) {
            float weight = weights[abs(i)];
            color += inputTexture.read(uint2(x, gid.y)) * weight;
            weightSum += weight;
        }
    }

    outputTexture.write(color / weightSum, gid);
}

kernel void gaussian_blur_vertical(
    texture2d<float, access::read> inputTexture [[texture(0)]],
    texture2d<float, access::write> outputTexture [[texture(1)]],
    constant float* weights [[buffer(0)]],
    constant int& radius [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) {
        return;
    }

    float4 color = float4(0.0);
    float weightSum = 0.0;

    for (int i = -radius; i <= radius; i++) {
        int y = int(gid.y) + i;
        if (y >= 0 && y < int(inputTexture.get_height())) {
            float weight = weights[abs(i)];
            color += inputTexture.read(uint2(gid.x, y)) * weight;
            weightSum += weight;
        }
    }

    outputTexture.write(color / weightSum, gid);
}
