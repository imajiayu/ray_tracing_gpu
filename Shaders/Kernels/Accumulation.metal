// Accumulation.metal
// 累积渲染内核 - 用于实时窗口模式
//
// ⚠️ Phase 5 - Window Mode (预留代码)
// 此文件将在 Phase 5 实现窗口模式时启用
// 当前版本仅支持离线图片渲染模式

#include <metal_stdlib>
using namespace metal;

/// 累积渲染参数（必须与 Swift 端对齐）
struct AccumulationParams {
    uint is_first_frame;  // 0 或 1（UInt32 对齐）
    uint spp_per_frame;
    uint total_samples;
};

/// 累积内核 - 将新渲染帧累加到累积缓冲区
/// 输入：raytrace_realtime 输出的平均值（每帧 1 spp）
/// 输出：累积所有帧的累积值（未平均）
kernel void accumulate_kernel(
    texture2d<float, access::read> frame_texture [[texture(0)]],        // 新渲染的帧（平均值）
    texture2d<float, access::read_write> accumulation_texture [[texture(1)]], // 累积缓冲区
    constant AccumulationParams& params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    // 边界检查
    if (gid.x >= frame_texture.get_width() || gid.y >= frame_texture.get_height()) {
        return;
    }

    // 读取新渲染帧的颜色（raytrace_realtime输出的是平均值）
    float4 frame_color = frame_texture.read(gid);

    if (params.is_first_frame) {
        // 第一帧：写入累积缓冲区（乘以 spp，转换为累积值）
        accumulation_texture.write(frame_color * float(params.spp_per_frame), gid);
    } else {
        // 后续帧：累加到累积缓冲区
        float4 accumulated = accumulation_texture.read(gid);
        accumulated += frame_color * float(params.spp_per_frame);
        accumulation_texture.write(accumulated, gid);
    }
}

/// 重置累积缓冲区
kernel void reset_accumulation_kernel(
    texture2d<float, access::write> accumulation_texture [[texture(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    // 边界检查
    if (gid.x >= accumulation_texture.get_width() || gid.y >= accumulation_texture.get_height()) {
        return;
    }

    // 清零
    accumulation_texture.write(float4(0.0), gid);
}
