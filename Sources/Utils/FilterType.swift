// FilterType.swift
// 像素重建滤波器类型

import Foundation

/// 像素重建滤波器类型
enum FilterType: String, CaseIterable {
    case box = "box"           // 均匀平均（当前方法）
    case tent = "tent"         // 三角形/锥形滤波器
    case gaussian = "gaussian" // 高斯滤波器
    case mitchell = "mitchell" // Mitchell-Netravali 滤波器
    case lanczos = "lanczos"   // Lanczos sinc 滤波器
    
    var description: String {
        switch self {
        case .box:      return "Box (uniform averaging)"
        case .tent:     return "Tent (triangle/cone)"
        case .gaussian: return "Gaussian (smooth)"
        case .mitchell: return "Mitchell-Netravali (balanced)"
        case .lanczos:  return "Lanczos (high quality)"
        }
    }
    
    var gpuValue: UInt32 {
        switch self {
        case .box:      return 0
        case .tent:     return 1
        case .gaussian: return 2
        case .mitchell: return 3
        case .lanczos:  return 4
        }
    }
}
