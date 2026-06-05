// AdaptiveSampling.metal
// 自适应采样相关内核函数

#include <metal_stdlib>
#include "../Common/Types.metal"
using namespace metal;

// ========== 辅助函数 ==========

/// 计算像素的感知亮度（用于自适应阈值）
inline float luminance(float3 color) {
    return 0.299f * color.r + 0.587f * color.g + 0.114f * color.b;
}

// ========== 核心内核 ==========

/// 计算像素方差并判断收敛
kernel void compute_variance(
    device const float4* color_sum [[buffer(0)]],           // 颜色累积
    device const float4* color_sum_squared [[buffer(1)]],   // 颜色平方累积
    device const uint* sample_count [[buffer(2)]],          // 采样计数
    device float* variance [[buffer(3)]],                   // 输出方差
    device uint* converged_flags [[buffer(4)]],             // 输出收敛标志
    constant AdaptiveSamplingParams& params [[buffer(5)]],  // 参数
    uint2 gid [[thread_position_in_grid]]
) {
    // 边界检查
    if (gid.x >= params.width || gid.y >= params.height) return;

    uint pixel_idx = gid.y * params.width + gid.x;
    uint N = sample_count[pixel_idx];

    // 至少需要 min_samples 才计算方差
    if (N < params.min_samples) return;

    // 优化：如果像素已收敛，跳过方差计算（已收敛像素的方差不再变化）
    // 注意：第一次计算时 converged_flags 可能未初始化，需要检查
    if (converged_flags[pixel_idx] == 1) {
        // 已收敛，保持之前的方差值不变（如果已计算过）
        // 如果 variance[pixel_idx] 还未计算，这里会保持为0，但不影响收敛判断
        return;
    }

    // 计算均值
    float3 sum = color_sum[pixel_idx].rgb;
    float3 mean = sum / float(N);

    // 计算方差: Var[X] = E[X²] - E[X]²
    float3 sum_squared = color_sum_squared[pixel_idx].rgb;
    float3 mean_squared = sum_squared / float(N);
    float3 var = mean_squared - mean * mean;

    // 批量采样方差校正：
    // 我们累积的是 batch 平均值，其方差约为 σ²/batch_size
    // 需要乘以 batch_size 来估计真实的每样本方差
    // 由于我们累积的是 batch_avg²  * spp 而不是 Σ(sample_i²)，
    // 需要额外的经验校正因子（路径追踪通常有很高的样本方差）
    var *= float(params.adaptive_batch_size * params.adaptive_batch_size);

    // 取 RGB 三通道最大方差（保守估计）
    float pixel_var = max(var.r, max(var.g, var.b));

    // 防止负方差（数值误差）
    pixel_var = max(0.0f, pixel_var);

    variance[pixel_idx] = pixel_var;

    // 自适应阈值（相对误差）
    float lum = luminance(mean);
    float adaptive_threshold = (params.adaptive_relative_threshold * lum);
    adaptive_threshold = adaptive_threshold * adaptive_threshold;  // 方差是误差的平方

    // 使用固定阈值和自适应阈值的最大值
    float final_threshold = max(params.variance_threshold, adaptive_threshold);

    // 判断收敛（仅基于方差阈值，不再有最大采样数限制）
    if (pixel_var < final_threshold && N >= params.min_samples) {
        converged_flags[pixel_idx] = 1;
    }
}

