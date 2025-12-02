// MetalContext.swift
// Metal 设备管理

import Metal
import MetalKit

class MetalContext {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue

    // MARK: - 初始化

    init?() {
        // 获取默认 Metal 设备
        guard let device = MTLCreateSystemDefaultDevice() else {
            print("[Metal] ❌ Failed to create Metal device")
            return nil
        }

        guard let commandQueue = device.makeCommandQueue() else {
            print("[Metal] ❌ Failed to create command queue")
            return nil
        }

        self.device = device
        self.commandQueue = commandQueue

        print("[Metal] ✓ Device: \(device.name)")
    }

    // MARK: - 着色器库

    /// 创建默认着色器库
    func makeDefaultLibrary() -> MTLLibrary? {
        return device.makeDefaultLibrary()
    }

    // MARK: - 计算管线

    /// 创建计算管线状态
    func makeComputePipeline(functionName: String, library: MTLLibrary) -> MTLComputePipelineState? {
        guard let function = library.makeFunction(name: functionName) else {
            print("[Metal] ❌ Failed to find function: \(functionName)")
            return nil
        }

        do {
            let pipeline = try device.makeComputePipelineState(function: function)
            print("[Metal] ✓ Pipeline created: \(functionName)")
            return pipeline
        } catch {
            print("[Metal] ❌ Failed to create pipeline: \(error)")
            return nil
        }
    }

    // MARK: - 纹理

    /// 创建纹理
    func makeTexture(width: Int, height: Int, pixelFormat: MTLPixelFormat = .rgba32Float) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor()
        descriptor.pixelFormat = pixelFormat
        descriptor.width = width
        descriptor.height = height
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .shared

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            print("[Metal] ❌ Failed to create texture (\(width)×\(height))")
            return nil
        }

        return texture
    }

    // MARK: - 缓冲区

    /// 创建缓冲区（从数组）
    func makeBuffer<T>(array: [T]) -> MTLBuffer? {
        guard !array.isEmpty else {
            print("[Metal] ⚠️ Cannot create buffer from empty array")
            return nil
        }

        let size = MemoryLayout<T>.stride * array.count
        guard let buffer = device.makeBuffer(bytes: array, length: size, options: .storageModeShared) else {
            print("[Metal] ❌ Failed to create buffer (size: \(size) bytes)")
            return nil
        }

        return buffer
    }

    /// 创建缓冲区（指定大小）
    func makeBuffer(length: Int) -> MTLBuffer? {
        guard length > 0 else {
            print("[Metal] ⚠️ Cannot create buffer with zero length")
            return nil
        }

        guard let buffer = device.makeBuffer(length: length, options: .storageModeShared) else {
            print("[Metal] ❌ Failed to create buffer (length: \(length) bytes)")
            return nil
        }

        return buffer
    }

    // MARK: - 命令执行

    /// 创建命令缓冲区
    func makeCommandBuffer() -> MTLCommandBuffer? {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            print("[Metal] ❌ Failed to create command buffer")
            return nil
        }
        return commandBuffer
    }
}
