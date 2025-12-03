// ColorConversion.metal
// Convert float RGBA buffer to BGRA8 texture for display
//
// ⚠️ Phase 5 - Window Mode (预留代码)
// 此文件将在 Phase 5 实现窗口模式时启用
// 当前版本仅支持离线图片渲染模式

#include <metal_stdlib>
using namespace metal;

kernel void rgb_to_bgra8(
    constant float* rgba_buffer [[buffer(0)]],
    constant uint& spp [[buffer(1)]],
    texture2d<half, access::write> output_texture [[texture(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    uint width = output_texture.get_width();
    uint height = output_texture.get_height();

    if (gid.x >= width || gid.y >= height) {
        return;
    }

    uint pixel_index = gid.y * width + gid.x;
    uint rgba_index = pixel_index * 4;

    // Read accumulated RGBA values (renderer outputs RGBA, we only need RGB)
    float r = rgba_buffer[rgba_index + 0];
    float g = rgba_buffer[rgba_index + 1];
    float b = rgba_buffer[rgba_index + 2];

    // Average by samples per pixel
    r /= float(spp);
    g /= float(spp);
    b /= float(spp);

    // Replace NaN components with zero (防止 Surface Acne)
    // NaN 检测: NaN != NaN
    if (r != r) r = 0.0f;
    if (g != g) g = 0.0f;
    if (b != b) b = 0.0f;

    // Gamma correction (gamma = 2.0)
    r = sqrt(max(0.0f, r));
    g = sqrt(max(0.0f, g));
    b = sqrt(max(0.0f, b));

    // Clamp to [0, 1]
    r = clamp(r, 0.0f, 1.0f);
    g = clamp(g, 0.0f, 1.0f);
    b = clamp(b, 0.0f, 1.0f);

    // Write as RGBA (Metal will handle byte order)
    half4 color = half4(half(r), half(g), half(b), 1.0h);
    output_texture.write(color, gid);
}
