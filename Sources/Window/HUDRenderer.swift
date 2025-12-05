// HUDRenderer.swift
// HUD 渲染器 - 在左上角显示透明的统计信息
//
// 参考 CPU 版本的 graphics_window.h 的 draw_stats() 实现
// 使用 CoreGraphics + CoreText 在 macOS 上渲染文本到 Metal 纹理

import MetalKit
import CoreGraphics
import CoreText
import simd

/// HUD 渲染器 - 使用 CoreGraphics 渲染文本，然后上传到 Metal 纹理
class HUDRenderer {
    let device: MTLDevice
    var hudTexture: MTLTexture?
    var hudPipeline: MTLRenderPipelineState!

    let hudWidth: Int = 210    // HUD 背景宽度（竖版，刚好容纳 Pos 行）
    let hudHeight: Int = 200   // HUD 背景高度（紧凑竖版布局，9行内容）

    init(device: MTLDevice, library: MTLLibrary) throws {
        self.device = device

        // 创建 HUD 渲染管线（用于叠加 HUD 到最终画面）
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = library.makeFunction(name: "hudVertex")
        pipelineDescriptor.fragmentFunction = library.makeFunction(name: "hudFragment")
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

        // 启用 alpha 混合（透明 HUD）
        pipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
        pipelineDescriptor.colorAttachments[0].rgbBlendOperation = .add
        pipelineDescriptor.colorAttachments[0].alphaBlendOperation = .add
        pipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        pipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        pipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        pipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        guard let pipeline = try? device.makeRenderPipelineState(descriptor: pipelineDescriptor) else {
            throw NSError(domain: "HUDRenderer", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to create HUD render pipeline"
            ])
        }
        self.hudPipeline = pipeline