/// 计算材质加权方差并判断收敛（基于颜色特征估计材质类型）
/// 这是AOV的简化版本，不需要修改raytrace kernel
kernel void compute_variance_weighted(
    device const float4* color_sum [[buffer(0)]],
    device const float4* color_sum_squared [[buffer(1)]],
    device const uint* sample_count [[buffer(2)]],
    device float* variance [[buffer(3)]],
    device uint* converged_flags [[buffer(4)]],
    constant AdaptiveSamplingParams& params [[buffer(5)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= params.width || gid.y >= params.height) return;

    uint pixel_idx = gid.y * params.width + gid.x;
    uint N = sample_count[pixel_idx];

    if (N < params.min_samples) return;

    if (converged_flags[pixel_idx] == 1) {
        return;
    }

    // 计算均值和方差
    float3 sum = color_sum[pixel_idx].rgb;
    float3 mean = sum / float(N);

    float3 sum_squared = color_sum_squared[pixel_idx].rgb;
    float3 mean_squared = sum_squared / float(N);
    float3 var = mean_squared - mean * mean;

    var *= float(params.adaptive_batch_size * params.adaptive_batch_size);

    float pixel_var = max(var.r, max(var.g, var.b));
    pixel_var = max(0.0f, pixel_var);

    variance[pixel_idx] = pixel_var;

    // === 材质类型估计（基于颜色特征） ===

    // 计算亮度和饱和度
    float brightness = max(mean.r, max(mean.g, mean.b));
    float min_channel = min(mean.r, min(mean.g, mean.b));
    float saturation = (brightness - min_channel) / (brightness + 0.001f);

    // 材质类型权重
    float material_weight = 1.0f;

    // 判断1: 高亮低饱和度 = Specular/Glass (镜面反射/玻璃)
    // 特征：brightness > 0.7 且 saturation < 0.3
    if (brightness > 0.7f && saturation < 0.3f) {
        material_weight = 4.0f;  // 镜面/玻璃需要4倍采样
    }
    // 判断2: 中等亮度低饱和度 = Metal (金属)
    // 特征：0.3 < brightness < 0.7 且 saturation < 0.2
    else if (brightness > 0.3f && brightness <= 0.7f && saturation < 0.2f) {
        material_weight = 3.0f;  // 金属需要3倍采样
    }
    // 判断3: 高饱和度高亮度 = 镜面高光
    // 特征：brightness > 0.8 且 saturation > 0.5
    else if (brightness > 0.8f && saturation > 0.5f) {
        material_weight = 2.5f;  // 彩色高光需要2.5倍采样
    }
    // 判断4: 极低亮度 = 阴影区域（可能有噪点）
    // 特征：brightness < 0.1
    else if (brightness < 0.1f) {
        material_weight = 2.0f;  // 阴影需要2倍采样
    }
    // 其他: Diffuse (漫反射)
    // 默认 weight = 1.0

    // 应用材质权重到阈值（更高的权重 = 更严格的阈值）
    // 相当于要求这些像素的方差更低才能收敛
    float weighted_variance_threshold = params.variance_threshold / material_weight;

    // 自适应阈值
    float lum = luminance(mean);
    float adaptive_threshold = (params.adaptive_relative_threshold * lum);
    adaptive_threshold = adaptive_threshold * adaptive_threshold;
    adaptive_threshold = adaptive_threshold / material_weight;

    float final_threshold = max(weighted_variance_threshold, adaptive_threshold);

    // 判断收敛
    if (pixel_var < final_threshold && N >= params.min_samples) {
        converged_flags[pixel_idx] = 1;
    }
}

/// 计算AOV多通道方差并判断收敛（使用最大通道方差）
kernel void compute_variance_aov(
    device const float4* diffuse_sum [[buffer(0)]],
    device const float4* diffuse_sum_sq [[buffer(1)]],
    device const float4* specular_sum [[buffer(2)]],
    device const float4* specular_sum_sq [[buffer(3)]],
    device const float4* transmission_sum [[buffer(4)]],
    device const float4* transmission_sum_sq [[buffer(5)]],
    device const uint* sample_count [[buffer(6)]],
    device float* variance [[buffer(7)]],                       // 输出：最大通道方差
    device uint* converged_flags [[buffer(8)]],
    constant AdaptiveSamplingParams& params [[buffer(9)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= params.width || gid.y >= params.height) return;

    uint pixel_idx = gid.y * params.width + gid.x;
    uint N = sample_count[pixel_idx];

    if (N < params.min_samples) return;

    if (converged_flags[pixel_idx] == 1) {
        return;  // 已收敛
    }

    float max_variance = 0.0f;

    // 计算各通道方差
    for (int channel = 0; channel < 3; ++channel) {
        device const float4* sums[3] = {diffuse_sum, specular_sum, transmission_sum};
        device const float4* sums_sq[3] = {diffuse_sum_sq, specular_sum_sq, transmission_sum_sq};

        float3 mean = sums[channel][pixel_idx].rgb / float(N);
        float3 mean_sq = sums_sq[channel][pixel_idx].rgb / float(N);
        float3 var = mean_sq - mean * mean;

        // 批量采样校正
        var *= float(params.adaptive_batch_size * params.adaptive_batch_size);

        // 取RGB最大方差
        float channel_var = max(var.r, max(var.g, var.b));
        channel_var = max(0.0f, channel_var);

        // 根据通道类型加权
        // Specular和Transmission通常噪声更大，需要更多采样
        float weight = 1.0f;
        if (channel == 1 || channel == 2) {  // specular或transmission
            weight = 2.0f;  // 这些通道的方差权重更高
        }

        max_variance = max(max_variance, channel_var * weight);
    }

    variance[pixel_idx] = max_variance;

    // 使用最大通道方差判断收敛
    // 自适应阈值
    float3 beauty_mean = (diffuse_sum[pixel_idx] + specular_sum[pixel_idx] + transmission_sum[pixel_idx]).rgb / float(N);
    float lum = luminance(beauty_mean);
    float adaptive_threshold = (params.adaptive_relative_threshold * lum);
    adaptive_threshold = adaptive_threshold * adaptive_threshold;

    float final_threshold = max(params.variance_threshold, adaptive_threshold);

    if (max_variance < final_threshold && N >= params.min_samples) {
        converged_flags[pixel_idx] = 1;
    }
}

/// 累积新采样到自适应缓冲区（批量采样版本）
kernel void accumulate_samples(
    texture2d<float, access::read> new_samples [[texture(0)]],   // 新渲染的采样
    device float4* color_sum [[buffer(0)]],                      // 颜色累积
    device float4* color_sum_squared [[buffer(1)]],              // 颜色平方累积
    device atomic_uint* sample_count [[buffer(2)]],              // 采样计数（原子）
    device const uint* pixel_mask [[buffer(3)]],                 // 像素掩码（可选，null = 所有像素）
    constant uint& spp [[buffer(4)]],                            // 本批次采样数
    uint2 gid [[thread_position_in_grid]]
) {
    uint width = new_samples.get_width();
    uint pixel_idx = gid.y * width + gid.x;

    // 检查像素掩码（如果存在）
    if (pixel_mask != nullptr && pixel_mask[pixel_idx] == 0) {
        return;
    }

    // 读取新采样（这是 spp 个采样的平均值）
    float4 new_color_avg = new_samples.read(gid);

    // 累积颜色总和
    // 将平均值乘以 spp 得到总和
    color_sum[pixel_idx] += new_color_avg * float(spp);

    // 累积颜色平方（用于方差计算）
    // 使用 batch 平均值的平方作为方差估计
    float4 squared = new_color_avg * new_color_avg * float(spp);
    color_sum_squared[pixel_idx] += squared;

    // 原子递增采样计数
    atomic_fetch_add_explicit(&sample_count[pixel_idx], spp, memory_order_relaxed);
}

/// 累积新采样到自适应缓冲区（AOV多通道版本）
kernel void accumulate_samples_aov(
    texture2d<float, access::read> beauty [[texture(0)]],        // Beauty（所有通道之和）
    texture2d<float, access::read> diffuse [[texture(1)]],       // Diffuse通道
    texture2d<float, access::read> specular [[texture(2)]],      // Specular通道
    texture2d<float, access::read> transmission [[texture(3)]],  // Transmission通道
    texture2d<float, access::read> emission [[texture(4)]],      // Emission通道
    device float4* beauty_sum [[buffer(0)]],                     // Beauty累积
    device float4* beauty_sum_sq [[buffer(1)]],                  // Beauty平方累积
    device float4* diffuse_sum [[buffer(2)]],                    // Diffuse累积
    device float4* diffuse_sum_sq [[buffer(3)]],                 // Diffuse平方累积
    device float4* specular_sum [[buffer(4)]],                   // Specular累积
    device float4* specular_sum_sq [[buffer(5)]],                // Specular平方累积
    device float4* transmission_sum [[buffer(6)]],               // Transmission累积
    device float4* transmission_sum_sq [[buffer(7)]],            // Transmission平方累积
    device float4* emission_sum [[buffer(8)]],                   // Emission累积
    device float4* emission_sum_sq [[buffer(9)]],                // Emission平方累积
    device atomic_uint* sample_count [[buffer(10)]],             // 采样计数
    device const uint* pixel_mask [[buffer(11)]],                // 像素掩码
    constant uint& spp [[buffer(12)]],                           // 本批次采样数
    uint2 gid [[thread_position_in_grid]]
) {
    uint width = beauty.get_width();
    uint pixel_idx = gid.y * width + gid.x;

    // 检查像素掩码
    if (pixel_mask != nullptr && pixel_mask[pixel_idx] == 0) {
        return;
    }

    // 读取各通道采样
    float4 beauty_val = beauty.read(gid);
    float4 diffuse_val = diffuse.read(gid);
    float4 specular_val = specular.read(gid);
    float4 transmission_val = transmission.read(gid);
    float4 emission_val = emission.read(gid);

    // 累积各通道
    beauty_sum[pixel_idx] += beauty_val * float(spp);
    beauty_sum_sq[pixel_idx] += beauty_val * beauty_val * float(spp);

    diffuse_sum[pixel_idx] += diffuse_val * float(spp);
    diffuse_sum_sq[pixel_idx] += diffuse_val * diffuse_val * float(spp);

    specular_sum[pixel_idx] += specular_val * float(spp);
    specular_sum_sq[pixel_idx] += specular_val * specular_val * float(spp);

    transmission_sum[pixel_idx] += transmission_val * float(spp);
    transmission_sum_sq[pixel_idx] += transmission_val * transmission_val * float(spp);

    emission_sum[pixel_idx] += emission_val * float(spp);
    emission_sum_sq[pixel_idx] += emission_val * emission_val * float(spp);

    // 原子递增采样计数
    atomic_fetch_add_explicit(&sample_count[pixel_idx], spp, memory_order_relaxed);
}

/// 压缩未收敛像素列表（Stream Compaction）
kernel void compact_unconverged_pixels(
    device const uint* converged_flags [[buffer(0)]],
    device uint* unconverged_list [[buffer(1)]],        // 输出：未收敛像素索引
    device atomic_uint* unconverged_counter [[buffer(2)]],  // 输出计数
    constant uint& total_pixels [[buffer(3)]],
    uint gid [[thread_position_in_grid]]
) {
    if (gid >= total_pixels) return;

    // 如果未收敛，加入列表
    if (converged_flags[gid] == 0) {
        uint idx = atomic_fetch_add_explicit(unconverged_counter, 1, memory_order_relaxed);
        unconverged_list[idx] = gid;
    }
}

/// 读取最终像素颜色（从累积缓冲区）
kernel void read_final_pixels(
    device const float4* color_sum [[buffer(0)]],       // 颜色累积
    device const uint* sample_count [[buffer(1)]],      // 采样计数
    device float* output_pixels [[buffer(2)]],          // 输出：RGBA 数组
    constant uint& width [[buffer(3)]],
    constant uint& height [[buffer(4)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= width || gid.y >= height) return;

    uint pixel_idx = gid.y * width + gid.x;
    uint N = sample_count[pixel_idx];

    // 计算平均颜色
    float3 color = (N > 0) ? (color_sum[pixel_idx].rgb / float(N)) : float3(0.0f);

    // 写入到输出数组（RGBA 连续存储，A 通道固定为 1.0）
    uint out_idx = pixel_idx * 4;
    output_pixels[out_idx + 0] = color.r;
    output_pixels[out_idx + 1] = color.g;
    output_pixels[out_idx + 2] = color.b;
    output_pixels[out_idx + 3] = 1.0f;  // Alpha
}

/// 创建像素掩码（从未收敛像素列表）- GPU版本
kernel void create_pixel_mask(
    device const uint* unconverged_list [[buffer(0)]],  // 未收敛像素索引列表
    device uint* pixel_mask [[buffer(1)]],              // 输出：像素掩码（1=渲染, 0=跳过）
    constant uint& unconverged_count [[buffer(2)]],
    uint gid [[thread_position_in_grid]]
) {
    if (gid >= unconverged_count) return;

    uint pixel_idx = unconverged_list[gid];
    pixel_mask[pixel_idx] = 1;
}

/// 重置像素掩码（GPU版本，比CPU memset更高效）
kernel void reset_pixel_mask(
    device uint* pixel_mask [[buffer(0)]],
    constant uint& total_pixels [[buffer(1)]],
    uint gid [[thread_position_in_grid]]
) {
    if (gid >= total_pixels) return;
    pixel_mask[gid] = 0;
}

/// 初始化GPU缓冲区（清零colorSum和colorSumSquared）
kernel void initialize_buffers(
    device float4* color_sum [[buffer(0)]],
    device float4* color_sum_squared [[buffer(1)]],
    device atomic_uint* sample_count [[buffer(2)]],
    constant uint& total_pixels [[buffer(3)]],
    uint gid [[thread_position_in_grid]]
) {
    if (gid >= total_pixels) return;
    
    color_sum[gid] = float4(0.0f);
    color_sum_squared[gid] = float4(0.0f);
    atomic_store_explicit(&sample_count[gid], 0, memory_order_relaxed);
}
