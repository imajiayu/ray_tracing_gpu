// HUD.metal
// HUD 叠加渲染着色器
//
// 在场景渲染结果上叠加半透明的 HUD

#include <metal_stdlib>
using namespace metal;

// HUD 参数
struct HUDParams {
    float2 position;        // HUD 左上角位置（像素坐标）
    float2 size;            // HUD 尺寸（像素坐标）
    float2 viewport_size;   // 视口尺寸
};

// 顶点着色器输出
struct HUDVertexOut {
    float4 position [[position]];
    float2 tex_coord;
};

/// HUD 顶点着色器 - 生成左上角的四边形
vertex HUDVertexOut hudVertex(uint vid [[vertex_id]],
                              constant HUDParams& params [[buffer(0)]]) {
    // 生成四边形顶点（左上角为原点，Metal 坐标系 Y 向下）
    // 顶点顺序：左下 → 右下 → 左上 → 右上（triangle strip）
    float2 positions[4] = {
        float2(0, 1),  // 左下
        float2(1, 1),  // 右下
        float2(0, 0),  // 左上
        float2(1, 0)   // 右上
    };

    float2 local_pos = positions[vid];

    // 计算屏幕像素坐标
    float2 pixel_pos = params.position + local_pos * params.size;

    // 转换为 NDC 坐标（Metal NDC: [-1, 1]，Y 向上）
    float2 ndc;
    ndc.x = (pixel_pos.x / params.viewport_size.x) * 2.0 - 1.0;
    ndc.y = 1.0 - (pixel_pos.y / params.viewport_size.y) * 2.0;  // Y 翻转

    HUDVertexOut out;
    out.position = float4(ndc, 0.0, 1.0);
    out.tex_coord = local_pos;  // UV 坐标（左上 = (0,0)，右下 = (1,1)）

    return out;
}

/// HUD 片段着色器 - 从 HUD 纹理采样并输出
fragment float4 hudFragment(HUDVertexOut in [[stage_in]],
                            texture2d<float> hud_texture [[texture(0)]]) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);

    // 从 HUD 纹理采样（已经是 premultiplied alpha）
    float4 color = hud_texture.sample(s, in.tex_coord);

    return color;
}
