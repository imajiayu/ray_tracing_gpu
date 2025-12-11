// Filter.metal
// 像素重建滤波器实现

#ifndef FILTER_METAL
#define FILTER_METAL

#include <metal_stdlib>
#include "Types.metal"
using namespace metal;

// ========== 辅助函数 ==========

/// Sinc 函数: sin(pi * x) / (pi * x)
inline float sinc(float x) {
    if (abs(x) < 1e-5f) {
        return 1.0f;
    }
    float pix = M_PI_F * x;
    return sin(pix) / pix;
}

// ========== Box 滤波器 ==========

/// Box 滤波器（均匀平均，无加权）
/// 最简单，但会产生锯齿
inline float filter_box(float x, float y) {
    return 1.0f;
}

// ========== Tent 滤波器 ==========

/// Tent 滤波器（三角形/锥形滤波器）
/// 中心权重高，边缘权重低，线性衰减
/// weight(x, y) = (1 - |x|) * (1 - |y|)
inline float filter_tent(float x, float y) {
    return fmax(0.0f, 1.0f - abs(x)) * fmax(0.0f, 1.0f - abs(y));
}

// ========== Gaussian 滤波器 ==========

/// Gaussian 滤波器（高斯滤波器）
/// 平滑，自然
/// weight(x, y) = exp(-(x² + y²) / (2σ²))
/// σ = 0.5 (标准差)
inline float filter_gaussian(float x, float y) {
    const float sigma = 0.5f;
    const float sigma2 = sigma * sigma;
    float r2 = x * x + y * y;
    return exp(-r2 / (2.0f * sigma2));
}

// ========== Mitchell-Netravali 滤波器 ==========

/// Mitchell-Netravali 三次多项式滤波器
/// 平衡锐度和平滑，业界标准
/// B = 1/3, C = 1/3 (Mitchell 推荐参数)
inline float mitchell_1d(float x) {
    x = abs(x);
    const float B = 1.0f / 3.0f;
    const float C = 1.0f / 3.0f;
    
    if (x < 1.0f) {
        // 内部区域: (12 - 9B - 6C)|x|³ + (-18 + 12B + 6C)|x|² + (6 - 2B)
        return ((12.0f - 9.0f * B - 6.0f * C) * x * x * x +
                (-18.0f + 12.0f * B + 6.0f * C) * x * x +
                (6.0f - 2.0f * B)) / 6.0f;
    } else if (x < 2.0f) {
        // 外部区域: (-B - 6C)|x|³ + (6B + 30C)|x|² + (-12B - 48C)|x| + (8B + 24C)
        return ((-B - 6.0f * C) * x * x * x +
                (6.0f * B + 30.0f * C) * x * x +
                (-12.0f * B - 48.0f * C) * x +
                (8.0f * B + 24.0f * C)) / 6.0f;
    } else {
        return 0.0f;
    }
}

/// Mitchell-Netravali 2D 滤波器（可分离）
inline float filter_mitchell(float x, float y) {
    return mitchell_1d(x) * mitchell_1d(y);
}

// ========== Lanczos 滤波器 ==========

/// Lanczos 滤波器（windowed sinc 滤波器）
/// 最高质量，但计算量大
/// weight(x, y) = sinc(x) * sinc(x/a) * sinc(y) * sinc(y/a)
/// a = 2 (窗口大小)
inline float lanczos_1d(float x) {
    x = abs(x);
    const float a = 2.0f;  // 窗口大小
    
    if (x < a) {
        return sinc(x) * sinc(x / a);
    } else {
        return 0.0f;
    }
}

/// Lanczos 2D 滤波器（可分离）
inline float filter_lanczos(float x, float y) {
    return lanczos_1d(x) * lanczos_1d(y);
}

// ========== 统一接口 ==========

/// 评估滤波器权重
/// @param filter_type 滤波器类型 (0=box, 1=tent, 2=gaussian, 3=mitchell, 4=lanczos)
/// @param x 采样点到像素中心的 X 距离，范围 [-0.5, 0.5]
/// @param y 采样点到像素中心的 Y 距离，范围 [-0.5, 0.5]
/// @return 滤波器权重（非归一化）
inline float evaluate_filter(uint filter_type, float x, float y) {
    switch (filter_type) {
        case FILTER_BOX:
            return filter_box(x, y);
        case FILTER_TENT:
            return filter_tent(x, y);
        case FILTER_GAUSSIAN:
            return filter_gaussian(x, y);
        case FILTER_MITCHELL:
            return filter_mitchell(x, y);
        case FILTER_LANCZOS:
            return filter_lanczos(x, y);
        default:
            return 1.0f;  // Fallback to box
    }
}

#endif // FILTER_METAL
