// Blit.metal
// 使用渲染管线将 RGBA32Float 纹理显示到屏幕
//
// Phase 6 - Window Mode - 标准渲染管线
// Phase 7 - ACES Tone Mapping

#include <metal_stdlib>
using namespace metal;

// ACES Filmic Tone Mapping (Narkowicz 2015)
// 参考: https://knarkowicz.wordpress.com/2016/01/06/aces-filmic-tone-mapping-curve/
inline float3 aces_tonemap(float3 x) {
    const float a = 2.51f;
    const float b = 0.03f;
    const float c = 2.43f;
    const float d = 0.59f;
    const float e = 0.14f;
    return saturate((x * (a * x + b)) / (x * (c * x + d) + e));
}

// 顶点着色器输入（全屏四边形）
struct VertexIn {
    float2 position [[attribute(0)]];
    float2 texCoord [[attribute(1)]];
};

// 顶点着色器输出
struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

// 顶点着色器：全屏四边形
vertex VertexOut blitVertex(
    uint vertexID [[vertex_id]])
{
    // 生成全屏四边形的顶点
    // Triangle strip: 0--2
    //                 |\ |
    //                 | \|
    //                 1--3

    float2 positions[4] = {
        float2(-1.0, -1.0),  // 左下
        float2(-1.0,  1.0),  // 左上
        float2( 1.0, -1.0),  // 右下
        float2( 1.0,  1.0)   // 右上
    };

    float2 texCoords[4] = {
        float2(0.0, 1.0),  // 左下（Metal 纹理坐标原点在左上）
        float2(0.0, 0.0),  // 左上
        float2(1.0, 1.0),  // 右下
        float2(1.0, 0.0)   // 右上
    };

    VertexOut out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    out.texCoord = texCoords[vertexID];
    return out;
}

// 片段着色器：采样 RGBA32Float 纹理并转换到 BGRA8Unorm
fragment half4 blitFragment(
    VertexOut in [[stage_in]],
    texture2d<float> srcTexture [[texture(0)]],
    constant float& sampleCount [[buffer(0)]],
    constant int& tonemapMode [[buffer(1)]])
{
    // 采样输入纹理（RGBA32Float）
    constexpr sampler textureSampler(mag_filter::nearest, min_filter::nearest);
    float4 accumulated = srcTexture.sample(textureSampler, in.texCoord);

    // 平均（除以采样数）
    float3 color = accumulated.rgb / sampleCount;

    // NaN 检测和替换
    if (color.r != color.r) color.r = 0.0f;
    if (color.g != color.g) color.g = 0.0f;
    if (color.b != color.b) color.b = 0.0f;

    // Tone Mapping (HDR → LDR)
    if (tonemapMode == 1) {
        // ACES Filmic Tone Mapping
        color = aces_tonemap(color);
    } else {
        // 硬截断（向后兼容）
        color = clamp(color, 0.0f, 1.0f);
    }

    // Gamma 校正 (gamma = 2.0)
    color = sqrt(max(color, 0.0f));

    // 返回 RGBA（Metal 自动转换为 BGRA8Unorm）
    return half4(half3(color), 1.0h);
}
