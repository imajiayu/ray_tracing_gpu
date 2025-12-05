// RealtimeRenderer.swift
// 实时渲染器 - MTKViewDelegate 核心
//
// 渲染流程：
// 1. Compute Shader (raytrace) → RGBA32Float 中间纹理（每帧 batch_size spp）
// 2. Accumulation → 累积到 RGBA32Float 累积纹理
// 3. Render Pipeline (blit) → BGRA8Unorm drawable（显示到屏幕）
//
// Phase 6 功能：
// - FPS 相机控制 (WASD + 鼠标)
// - 质量预设切换 (1/2/3 键)
// - HUD 显示切换 (Tab 键)
// - 智能累积重置（三级变化检测）

import MetalKit
import simd

class RealtimeRenderer: NSObject, MTKViewDelegate {
    // MARK: - Metal 上下文
    let context: MetalContext
    let device: MTLDevice
    let commandQueue: MTLCommandQueue

    // MARK: - 场景数据
    var scene: Scene
    var camera: Camera
    let bvh: FlatBVH

    // MARK: - 渲染器
    let renderer: Renderer
    let pipeline: MTLComputePipelineState
    let blitPipeline: MTLRenderPipelineState
    let gpuBuffers: Renderer.GPUBuffers
    let sphereCount: Int
    let quadCount: Int

    // MARK: - 累积渲染
    var accumulationTexture: MTLTexture!              // 累积缓冲区（RGBA32Float）
    let accumulatePipeline: MTLComputePipelineState
    let resetPipeline: MTLComputePipelineState
    var sampleCount: Int = 0

    // MARK: - 质量预设
    var batchSize: Int                                // 每帧采样数（动态可调）
    let initialBatchSize: Int                         // 初始 batch_size（来自命令行）

    // MARK: - 相机控制
    var inputController: InputController!
    var cameraTracker: CameraStateTracker!
    var lastCameraChangeTime: TimeInterval = 0
    let cameraChangeDebounce: TimeInterval = 0.1      // 100ms 防抖

    // MARK: - 统计信息
    var fpsSmooth: Double = 0.0
    var lastFrameTime: Date = Date()
    var frameCount: Int = 0

    // MARK: - HUD
    var hudRenderer: HUDRenderer?
    var hudVisible: Bool = true                       // HUD 显示状态

    let sceneType: SceneType

    // MARK: - 公开接口
    var currentSampleCount: Int { return sampleCount }
    var currentFPS: Double { return fpsSmooth }

    init(scene: Scene, mtkView: MTKView, device: MTLDevice, sceneType: SceneType, batchSize: Int = 1) throws {
        self.device = device
        self.scene = scene
        self.sceneType = sceneType
        self.batchSize = batchSize
        self.initialBatchSize = batchSize

        // 初始化 Metal 上下文
        guard let ctx = MetalContext() else {
            throw NSError(domain: "RealtimeRenderer", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to create Metal context"
            ])
        }
        self.context = ctx
        self.commandQueue = ctx.commandQueue

