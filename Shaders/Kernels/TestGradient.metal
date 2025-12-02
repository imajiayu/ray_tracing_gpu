// TestGradient.metal
// 测试着色器：渲染简单渐变

#include <metal_stdlib>
using namespace metal;

kernel void test_gradient(
    texture2d<float, access::write> output [[texture(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint width = output.get_width();
    uint height = output.get_height();

    if (gid.x >= width || gid.y >= height) {
        return;
    }

    // 归一化坐标 [0, 1]
    float u = float(gid.x) / float(width);
    float v = float(gid.y) / float(height);

    // 渐变颜色：左下蓝色 → 右上白色
    float3 color = float3(u, v, 0.5f);

    output.write(float4(color, 1.0f), gid);
}
