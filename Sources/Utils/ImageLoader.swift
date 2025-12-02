// ImageLoader.swift
// 图片纹理加载工具

import Metal
import MetalKit
import Foundation

/// 图片加载器
/// 使用 MTKTextureLoader 加载图片并转换为 Metal 纹理
class ImageLoader {
    private let device: MTLDevice
    private let textureLoader: MTKTextureLoader

    init(device: MTLDevice) {
        self.device = device
        self.textureLoader = MTKTextureLoader(device: device)
    }

    /// 从文件路径加载图片纹理
    /// - Parameter path: 图片文件路径
    /// - Parameter silent: 是否静默模式（不打印错误）
    /// - Returns: Metal 纹理对象，如果加载失败返回 nil
    func loadTexture(from path: String, silent: Bool = false) -> MTLTexture? {
        let url = URL(fileURLWithPath: path)

        // 配置纹理加载选项
        let options: [MTKTextureLoader.Option: Any] = [
            .textureUsage: MTLTextureUsage.shaderRead.rawValue,
            .textureStorageMode: MTLStorageMode.shared.rawValue,
            .SRGB: false  // 使用线性颜色空间（与 ray tracing 一致）
        ]

        do {
            let texture = try textureLoader.newTexture(URL: url, options: options)
            print("[ImageLoader] ✓ Loaded texture: \(path) (\(texture.width)×\(texture.height))")
            return texture
        } catch {
            if !silent {
                print("[ImageLoader] ❌ Failed to load texture from \(path): \(error)")
            }
            return nil
        }
    }

    /// 搜索图片文件（类似 CPU 版本的搜索逻辑）
    /// - Parameter filename: 图片文件名
    /// - Returns: Metal 纹理对象，如果加载失败返回 nil
    func loadTextureSearching(filename: String) -> MTLTexture? {
        // 搜索路径列表（类似 CPU 版本）
        let searchPaths = [
            filename,
            "Resources/images/\(filename)",
            "images/\(filename)",
            "../images/\(filename)",
            "../../images/\(filename)",
            "../../../images/\(filename)"
        ]

        // 依次尝试每个路径（静默模式，只在找到时打印）
        for path in searchPaths {
            if let texture = loadTexture(from: path, silent: true) {
                return texture
            }
        }

        print("[ImageLoader] ❌ Could not find image file '\(filename)' in any search path")
        return nil
    }
}