        // 加载着色器
        let metalLibPath = "Resources/default.metallib"
        guard let library = try? device.makeLibrary(URL: URL(fileURLWithPath: metalLibPath)) else {
            throw NSError(domain: "RealtimeRenderer", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Failed to load shader library from: \(metalLibPath)"
            ])
        }

        guard let pipe = ctx.makeComputePipeline(functionName: "raytrace_realtime", library: library) else {
            throw NSError(domain: "RealtimeRenderer", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Failed to create raytrace_realtime pipeline"
            ])
        }
        self.pipeline = pipe

        // 创建 Blit 渲染管线（标准渲染管线，用于显示到 drawable）
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = library.makeFunction(name: "blitVertex")
        pipelineDescriptor.fragmentFunction = library.makeFunction(name: "blitFragment")
        pipelineDescriptor.colorAttachments[0].pixelFormat = mtkView.colorPixelFormat  // 必须与 MTKView 一致！

        guard let blitPipe = try? device.makeRenderPipelineState(descriptor: pipelineDescriptor) else {
            throw NSError(domain: "RealtimeRenderer", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "Failed to create blit render pipeline"
            ])
        }
        self.blitPipeline = blitPipe

        // 加载累积着色器
        guard let accumPipe = ctx.makeComputePipeline(functionName: "accumulate_kernel", library: library) else {
            throw NSError(domain: "RealtimeRenderer", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "Failed to create accumulation pipeline"
            ])
        }
        self.accumulatePipeline = accumPipe

        guard let resetPipe = ctx.makeComputePipeline(functionName: "reset_accumulation_kernel", library: library) else {
            throw NSError(domain: "RealtimeRenderer", code: 6, userInfo: [
                NSLocalizedDescriptionKey: "Failed to create reset pipeline"
            ])
        }
        self.resetPipeline = resetPipe

        // 创建相机
        self.camera = Camera(config: scene.camera)

        // 构建 BVH
        self.bvh = FlatBVH()
        let spheres = scene.geometry.getSpheres()
        let quads = scene.geometry.getQuads()
        bvh.build(spheres: spheres, quads: quads, transforms: scene.cpuTransforms, debug: false)

        // 创建渲染器
        self.renderer = Renderer(context: ctx, pipeline: pipe)

        // 加载图片纹理（自动根据场景需求加载）
        let imageLoader = ImageLoader(device: device)
        for imagePath in self.scene.imageTexturePaths {
            if let texture = imageLoader.loadTextureSearching(filename: imagePath) {
                self.scene.addImageTexture(texture)
            }
        }

        // 预创建 GPU 缓冲区（避免每帧重新创建）
        let (gpuSpheres, gpuQuads, gpuMaterials, gpuTextures, gpuTransforms) = self.scene.toGPU()

        // 保存计数
        self.sphereCount = gpuSpheres.count
        self.quadCount = gpuQuads.count

        guard let buffers = renderer.createBuffers(
            spheres: gpuSpheres,
            quads: gpuQuads,
            materials: gpuMaterials,
            textures: gpuTextures,
            transforms: gpuTransforms,
            bvh: bvh,
            lights: self.scene.lights
        ) else {
            throw NSError(domain: "RealtimeRenderer", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "Failed to create GPU buffers"
            ])
        }
        self.gpuBuffers = buffers

        super.init()

        // 创建累积纹理（包括预渲染缓冲区）
        setupAccumulationTexture(width: camera.imageWidth, height: camera.imageHeight)

        // 创建 HUD 渲染器
        do {
            self.hudRenderer = try HUDRenderer(device: device, library: library)
        } catch {
            print("⚠️  Warning: Failed to create HUD renderer: \(error)")
            // HUD 是可选的，渲染器仍然可以工作
        }

        // 初始化输入控制器
        self.inputController = InputController(config: scene.camera)

        // 初始化相机状态跟踪器
        self.cameraTracker = CameraStateTracker(config: scene.camera)
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // 窗口大小改变时的处理（不输出日志）
        // 更新场景相机配置
        scene.camera.imageWidth = Int(size.width)

        // 重新创建相机
        camera = Camera(config: scene.camera)

        // 重新创建累积纹理（尺寸变化）
        setupAccumulationTexture(width: Int(size.width), height: Int(size.height))
    }

    /// MTKViewDelegate 核心方法：每帧渲染循环
    func draw(in view: MTKView) {
        // 1. 计算帧时间
        let now = Date()
        let deltaTime = now.timeIntervalSince(lastFrameTime)
        lastFrameTime = now

        // 2. 更新输入控制器（WASD 移动）
        inputController.update(deltaTime: deltaTime)

        // 3. 检测相机变化并处理累积重置
        handleCameraChange()

        // 4. 从 InputController 同步相机配置
        scene.camera = inputController.config
        camera = Camera(config: scene.camera)

        // 5. 获取当前帧的 drawable
        guard let drawable = view.currentDrawable else {
            return
        }

        // 6. 执行光线追踪渲染（compute shader）
        guard let renderedTexture = renderer.renderToTexture(
            scene: scene,
            camera: camera,
            bvh: bvh,
            buffers: gpuBuffers,
            sphereCount: sphereCount,
            quadCount: quadCount,
            batchSize: batchSize,
            sampleOffset: UInt32(sampleCount)
        ) else {
            return
        }

        // 7. 累积当前帧到累积纹理
        accumulateFrame(currentFrameTexture: renderedTexture, targetTexture: accumulationTexture)

        // 8. 将累积纹理显示到屏幕
        displayTexture(texture: accumulationTexture, drawable: drawable)

        // 9. 更新 FPS 统计
        updateFPS(deltaTime: deltaTime)
        frameCount += 1
    }

    // MARK: - Helper Methods

    /// 将 RGBA32Float 纹理显示到 drawable（使用渲染管线）
    /// - Parameters:
    ///   - texture: 输入纹理（RGBA32Float，由 raytrace compute shader 生成）
    ///   - drawable: 输出 drawable（BGRA8Unorm，显示到屏幕）
    func displayTexture(texture: MTLTexture, drawable: CAMetalDrawable) {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            return
        }

        // 更新 HUD 内容（仅当 HUD 可见时）
        if hudVisible, let hudRenderer = hudRenderer {
            let frameTimeMs = (1.0 / max(fpsSmooth, 0.1)) * 1000  // 避免除零
            hudRenderer.updateHUD(
                frameCount: frameCount,
                fps: fpsSmooth,
                frameTimeMs: frameTimeMs,
                sampleCount: sampleCount,
                cameraConfig: scene.camera,
                rollDegrees: Double(inputController.getRollDegrees())
            )
        }

        // 创建渲染通道描述符（渲染到 drawable）
        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = drawable.texture
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        renderPassDescriptor.colorAttachments[0].storeAction = .store

        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }

        // 步骤 1: 渲染场景（blit 全屏四边形）
        renderEncoder.setRenderPipelineState(blitPipeline)
        renderEncoder.setFragmentTexture(texture, index: 0)

        var sampleCountFloat = Float(max(sampleCount, 1))  // 至少为 1 避免除零
        renderEncoder.setFragmentBytes(&sampleCountFloat, length: MemoryLayout<Float>.size, index: 0)

        renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)

        // 步骤 2: 叠加 HUD（透明混合，仅当 HUD 可见时）
        if hudVisible, let hudRenderer = hudRenderer {
            hudRenderer.renderHUD(
                renderEncoder: renderEncoder,
                viewportWidth: drawable.texture.width,
                viewportHeight: drawable.texture.height
            )
        }

        renderEncoder.endEncoding()

        // 呈现到屏幕
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    func updateFPS(deltaTime: TimeInterval) {
        let instantFPS = 1.0 / deltaTime
        let alpha = 0.1

        if fpsSmooth == 0.0 {
            fpsSmooth = instantFPS
        } else {
            fpsSmooth = alpha * instantFPS + (1.0 - alpha) * fpsSmooth
        }
    }

    // MARK: - Accumulation

    /// 设置累积纹理（初始化或分辨率改变时调用）
    func setupAccumulationTexture(width: Int, height: Int) {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float,  // 使用 Float 累积（避免精度损失）
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private

        // 创建累积缓冲区
        accumulationTexture = device.makeTexture(descriptor: descriptor)

        resetAccumulation()
    }

    /// 重置累积缓冲区
    func resetAccumulation() {
        sampleCount = 0

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return
        }

        encoder.setComputePipelineState(resetPipeline)
        encoder.setTexture(accumulationTexture, index: 0)

        let threadsPerGrid = MTLSize(
            width: accumulationTexture.width,
            height: accumulationTexture.height,
            depth: 1
        )
        let threadsPerThreadgroup = MTLSize(width: 16, height: 16, depth: 1)
        encoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)

        encoder.endEncoding()
        commandBuffer.commit()
    }

    /// 累积当前帧到目标纹理
    func accumulateFrame(currentFrameTexture: MTLTexture, targetTexture: MTLTexture) {
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return
        }

        encoder.setComputePipelineState(accumulatePipeline)
        encoder.setTexture(currentFrameTexture, index: 0)      // 输入：当前帧
        encoder.setTexture(targetTexture, index: 1)            // 输入/输出：目标累积纹理

        // 设置累积参数
        struct AccumulationParams {
            var isFirstFrame: UInt32
            var sppPerFrame: UInt32
            var totalSamples: UInt32
        }

        var params = AccumulationParams(
            isFirstFrame: sampleCount == 0 ? 1 : 0,
            sppPerFrame: UInt32(batchSize),  // 每帧 batchSize spp
            totalSamples: UInt32(sampleCount + batchSize)
        )
        encoder.setBytes(&params, length: MemoryLayout<AccumulationParams>.size, index: 0)

        let threadsPerGrid = MTLSize(
            width: currentFrameTexture.width,
            height: currentFrameTexture.height,
            depth: 1
        )
        let threadsPerThreadgroup = MTLSize(width: 16, height: 16, depth: 1)
        encoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)

        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        sampleCount += batchSize
    }

    // MARK: - Camera Change Handling

    /// 处理相机变化（三级检测）
    func handleCameraChange() {
        let now = CACurrentMediaTime()

        // 防抖：忽略过快的变化
        if now - lastCameraChangeTime < cameraChangeDebounce {
            return
        }

        let changeType = cameraTracker.detectChange(current: inputController.config)

        switch changeType {
        case .none:
            // 无变化，继续累积
            break

        case .minor:
            // 次要参数变化（景深）：也需要完全重置
            // 因为累积纹理中的样本数与新的相机参数不匹配
            resetAccumulation()
            cameraTracker.update(config: inputController.config)
            lastCameraChangeTime = now

        case .major:
            // 主要参数变化（位置/视角/FOV）：完全重置
            resetAccumulation()
            cameraTracker.update(config: inputController.config)
            lastCameraChangeTime = now
        }
    }

    // MARK: - Event Handling

    /// 处理按键事件（质量预设、HUD 切换等）
    func processKeyDown(_ event: NSEvent) -> Bool {
        let keyCode = event.keyCode

        switch keyCode {
        case 18:  // 1 - Preview quality
            setBatchSize(1)
            return true

        case 19:  // 2 - Medium quality
            setBatchSize(4)
            return true

        case 20:  // 3 - High quality
            setBatchSize(8)
            return true

        case 48:  // Tab - Toggle HUD
            hudVisible.toggle()
            return true

        default:
            // 转发给 InputController
            return inputController.processKeyDown(event)
        }
    }

    /// 处理按键释放事件
    func processKeyUp(_ event: NSEvent) -> Bool {
        return inputController.processKeyUp(event)
    }

    /// 处理修饰键变化（Shift, Ctrl, etc）
    func processFlagsChanged(_ event: NSEvent) {
        inputController.processFlagsChanged(event)
    }

    /// 处理鼠标按钮事件
    func processMouseButton(_ event: NSEvent) -> Bool {
        return inputController.processMouseButton(event)
    }

    /// 处理鼠标移动事件
    func processMouseMotion(_ event: NSEvent) -> Bool {
        return inputController.processMouseMotion(event)
    }

    /// 处理鼠标滚轮事件
    func processScrollWheel(_ event: NSEvent) -> Bool {
        return inputController.processScrollWheel(event)
    }

    /// 设置 batch_size（质量预设）
    func setBatchSize(_ newBatchSize: Int) {
        if newBatchSize != batchSize {
            batchSize = newBatchSize
            print("[Quality] Batch size changed to \(batchSize) spp/frame")
            // 注意：不重置累积，让新旧样本混合
        }
    }

    /// 检查鼠标是否被捕获
    func isMouseCaptured() -> Bool {
        return inputController.isMouseCaptured
    }
}