        // 创建 HUD 纹理（BGRA8Unorm，用于显示）
        createHUDTexture()
    }

    /// 创建 HUD 纹理
    private func createHUDTexture() {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: hudWidth,
            height: hudHeight,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .managed  // 允许 CPU 写入

        hudTexture = device.makeTexture(descriptor: descriptor)
    }

    /// 更新 HUD 内容
    /// - Parameters:
    ///   - frameCount: 帧计数
    ///   - fps: 帧率
    ///   - frameTimeMs: 帧时间（毫秒）
    ///   - sampleCount: 累积采样数
    ///   - cameraConfig: 当前相机配置
    ///   - rollDegrees: 相机滚转角（暂未实现，传 0.0）
    func updateHUD(frameCount: Int, fps: Double, frameTimeMs: Double, sampleCount: Int, cameraConfig: CameraConfig, rollDegrees: Double = 0.0) {
        guard let texture = hudTexture else { return }

        // 创建位图上下文（BGRA8）
        let bytesPerPixel = 4
        let bytesPerRow = hudWidth * bytesPerPixel
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

        guard let context = CGContext(
            data: nil,
            width: hudWidth,
            height: hudHeight,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        ) else {
            return
        }

        // 清空背景（完全透明）
        context.clear(CGRect(x: 0, y: 0, width: hudWidth, height: hudHeight))

        // 绘制半透明背景矩形（黑色，78% 不透明度，参考 CPU 版本的 200/255）
        context.setFillColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.78)
        let bgRect = CGRect(x: 5, y: 5, width: CGFloat(hudWidth - 10), height: CGFloat(hudHeight - 10))
        context.fill(bgRect)

        // 绘制白色边框
        context.setStrokeColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
        context.setLineWidth(1.0)
        context.stroke(bgRect)

        // 准备文本属性（更小的字体）
        let fontSize: CGFloat = 11  // 进一步缩小字体
        let font = CTFontCreateWithName("Menlo" as CFString, fontSize, nil)

        // 绘制文本（更紧凑的行间距）
        let lineHeight: CGFloat = 18  // 行高（进一步减小间距）
        var yOffset: CGFloat = CGFloat(hudHeight) - 20  // 从顶部开始（CoreGraphics 坐标系 Y 轴向上）

        // 第 1 行：帧计数
        drawText(context: context, text: "Frame: \(frameCount)", x: 15, y: yOffset, font: font, color: CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        yOffset -= lineHeight

        // 第 2 行：FPS（颜色编码）
        let fpsColor: CGColor
        if fps > 30 {
            fpsColor = CGColor(red: 0, green: 1, blue: 0, alpha: 1)  // 绿色
        } else if fps > 20 {
            fpsColor = CGColor(red: 1, green: 1, blue: 0, alpha: 1)  // 黄色
        } else {
            fpsColor = CGColor(red: 1, green: 0, blue: 0, alpha: 1)  // 红色
        }
        drawText(context: context, text: String(format: "FPS: %.1f", fps), x: 15, y: yOffset, font: font, color: fpsColor)
        yOffset -= lineHeight

        // 第 3 行：帧时间
        drawText(context: context, text: String(format: "Time: %.2f ms", frameTimeMs), x: 15, y: yOffset, font: font, color: CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        yOffset -= lineHeight

        // 第 4 行：采样数（颜色编码）
        let samplesColor: CGColor
        if sampleCount >= 100 {
            samplesColor = CGColor(red: 0, green: 1, blue: 0, alpha: 1)  // 绿色 - 已收敛
        } else if sampleCount >= 50 {
            samplesColor = CGColor(red: 1, green: 1, blue: 0, alpha: 1)  // 黄色 - 接近收敛
        } else {
            samplesColor = CGColor(red: 1, green: 0.5, blue: 0, alpha: 1)  // 橙色 - 累积中
        }
        drawText(context: context, text: "Samples: \(sampleCount) spp", x: 15, y: yOffset, font: font, color: samplesColor)
        yOffset -= lineHeight + 3  // 空行（分隔统计和相机参数）

        // 相机参数（青色显示，参考 CPU 版本）
        let cyanColor = CGColor(red: 0, green: 1, blue: 1, alpha: 1)
        let pos = cameraConfig.lookFrom
        drawText(context: context, text: String(format: "Pos: (%.1f, %.1f, %.1f)", pos.x, pos.y, pos.z), x: 15, y: yOffset, font: font, color: cyanColor)
        yOffset -= lineHeight

        drawText(context: context, text: String(format: "Focus Dist: %.2f", cameraConfig.focusDist), x: 15, y: yOffset, font: font, color: cyanColor)
        yOffset -= lineHeight

        drawText(context: context, text: String(format: "Aperture: %.2f°", cameraConfig.defocusAngle), x: 15, y: yOffset, font: font, color: cyanColor)
        yOffset -= lineHeight

        drawText(context: context, text: String(format: "FOV: %.1f°", cameraConfig.vfov), x: 15, y: yOffset, font: font, color: cyanColor)
        yOffset -= lineHeight

        drawText(context: context, text: String(format: "Roll: %.1f°", rollDegrees), x: 15, y: yOffset, font: font, color: cyanColor)

        // 上传到 Metal 纹理
        guard let data = context.data else { return }
        let region = MTLRegionMake2D(0, 0, hudWidth, hudHeight)
        texture.replace(region: region, mipmapLevel: 0, withBytes: data, bytesPerRow: bytesPerRow)
    }

    /// 绘制单行文本（使用 CoreText）
    private func drawText(context: CGContext, text: String, x: CGFloat, y: CGFloat, font: CTFont, color: CGColor) {
        // 创建属性字符串
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color
        ]
        let attributedString = NSAttributedString(string: text, attributes: attributes)

        // 创建 CTLine
        let line = CTLineCreateWithAttributedString(attributedString)

        // 设置文本绘制位置
        context.textPosition = CGPoint(x: x, y: y)

        // 绘制文本
        CTLineDraw(line, context)
    }

    /// 将 HUD 叠加到渲染通道（已经有场景渲染内容）
    /// - Parameters:
    ///   - renderEncoder: 当前的渲染编码器（已经绑定了 blit pipeline）
    ///   - viewportWidth: 窗口宽度
    ///   - viewportHeight: 窗口高度
    func renderHUD(renderEncoder: MTLRenderCommandEncoder, viewportWidth: Int, viewportHeight: Int) {
        guard let hudTexture = hudTexture else { return }

        // 设置 HUD 渲染管线
        renderEncoder.setRenderPipelineState(hudPipeline)

        // 绑定 HUD 纹理
        renderEncoder.setFragmentTexture(hudTexture, index: 0)

        // 传递 HUD 位置和尺寸（左上角，归一化坐标）
        struct HUDParams {
            var position: SIMD2<Float>  // 左上角位置（像素坐标）
            var size: SIMD2<Float>      // HUD 尺寸（像素坐标）
            var viewportSize: SIMD2<Float>  // 视口尺寸
        }

        var params = HUDParams(
            position: SIMD2<Float>(10, 10),  // 左上角偏移 10 像素
            size: SIMD2<Float>(Float(hudWidth), Float(hudHeight)),
            viewportSize: SIMD2<Float>(Float(viewportWidth), Float(viewportHeight))
        )

        renderEncoder.setVertexBytes(&params, length: MemoryLayout<HUDParams>.size, index: 0)

        // 绘制 HUD 四边形（6 个顶点，2 个三角形）
        renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }
}
