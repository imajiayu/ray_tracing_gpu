// Texture.swift
// 纹理系统 - Swift端定义

import simd

// MARK: - 纹理类型枚举

enum TextureType: UInt32 {
    case solidColor = 0
    case checker = 1
    case imageTexture = 2
    case noise = 3
}

// MARK: - 纹理协议（Swift端）

/// 纹理基类（仅用于Swift端类型系统）
/// GPU端使用tagged union方式存储
protocol TextureProtocol {
    func toGPU() -> GPUTexture
}

// MARK: - 纯色纹理

struct SolidColorTexture: TextureProtocol {
    var albedo: SIMD3<Float>

    init(albedo: SIMD3<Float>) {
        self.albedo = albedo
    }

    init(r: Float, g: Float, b: Float) {
        self.albedo = SIMD3<Float>(r, g, b)
    }

    func toGPU() -> GPUTexture {
        return GPUTexture(
            type: TextureType.solidColor.rawValue,
            padding1: SIMD3<UInt32>(0, 0, 0),
            albedo: albedo,
            invScale: 0,
            scale: 0,
            oddColor: SIMD3<Float>(0, 0, 0),
            imageIndex: -1,
            padding2: SIMD3<Float>(0, 0, 0)
        )
    }
}

// MARK: - 棋盘格纹理

struct CheckerTexture: TextureProtocol {
    var invScale: Float
    var evenColor: SIMD3<Float>
    var oddColor: SIMD3<Float>

    init(scale: Float, evenColor: SIMD3<Float>, oddColor: SIMD3<Float>) {
        self.invScale = 1.0 / scale
        self.evenColor = evenColor
        self.oddColor = oddColor
    }

    init(scale: Float, c1: SIMD3<Float>, c2: SIMD3<Float>) {
        self.init(scale: scale, evenColor: c1, oddColor: c2)
    }

    func toGPU() -> GPUTexture {
        return GPUTexture(
            type: TextureType.checker.rawValue,
            padding1: SIMD3<UInt32>(0, 0, 0),
            albedo: evenColor,
            invScale: invScale,
            scale: 0,
            oddColor: oddColor,
            imageIndex: -1,
            padding2: SIMD3<Float>(0, 0, 0)
        )
    }
}

// MARK: - 噪声纹理

struct NoiseTexture: TextureProtocol {
    var scale: Float

    init(scale: Float) {
        self.scale = scale
    }

    func toGPU() -> GPUTexture {
        return GPUTexture(
            type: TextureType.noise.rawValue,
            padding1: SIMD3<UInt32>(0, 0, 0),
            albedo: SIMD3<Float>(0.5, 0.5, 0.5),
            invScale: 0,
            scale: scale,
            oddColor: SIMD3<Float>(0, 0, 0),
            imageIndex: -1,
            padding2: SIMD3<Float>(0, 0, 0)
        )
    }
}

// MARK: - 图像纹理

import Metal
import MetalKit

struct ImageTexture: TextureProtocol {
    var imagePath: String
    var imageIndex: Int32  // 在Metal纹理数组中的索引

    init(path: String, index: Int32) {
        self.imagePath = path
        self.imageIndex = index
    }

    func toGPU() -> GPUTexture {
        return GPUTexture(
            type: TextureType.imageTexture.rawValue,
            padding1: SIMD3<UInt32>(0, 0, 0),
            albedo: SIMD3<Float>(0, 0, 0),  // 图片纹理不使用 albedo
            invScale: 0,
            scale: 0,
            oddColor: SIMD3<Float>(0, 0, 0),
            imageIndex: imageIndex,
            padding2: SIMD3<Float>(0, 0, 0)
        )
    }
}
