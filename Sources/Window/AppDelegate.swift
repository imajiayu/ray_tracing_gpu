// AppDelegate.swift
// Ray Tracing GPU - 主应用程序代理

import Cocoa
import MetalKit

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var realtimeRenderer: RealtimeRenderer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 解析命令行参数
        guard let cmdArgs = CommandLineArgs.parse() else {
            NSApplication.shared.terminate(nil)
            return
        }

        // 检查模式
        if cmdArgs.mode == "window" {
            startWindowMode(args: cmdArgs)
        } else {
            // Image 模式：使用现有的离线渲染逻辑
            startImageMode(args: cmdArgs)
            // 渲染完成后退出
            NSApplication.shared.terminate(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    // MARK: - Window Mode

    func startWindowMode(args: CommandLineArgs) {
        // 将应用设置为正常的 GUI 应用（显示在 Dock 中）
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)

        // 获取场景
        guard args.sceneExists() else {
            ThreadSafeLogger.shared.logln("❌ Unknown scene: '\(args.sceneName)'")
            let available = CommandLineArgs.getAvailableScenes().joined(separator: ", ")
            ThreadSafeLogger.shared.logln("Available scenes: \(available)")
            NSApplication.shared.terminate(nil)
            return
        }

        guard var scene = SceneRegistry.create(name: args.sceneName) else {
            ThreadSafeLogger.shared.logln("❌ Failed to create scene: '\(args.sceneName)'")
            NSApplication.shared.terminate(nil)
            return
        }

        // 应用命令行参数覆盖
        applyCommandLineArgs(args: args, scene: &scene)

        // 窗口大小：使用相机配置的实际分辨率
        let windowWidth = scene.camera.imageWidth
        let windowHeight = Int(Float(windowWidth) / scene.camera.aspectRatio)

        // 更新场景相机配置的高度（确保一致）
        scene.camera.imageWidth = windowWidth

        // 创建自定义 MTKView 子类（接收所有事件）
        class CustomMTKView: MTKView {
            weak var appDelegate: AppDelegate?
            var mouseCaptured = false

            override var acceptsFirstResponder: Bool {
                return true
            }

            override func becomeFirstResponder() -> Bool {
                return true
            }

            // 设置鼠标追踪区域（允许接收 mouseMoved 事件）
            override func updateTrackingAreas() {
                super.updateTrackingAreas()

                // 移除旧的追踪区域
                for area in trackingAreas {
                    removeTrackingArea(area)
                }

                // 添加新的追踪区域
                let options: NSTrackingArea.Options = [
                    .mouseMoved,
                    .activeInKeyWindow,
                    .inVisibleRect
                ]
                let trackingArea = NSTrackingArea(
                    rect: bounds,
                    options: options,
                    owner: self,
                    userInfo: nil
                )
                addTrackingArea(trackingArea)
            }

            override func keyDown(with event: NSEvent) {
                // 特殊处理 ESC：如果鼠标未捕获则关闭窗口
                if event.keyCode == 53 && !mouseCaptured {
                    NSApplication.shared.terminate(nil)
                    return
                }

                if let renderer = appDelegate?.realtimeRenderer {
                    if renderer.processKeyDown(event) {
                        return
                    }
                }
                // 不调用 super 避免系统声音
            }

            override func keyUp(with event: NSEvent) {
                if let renderer = appDelegate?.realtimeRenderer {
                    if renderer.processKeyUp(event) {
                        return
                    }
                }
            }

            override func flagsChanged(with event: NSEvent) {
                // 监听修饰键（Shift, Ctrl, Option, Cmd）
                if let renderer = appDelegate?.realtimeRenderer {
                    renderer.processFlagsChanged(event)
                }
            }

            override func mouseDown(with event: NSEvent) {
                window?.makeKeyAndOrderFront(nil)
                window?.makeFirstResponder(self)

                if !mouseCaptured {
                    captureMouse()
                    mouseCaptured = true

                    if let renderer = appDelegate?.realtimeRenderer {
                        renderer.inputController.isMouseCaptured = true
                        renderer.inputController.firstMouse = true
                    }
                }
            }

            override func mouseMoved(with event: NSEvent) {
                guard mouseCaptured else {
                    super.mouseMoved(with: event)
                    return
                }

                // 使用 event.deltaX/deltaY 获取真正的鼠标移动增量
                let dx = Float(event.deltaX)
                let dy = Float(event.deltaY)

                // 传递给 InputController
                if let renderer = appDelegate?.realtimeRenderer {
                    renderer.inputController.processMouseMovement(deltaX: dx, deltaY: dy)
                }

                // 将光标重置到视图中心，实现无限鼠标移动
                recenterMouse()
            }

            override func mouseDragged(with event: NSEvent) {
                // 捕获模式下，dragged 等同于 moved
                mouseMoved(with: event)
            }

            override func scrollWheel(with event: NSEvent) {
                if let renderer = appDelegate?.realtimeRenderer {
                    if renderer.processScrollWheel(event) {
                        return
                    }
                }
                super.scrollWheel(with: event)
            }

            func captureMouse() {
                CGAssociateMouseAndMouseCursorPosition(0)
                for _ in 0..<5 {
                    NSCursor.hide()
                }
                recenterMouse()
            }

            func releaseMouse() {
                guard mouseCaptured else { return }

                CGAssociateMouseAndMouseCursorPosition(1)
                for _ in 0..<5 {
                    NSCursor.unhide()
                }

                mouseCaptured = false

                if let renderer = appDelegate?.realtimeRenderer {
                    renderer.inputController.isMouseCaptured = false
                }
            }

            // 将鼠标移回视图中心（实现无限鼠标移动）
            func recenterMouse() {
                guard let window = window else { return }

                // 计算视图中心在窗口坐标系中的位置
                let frameInWindow = convert(bounds, to: nil)
                let centerInWindow = CGPoint(x: frameInWindow.midX, y: frameInWindow.midY)

                // 转换为屏幕坐标
                let centerOnScreen = window.convertPoint(toScreen: centerInWindow)

                // 移动光标到中心
                CGWarpMouseCursorPosition(centerOnScreen)

                // 保持锁定状态
                CGAssociateMouseAndMouseCursorPosition(0)
            }
        }

        // 创建 MTKView
        let mtkView = CustomMTKView(frame: CGRect(x: 0, y: 0, width: windowWidth, height: windowHeight))
        mtkView.appDelegate = self
        guard let device = MTLCreateSystemDefaultDevice() else {
            ThreadSafeLogger.shared.logln("❌ Failed to create Metal device")
            NSApplication.shared.terminate(nil)
            return
        }

        mtkView.device = device
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.preferredFramesPerSecond = 60
        mtkView.enableSetNeedsDisplay = false
        mtkView.isPaused = false

        // 禁用自动清除（我们手动渲染整个画面）
        mtkView.clearColor = MTLClearColorMake(0, 0, 0, 1)

        // 强制设置 drawable 尺寸为渲染尺寸，禁用自动 Retina 缩放
        mtkView.autoResizeDrawable = false
        mtkView.drawableSize = CGSize(width: windowWidth, height: windowHeight)

        // 创建窗口（不可调整大小，固定分辨率）
        window = NSWindow(
            contentRect: mtkView.frame,
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = mtkView
        window.title = "Ray Tracing GPU - Real-time Renderer [\(windowWidth)×\(windowHeight)]"
        window.delegate = self
        window.acceptsMouseMovedEvents = true  // 允许接收鼠标移动事件
        window.isReleasedWhenClosed = false

        // 确保窗口可以接收键盘事件
        window.makeKeyAndOrderFront(nil)
        window.center()

        // 激活应用程序
        NSApp.activate(ignoringOtherApps: true)

        // 创建实时渲染器
        do {
            let batchSize = args.getEffectiveBatchSize()
            realtimeRenderer = try RealtimeRenderer(
                scene: scene,
                mtkView: mtkView,
                device: device,
                sceneName: args.sceneName,
                batchSize: batchSize,
                tonemapMode: args.tonemapMode,
                bloomStrength: args.bloomStrength,
                bloomThreshold: args.bloomThreshold,
                filterType: args.filterType,
                useBlueNoise: args.useBlueNoise
            )

            // 设置代理
            mtkView.delegate = realtimeRenderer

            // 连接 ESC 释放鼠标的回调
            realtimeRenderer!.inputController.onRequestMouseRelease = { [weak mtkView] in
                mtkView?.releaseMouse()
            }

            // 打印窗口模式统计头部
            let bvh = realtimeRenderer!.bvh
            let (gpuSpheres, gpuQuads, _, _, _) = scene.toGPU()

            let stats = WindowRenderStats(
                sceneName: args.sceneName,
                width: windowWidth,
                height: windowHeight,
                batchSize: batchSize,
                cameraConfig: scene.camera,
                filterType: args.filterType,
                useBlueNoise: args.useBlueNoise,
                tonemapMode: args.tonemapMode,
                bloomStrength: args.bloomStrength,
                bloomThreshold: args.bloomThreshold
            )
            stats.printHeader(
                sphereCount: gpuSpheres.count,
                quadCount: gpuQuads.count,
                bvhNodeCount: bvh.nodes.count,
                lightsCount: scene.lights.count
            )

            // 启动定时器更新统计
            startWindowStatsTimer(stats: stats)

            // 延迟设置 MTKView 为第一响应者
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                let result = self.window.makeFirstResponder(mtkView)
                print("[AppDelegate] makeFirstResponder(mtkView) result: \(result)")
                print("[AppDelegate] Current first responder: \(String(describing: self.window.firstResponder))")
            }

        } catch {
            ThreadSafeLogger.shared.logln("❌ Failed to initialize renderer: \(error)")
            NSApplication.shared.terminate(nil)
        }
    }


    // 定时器用于更新窗口模式统计
    var windowStatsTimer: Timer?
    var windowStats: WindowRenderStats?

    func startWindowStatsTimer(stats: WindowRenderStats) {
        windowStats = stats

        // 每秒更新一次统计
        windowStatsTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self,
                  let renderer = self.realtimeRenderer,
                  let stats = self.windowStats else {
                return
            }

            // 使用当前时间戳计算 delta（不依赖 lastFrameTime）
            let deltaTime = 1.0 / max(renderer.currentFPS, 0.1)  // 避免除零

            // 获取当前相机配置
            let currentCamera = renderer.scene.camera

            stats.updateFrame(deltaTime: deltaTime, sampleCount: renderer.currentSampleCount, currentCamera: currentCamera)
        }
    }

    // MARK: - Image Mode (Offline Rendering)

    func startImageMode(args: CommandLineArgs) {
        // 1. 初始化 Metal
        guard let context = MetalContext() else {
            ThreadSafeLogger.shared.logln("❌ Failed to initialize Metal")
            exit(1)
        }

        // 2. 加载着色器库
        let metalLibPath = "Resources/default.metallib"
        guard let library = try? context.device.makeLibrary(URL: URL(fileURLWithPath: metalLibPath)) else {
            ThreadSafeLogger.shared.logln("❌ Failed to load shader library from: \(metalLibPath)")
            ThreadSafeLogger.shared.logln("   Make sure to run: ./compile_shaders.sh")
            exit(1)
        }

        // 3. 创建计算管线
        guard let pipeline = context.makeComputePipeline(functionName: "raytrace", library: library) else {
            ThreadSafeLogger.shared.logln("❌ Failed to create compute pipeline")
            exit(1)
        }

        // 4. 创建场景
        guard args.sceneExists() else {
            ThreadSafeLogger.shared.logln("❌ Unknown scene: '\(args.sceneName)'")
            let available = CommandLineArgs.getAvailableScenes().joined(separator: ", ")
            ThreadSafeLogger.shared.logln("Available scenes: \(available)")
            exit(1)
        }

        guard var scene = SceneRegistry.create(name: args.sceneName) else {
            ThreadSafeLogger.shared.logln("❌ Failed to create scene: '\(args.sceneName)'")
            exit(1)
        }

        // 应用命令行参数覆盖
        applyCommandLineArgs(args: args, scene: &scene)

        // 生成默认输出文件名（如果用户未指定 --output）
        var outputFilename: String
        if let userFilename = args.outputFile {
            // 用户明确指定了文件名
            outputFilename = ensureUniqueFilename(userFilename)
        } else {
            // 用户未指定输出文件名，使用自动生成的文件名
            let generatedFilename = args.generateDefaultOutputFilename(scene: scene)
            outputFilename = ensureUniqueFilename(generatedFilename)
            ThreadSafeLogger.shared.logln("ℹ️  Auto-generated output filename: \(outputFilename)")
        }

        // 5. 加载图片纹理（自动根据场景需求加载）
        let imageLoader = ImageLoader(device: context.device)
        for imagePath in scene.imageTexturePaths {
            if let texture = imageLoader.loadTextureSearching(filename: imagePath) {
                scene.addImageTexture(texture)
            }
        }

        // 6. 转换为 GPU 数据并构建 BVH
        let (gpuSpheres, gpuQuads, _, _, _) = scene.toGPU()

        // 7. 构建 BVH
        let bvh = FlatBVH()
        let spheres = scene.geometry.getSpheres()
        let quads = scene.geometry.getQuads()
        bvh.build(spheres: spheres, quads: quads, transforms: scene.cpuTransforms, debug: false)

        // 8. 创建相机
        let camera = Camera(config: scene.camera)

        // 9. 创建渲染器
        let renderer = Renderer(context: context, pipeline: pipeline)

        // 检查是否使用自适应采样
        let pixelData: [Float]
        let renderTime: TimeInterval

        if args.useAdaptiveSampling {
            // ===== 自适应采样模式 =====
            guard let minSpp = args.minSpp else {
                fatalError("Internal error: useAdaptiveSampling is true but minSpp is nil")
            }
            let targetSpp = args.spp ?? Int(scene.camera.samplesPerPixel)
            let totalBudget = camera.imageWidth * camera.imageHeight * targetSpp

            ThreadSafeLogger.shared.logln("")
            ThreadSafeLogger.shared.logln("╔═════════════════════════════════════════════════════════════════════╗")
            ThreadSafeLogger.shared.logln("║ 🎯 Adaptive Sampling (Fixed Budget)                                 ║")
            ThreadSafeLogger.shared.logln("╚═════════════════════════════════════════════════════════════════════╝")
            ThreadSafeLogger.shared.logln("  Scene              : \(args.sceneName)")
            ThreadSafeLogger.shared.logln("  Resolution         : \(camera.imageWidth) × \(camera.imageHeight)")
            ThreadSafeLogger.shared.logln("  Min SPP            : \(minSpp) (guaranteed for all pixels)")
            ThreadSafeLogger.shared.logln("  Target SPP         : \(targetSpp) (total budget)")
            ThreadSafeLogger.shared.logln("  Total Budget       : \(totalBudget) samples")
            ThreadSafeLogger.shared.logln("  Variance Threshold : \(args.adaptiveVarianceThreshold)")
            ThreadSafeLogger.shared.logln("  Relative Error     : \(args.adaptiveRelativeThreshold)")
            ThreadSafeLogger.shared.logln("  Batch Size         : \(args.adaptiveBatchSize)")
            ThreadSafeLogger.shared.logln("  Max Depth          : \(scene.camera.maxDepth)")
            ThreadSafeLogger.shared.logln("  Filter             : \(args.filterType.description)")
            ThreadSafeLogger.shared.logln("  Blue Noise         : \(args.useBlueNoise ? "Yes" : "No")")
            ThreadSafeLogger.shared.logln("  Weighted Variance  : \(args.useWeightedVariance ? "Yes (Material-aware)" : "No (Standard)")")
            ThreadSafeLogger.shared.logln("")
            ThreadSafeLogger.shared.logln("  Geometry:")
            ThreadSafeLogger.shared.logln("    Spheres          : \(gpuSpheres.count)")
            ThreadSafeLogger.shared.logln("    Quads            : \(gpuQuads.count)")
            ThreadSafeLogger.shared.logln("    BVH Nodes        : \(bvh.nodes.count)")
            ThreadSafeLogger.shared.logln("    Lights           : \(scene.lights.count)")
            ThreadSafeLogger.shared.logln("")

            // 创建自适应渲染器
            let adaptiveRenderer = AdaptiveRenderer(context: context, baseRenderer: renderer, library: library)

            // 执行自适应渲染
            let (adaptivePixels, adaptiveTime, adaptiveStats) = adaptiveRenderer.renderAdaptive(
                scene: scene,
                camera: camera,
                bvh: bvh,
                sceneName: args.sceneName,
                minSamples: minSpp,
                targetSpp: targetSpp,
                varianceThreshold: args.adaptiveVarianceThreshold,
                relativeThreshold: args.adaptiveRelativeThreshold,
                batchSize: args.adaptiveBatchSize,
                filterType: args.filterType,
                useBlueNoise: args.useBlueNoise,
                useWeightedVariance: args.useWeightedVariance,
                progressCallback: nil  // 进度打印已在 AdaptiveRenderer 内部处理
            )

            pixelData = adaptivePixels
            renderTime = adaptiveTime

            // 打印自适应采样统计
            ThreadSafeLogger.shared.logln("")
            ThreadSafeLogger.shared.logln("╔═════════════════════════════════════════════════════════════════════╗")
            ThreadSafeLogger.shared.logln("║ 📊 Adaptive Sampling Statistics                                     ║")
            ThreadSafeLogger.shared.logln("╚═════════════════════════════════════════════════════════════════════╝")
            ThreadSafeLogger.shared.logln("  Total Render Time  : \(String(format: "%.2f", adaptiveTime * 1000)) ms")
            ThreadSafeLogger.shared.logln("  Iterations         : \(adaptiveStats.iterationCount)")
            ThreadSafeLogger.shared.logln("")
            ThreadSafeLogger.shared.logln("  SPP Distribution:")
            ThreadSafeLogger.shared.logln("    Average          : \(String(format: "%.1f", adaptiveStats.averageSpp))")
            ThreadSafeLogger.shared.logln("    Min              : \(adaptiveStats.minSpp)")
            ThreadSafeLogger.shared.logln("    25th Percentile  : \(adaptiveStats.percentile25Spp)")
            ThreadSafeLogger.shared.logln("    50th Percentile  : \(adaptiveStats.percentile50Spp)")
            ThreadSafeLogger.shared.logln("    75th Percentile  : \(adaptiveStats.percentile75Spp)")
            ThreadSafeLogger.shared.logln("    Max              : \(adaptiveStats.maxSpp)")
            ThreadSafeLogger.shared.logln("")
            ThreadSafeLogger.shared.logln("  Efficiency:")
            ThreadSafeLogger.shared.logln("    Samples Saved    : \(String(format: "%.1f%%", adaptiveStats.samplesSavedPercent * 100))")

            let theoreticalTime = renderTime / Double(adaptiveStats.averageSpp) * Double(targetSpp)
            let speedup = theoreticalTime / renderTime
            ThreadSafeLogger.shared.logln("    Speedup vs Fixed : \(String(format: "%.2fx", speedup)) (vs \(targetSpp) spp fixed)")
            ThreadSafeLogger.shared.logln("")

        } else {
            // ===== 传统固定采样模式 =====
            let batchSize = args.getEffectiveBatchSize()
            let samplesPerBatch = UInt32(batchSize)
            let totalBatches = Int((scene.camera.samplesPerPixel + samplesPerBatch - 1) / samplesPerBatch)

            let stats = ImageRenderStats(
                sceneName: args.sceneName,
                width: camera.imageWidth,
                height: camera.imageHeight,
                spp: Int(scene.camera.samplesPerPixel),
                maxDepth: Int(scene.camera.maxDepth),
                totalBatches: totalBatches,
                cameraConfig: scene.camera,
                filterType: args.filterType,
                useBlueNoise: args.useBlueNoise,
                tonemapMode: args.tonemapMode,
                bloomStrength: args.bloomStrength,
                bloomThreshold: args.bloomThreshold
            )

            // 打印头部信息
            stats.printHeader(
                sphereCount: gpuSpheres.count,
                quadCount: gpuQuads.count,
                bvhNodeCount: bvh.nodes.count,
                lightsCount: scene.lights.count
            )

            // 执行渲染（带进度回调）
            let (pixels, time) = renderer.render(
                scene: scene,
                camera: camera,
                bvh: bvh,
                batchSize: batchSize,
                filterType: args.filterType,
                useBlueNoise: args.useBlueNoise,
                progressCallback: { batch in
                    stats.updateProgress(batch: batch, samplesPerBatch: batchSize)
                }
            )

            pixelData = pixels
            renderTime = time

            // 打印总结
            stats.printSummary(renderTime: renderTime)
        }

        // 11. 应用 Bloom 效果（如果启用）
        var finalPixelData = pixelData
        if args.bloomStrength > 0.0 {
            let sppForBloom: UInt32
            if args.useAdaptiveSampling {
                // 自适应采样：像素已经归一化，使用 1
                sppForBloom = 1
            } else {
                // 传统模式：使用 batch 数量
                let batchSize = args.getEffectiveBatchSize()
                let samplesPerBatch = UInt32(batchSize)
                let totalBatches = Int((scene.camera.samplesPerPixel + samplesPerBatch - 1) / samplesPerBatch)
                sppForBloom = UInt32(totalBatches)
            }

            finalPixelData = applyBloomToPixelData(
                pixelData: pixelData,
                width: camera.imageWidth,
                height: camera.imageHeight,
                spp: sppForBloom,
                bloomStrength: args.bloomStrength,
                bloomThreshold: args.bloomThreshold,
                context: context,
                library: library
            )
        }

        // 12. 保存结果
        var mutablePixelData = finalPixelData

        if args.useAdaptiveSampling {
            // 自适应采样：像素已经在 GPU 端归一化，直接保存（spp=1 表示不再归一化）
            ImageWriter.averageAndSavePPM(
                accumulatedPixels: &mutablePixelData,
                samplesPerPixel: 1,
                width: camera.imageWidth,
                height: camera.imageHeight,
                filename: outputFilename,
                tonemapMode: args.tonemapMode
            )
        } else {
            // 传统模式：需要除以 batch 数量
            let batchSize = args.getEffectiveBatchSize()
            let samplesPerBatch = UInt32(batchSize)
            let totalBatches = Int((scene.camera.samplesPerPixel + samplesPerBatch - 1) / samplesPerBatch)

            ImageWriter.averageAndSavePPM(
                accumulatedPixels: &mutablePixelData,
                samplesPerPixel: UInt32(totalBatches),
                width: camera.imageWidth,
                height: camera.imageHeight,
                filename: outputFilename,
                tonemapMode: args.tonemapMode
            )
        }

        ThreadSafeLogger.shared.logln("")
        ThreadSafeLogger.shared.logln("✅ Output: \(outputFilename)")
    }

    // MARK: - Helper Methods

    /// 对离线渲染的像素数据应用 Bloom 效果（GPU 加速）
    func applyBloomToPixelData(
        pixelData: [Float],
        width: Int,
        height: Int,
        spp: UInt32,
        bloomStrength: Float,
        bloomThreshold: Float,
        context: MetalContext,
        library: MTLLibrary
    ) -> [Float] {
        print("[Bloom] 应用 Bloom 效果到离线渲染...")

        guard let bloomRenderer = BloomRenderer(
            device: context.device,
            library: library,
            bloomThreshold: bloomThreshold,
            bloomStrength: bloomStrength
        ) else {
            print("[Bloom] ⚠️  无法创建 BloomRenderer，跳过 Bloom")
            return pixelData
        }

        // 1. 创建输入纹理并上传累积数据（已累积，未平均）
        let inputDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float,
            width: width,
            height: height,
            mipmapped: false
        )
        inputDescriptor.usage = [.shaderRead, .shaderWrite]
        inputDescriptor.storageMode = .shared  // 需要 CPU 访问

        guard let inputTexture = context.device.makeTexture(descriptor: inputDescriptor) else {
            print("[Bloom] ⚠️  无法创建输入纹理")
            return pixelData
        }

        // 平均累积数据（Bloom 需要已平均的 HDR 数据）
        var averagedData = pixelData
        let sppFloat = Float(spp)
        for i in 0..<averagedData.count {
            averagedData[i] /= sppFloat
        }

        // 上传平均后的数据到纹理
        let bytesPerRow = width * 4 * MemoryLayout<Float>.size
        inputTexture.replace(
            region: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0,
            withBytes: averagedData,
            bytesPerRow: bytesPerRow
        )

        // 2. 创建输出纹理
        let outputDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float,
            width: width,
            height: height,
            mipmapped: false
        )
        outputDescriptor.usage = [.shaderRead, .shaderWrite]
        outputDescriptor.storageMode = .shared

        guard let outputTexture = context.device.makeTexture(descriptor: outputDescriptor) else {
            print("[Bloom] ⚠️  无法创建输出纹理")
            return pixelData
        }

        // 3. 执行 Bloom
        guard let commandBuffer = context.commandQueue.makeCommandBuffer() else {
            print("[Bloom] ⚠️  无法创建命令缓冲区")
            return pixelData
        }

        bloomRenderer.applyBloom(
            inputTexture: inputTexture,
            outputTexture: outputTexture,
            commandBuffer: commandBuffer
        )

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        // 4. 从输出纹理下载数据
        var outputData = [Float](repeating: 0, count: width * height * 4)
        outputTexture.getBytes(
            &outputData,
            bytesPerRow: bytesPerRow,
            from: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0
        )

        // 5. 将数据乘回实际采样数（因为 ImageWriter 会再次平均）
        // 注意：分层采样会调整为完全平方数
        let sqrtSpp = UInt32(sqrt(Double(spp)))
        let actualSpp = sqrtSpp * sqrtSpp
        let actualSppFloat = Float(actualSpp)
        for i in 0..<outputData.count {
            outputData[i] *= actualSppFloat
        }

        print("[Bloom] ✓ Bloom 应用完成")
        return outputData
    }

    /// 确保文件名唯一（如果文件已存在，添加时间戳后缀）
    func ensureUniqueFilename(_ filename: String) -> String {
        let fileManager = FileManager.default
        let url = URL(fileURLWithPath: filename)
        let directory = url.deletingLastPathComponent().path
        let basename = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension

        // 检查文件是否存在
        guard fileManager.fileExists(atPath: filename) else {
            return filename
        }

        // 文件存在，生成带时间戳的新文件名
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = dateFormatter.string(from: Date())

        let newFilename: String
        if directory.isEmpty || directory == "." {
            newFilename = "\(basename)_\(timestamp).\(ext)"
        } else {
            newFilename = "\(directory)/\(basename)_\(timestamp).\(ext)"
        }

        ThreadSafeLogger.shared.logln("⚠️  文件 '\(filename)' 已存在")
        ThreadSafeLogger.shared.logln("ℹ️  使用新文件名: \(newFilename)")

        return newFilename
    }

    func applyCommandLineArgs(args: CommandLineArgs, scene: inout Scene) {
        // 优先级：用户输入 > 场景设定值 > 统一默认值

        // 1. Width
        // 优先级：用户输入 > 场景值 > 默认值 1024
        if let width = args.width {
            scene.camera.imageWidth = width
        } else if scene.camera.imageWidth == 0 {
            scene.camera.imageWidth = 1024
        }

        // 2. SPP
        // 优先级：用户输入 > 场景值 > 默认值（image 模式 1000，window 模式无限制）
        if let spp = args.spp {
            scene.camera.samplesPerPixel = UInt32(spp)
        } else if scene.camera.samplesPerPixel == 0 {
            // 只有场景未设置时，才应用默认值
            if args.mode == "image" {
                scene.camera.samplesPerPixel = 1000
            }
            // Window 模式：不需要总 spp（使用无限累积）
        }

        // 3. Max Depth
        // 优先级：用户输入 > 场景值 > 默认值 50
        if let maxDepth = args.maxDepth {
            scene.camera.maxDepth = UInt32(maxDepth)
        } else if scene.camera.maxDepth == 0 {
            scene.camera.maxDepth = 50
        }

        // 4. VFov (视野角度)
        // 优先级：用户输入 > 场景值
        if let vfov = args.vfov {
            scene.camera.vfov = vfov
        }
        // 如果用户没有指定，保持场景的原始值

        // 5. Defocus Angle（景深）
        // 优先级：用户输入 > 场景值 > 默认值 0（无景深）
        if let defocusAngle = args.defocusAngle {
            scene.camera.defocusAngle = defocusAngle
        }
        // 如果用户没有指定，保持场景的原始值（可能是 0 或其他值）
        // 例如：BouncingSpheres 场景默认有 defocusAngle = 0.6

        // 6. Focus Distance
        // 优先级：用户输入 > 场景值
        if let focusDist = args.focusDist {
            scene.camera.focusDist = focusDist
        }
        // 如果用户没有指定，保持场景的原始值

        // 7. Background（天空背景）
        // 优先级：用户输入 > 场景值
        if let useBackground = args.useBackground {
            scene.camera.useBackground = useBackground
        }
        // 如果用户没有指定，保持场景的原始值
    }
}

// MARK: - NSWindowDelegate

extension AppDelegate: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        return true
    }

    func windowWillClose(_ notification: Notification) {
        // 窗口即将关闭，停止定时器
        windowStatsTimer?.invalidate()
        windowStatsTimer = nil
        windowStats = nil
    }
}

