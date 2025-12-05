# Phase 6: 实时窗口模式 - 技术设计文档

**实施日期**: 2025-12-03
**目标**: 实现交互式实时渲染窗口，支持累积渲染和相机控制
**参考**: CPU 版本 `~/ray_tracing` Week 6 实时架构

---

## 1. 概述

### 1.1 目标

将当前的离线渲染器升级为支持实时交互的窗口应用，同时保持现有的静态渲染功能。

**核心功能**:
- ✅ MTKView 原生窗口显示
- ✅ 渐进式累积渲染（静止时达到高质量）
- ✅ FPS 风格相机控制（WASD + 鼠标）
- ✅ 质量预设切换
- ✅ 实时 HUD 显示

### 1.2 设计原则

1. **复用现有 Renderer**：最大化利用 `Sources/Rendering/Renderer.swift` 的现有代码
2. **零转换开销**：Metal 纹理直接显示到 MTKView，无 CPU ↔ GPU 数据回传
3. **渐进式渲染**：利用现有的 batch 渲染机制实现累积
4. **保持双模式**：同时支持 window（实时）和 image（离线）模式

---

## 2. 架构设计

### 2.1 整体架构

```
┌─────────────────────────────────────────────────────────┐
│                     AppDelegate                         │
│              (NSApplication 主循环)                      │
└────────────────────┬────────────────────────────────────┘
                     │
      ┌──────────────┴──────────────┐
      │                             │
┌─────▼─────────┐          ┌────────▼────────┐
│  MTKView      │          │ InputController │
│  (Metal View) │          │  (WASD + Mouse) │
└─────┬─────────┘          └────────┬────────┘
      │                             │
      │   ┌─────────────────────────┘
      │   │
┌─────▼───▼────────────────────────────────────────────┐
│          RealtimeRenderer (NSViewController)        │
│  ┌──────────────────────────────────────────────┐  │
│  │  MTKViewDelegate:                             │  │
│  │  - draw(in:) 每帧调用                          │  │
│  │  - 调用 Renderer.renderToTexture()            │  │
│  │  - 累积到 AccumulationTexture                  │  │
│  │  - 混合结果显示到 drawable                     │  │
│  └──────────────────────────────────────────────┘  │
│                                                     │
│  ┌──────────────────────────────────────────────┐  │
│  │  AccumulationBuffer (GPU 端):                │  │
│  │  - Metal 纹理累积（compute shader）           │  │
│  │  - 静止时渐进提升质量                          │  │
│  │  - 相机移动时自动重置                          │  │
│  └──────────────────────────────────────────────┘  │
│                                                     │
│  ┌──────────────────────────────────────────────┐  │
│  │  复用现有 Renderer:                           │  │
│  │  - render() 改为 renderToTexture()           │  │
│  │  - 返回 MTLTexture 而不是 [Float]            │  │
│  │  - batchSize = 1 用于实时模式                 │  │
│  └──────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────┘
```

### 2.2 数据流

**实时渲染循环**:
```
每帧 (60 FPS):
  1. MTKView.draw(in:) 触发
  2. 检测相机是否移动
     - 移动：重置累积缓冲区
     - 静止：继续累积
  3. Renderer.renderToTexture(batchSize: 1)
     → Metal compute shader → MTLTexture (1 spp)
  4. AccumulationShader.accumulate(currentFrame, accumulationTexture)
     → accumulationTexture += currentFrame
     → sampleCount++
  5. BlendShader.blend(accumulationTexture, sampleCount)
     → finalTexture = accumulationTexture / sampleCount
  6. 显示 finalTexture 到 MTKView.drawable
  7. 绘制 HUD (Metal 文字渲染)
```

---

## 3. 详细实现计划

### 3.1 窗口系统 (MTKView + AppKit)

#### 3.1.1 文件结构
```
Sources/
  ├── Window/
  │   ├── AppDelegate.swift         # NSApplication 主循环
  │   ├── RealtimeRenderer.swift    # MTKViewDelegate + 渲染循环
  │   ├── InputController.swift     # 键盘鼠标输入处理
  │   └── HUDRenderer.swift         # Metal 文字渲染 (FPS, 相机参数等)
```

#### 3.1.2 AppDelegate.swift
```swift
import Cocoa
import MetalKit

@main
class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var realtimeRenderer: RealtimeRenderer!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 解析命令行参数
        let args = CommandLineArgs.parse()

        if args.mode == "window" {
            // 创建 Metal 窗口
            setupWindow(width: 800, height: 600)

            // 创建实时渲染器
            realtimeRenderer = RealtimeRenderer(
                scene: args.getScene(),
                mtkView: window.contentView as! MTKView
            )
        } else {
            // 离线渲染模式（现有代码）
            renderOffline(args)
            NSApplication.shared.terminate(nil)
        }
    }

    func setupWindow(width: Int, height: Int) {
        // 创建 MTKView
        let mtkView = MTKView(frame: CGRect(x: 0, y: 0, width: width, height: height))
        mtkView.device = MTLCreateSystemDefaultDevice()
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.preferredFramesPerSecond = 60

        // 创建窗口
        window = NSWindow(
            contentRect: mtkView.frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = mtkView
        window.title = "Ray Tracing GPU - Real-time Renderer"
        window.makeKeyAndOrderFront(nil)
    }
}
```

#### 3.1.3 RealtimeRenderer.swift (核心)
```swift
import MetalKit

class RealtimeRenderer: NSObject, MTKViewDelegate {
    // Metal 上下文
    let context: MetalContext
    let device: MTLDevice
    let commandQueue: MTLCommandQueue

    // 渲染器（复用现有）
    let renderer: Renderer
    let pipeline: MTLComputePipelineState

    // 场景数据
    var scene: Scene
    var camera: Camera
    let bvh: FlatBVH

    // 累积渲染
    var accumulationTexture: MTLTexture!
    var sampleCount: Int = 0
    let maxSamples: Int = 100

    // 着色器管线
    var accumulationPipeline: MTLComputePipelineState!
    var blendPipeline: MTLComputePipelineState!

    // 输入控制
    let inputController: InputController
    var cameraStateTracker: CameraStateTracker

    // 统计信息
    var fpsSmooth: Double = 0.0
    var lastFrameTime: Date = Date()

    init(scene: Scene, mtkView: MTKView) {
        self.device = mtkView.device!
        self.context = MetalContext(device: device)!
        self.commandQueue = context.commandQueue

        // 加载着色器
        let library = try! device.makeDefaultLibrary(bundle: Bundle.main)!
        self.pipeline = context.makeComputePipeline(
            functionName: "raytrace",
            library: library
        )!

        // 创建渲染器（复用现有）
        self.renderer = Renderer(context: context, pipeline: pipeline)

        // 场景和相机
        self.scene = scene
        self.camera = Camera(config: scene.camera)

        // 构建 BVH
        self.bvh = FlatBVH()
        bvh.build(spheres: scene.geometry.getSpheres(),
                 quads: scene.geometry.getQuads(),
                 transforms: scene.cpuTransforms,
                 debug: false)

        // 输入控制器
        self.inputController = InputController(camera: camera)
        self.cameraStateTracker = CameraStateTracker(config: camera.config)

        super.init()

        // 初始化累积纹理
        setupAccumulationTexture(width: camera.imageWidth, height: camera.imageHeight)

        // 加载累积/混合着色器
        setupAccumulationPipelines(library: library)

        // 设置 MTKView 代理
        mtkView.delegate = self
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // 窗口大小改变时重新创建累积纹理
        setupAccumulationTexture(width: Int(size.width), height: Int(size.height))
        camera.imageWidth = Int(size.width)
        camera.imageHeight = Int(size.height)
    }

    func draw(in view: MTKView) {
        // 核心渲染循环（每帧调用）

        // 1. 计算 delta_time
        let now = Date()
        let deltaTime = now.timeIntervalSince(lastFrameTime)
        lastFrameTime = now

        // 2. 更新输入控制器
        inputController.update(deltaTime: deltaTime)

        // 3. 检测相机移动
        if cameraStateTracker.hasMoved(config: inputController.camera.config) {
            // 相机移动：重置累积
            resetAccumulation()
            cameraStateTracker.update(config: inputController.camera.config)
            camera.config = inputController.camera.config
        }

        // 4. 渲染当前帧（1 spp）
        guard let currentFrameTexture = renderer.renderToTexture(
            scene: scene,
            camera: camera,
            bvh: bvh,
            batchSize: 1  // 实时模式：每帧 1 个采样
        ) else {
            return
        }

        // 5. 累积当前帧
        accumulateFrame(currentFrameTexture: currentFrameTexture)

        // 6. 混合累积结果
        guard let finalTexture = blendAccumulation() else {
            return
        }

        // 7. 显示到屏幕
        guard let drawable = view.currentDrawable else { return }
        displayToScreen(texture: finalTexture, drawable: drawable)

        // 8. 绘制 HUD
        drawHUD(drawable: drawable, fps: fpsSmooth)

        // 9. 更新 FPS
        updateFPS(deltaTime: deltaTime)
    }

    // MARK: - 累积渲染

    func setupAccumulationTexture(width: Int, height: Int) {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float,  // 使用 Float 累积（避免精度损失）
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private

        accumulationTexture = device.makeTexture(descriptor: descriptor)!
        resetAccumulation()
    }

    func resetAccumulation() {
        sampleCount = 0
        // 清空累积纹理（使用 clear shader 或 blit encoder）
        clearTexture(accumulationTexture)
    }

    func accumulateFrame(currentFrameTexture: MTLTexture) {
        // 使用 compute shader 累积
        // accumulationTexture += currentFrameTexture
        // sampleCount++

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return
        }

        encoder.setComputePipelineState(accumulationPipeline)
        encoder.setTexture(currentFrameTexture, index: 0)      // 输入：当前帧
        encoder.setTexture(accumulationTexture, index: 1)      // 输入/输出：累积纹理

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

        sampleCount += 1
    }

    func blendAccumulation() -> MTLTexture? {
        // 混合累积结果：finalColor = accumulationTexture / sampleCount
        // 返回 BGRA8 纹理用于显示

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: accumulationTexture.width,
            height: accumulationTexture.height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]

        guard let finalTexture = device.makeTexture(descriptor: descriptor),
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return nil
        }

        encoder.setComputePipelineState(blendPipeline)
        encoder.setTexture(accumulationTexture, index: 0)  // 输入：累积纹理 (RGBA32Float)
        encoder.setTexture(finalTexture, index: 1)         // 输出：最终纹理 (BGRA8)

        var sampleCountFloat = Float(sampleCount)
        encoder.setBytes(&sampleCountFloat, length: MemoryLayout<Float>.size, index: 0)

        let threadsPerGrid = MTLSize(
            width: finalTexture.width,
            height: finalTexture.height,
            depth: 1
        )
        let threadsPerThreadgroup = MTLSize(width: 16, height: 16, depth: 1)
        encoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)

        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        return finalTexture
    }

    func displayToScreen(texture: MTLTexture, drawable: CAMetalDrawable) {
        // 使用 blit encoder 或 render pipeline 将 texture 复制到 drawable
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
            return
        }

        let origin = MTLOrigin(x: 0, y: 0, z: 0)
        let size = MTLSize(width: texture.width, height: texture.height, depth: 1)

        blitEncoder.copy(
            from: texture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: origin,
            sourceSize: size,
            to: drawable.texture,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: origin
        )

        blitEncoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // ... 其他方法
}
```

---

### 3.2 修改现有 Renderer

#### 3.2.1 添加 `renderToTexture()` 方法

```swift
// Renderer.swift

/// 渲染到纹理（用于实时模式）
/// - Returns: 渲染后的 MTLTexture (RGBA32Float)
func renderToTexture(
    scene: Scene,
    camera: Camera,
    bvh: FlatBVH,
    batchSize: Int = 1
) -> MTLTexture? {
    // 类似现有 render()，但不读取纹理数据
    // 直接返回 outputTexture

    // ... (复用现有代码) ...

    // 创建输出纹理
    guard let outputTexture = context.makeTexture(
        width: camera.imageWidth,
        height: camera.imageHeight
    ) else {
        return nil
    }

    // 执行渲染（与现有代码相同）
    // ...

    // 直接返回纹理，不读取像素数据
    return outputTexture
}
```

---

### 3.3 累积渲染着色器

#### 3.3.1 Accumulation Kernel

```metal
// Shaders/Kernels/Accumulation.metal

#include <metal_stdlib>
using namespace metal;

/// 累积内核：将当前帧累加到累积纹理
kernel void accumulate_kernel(
    texture2d<float, access::read> currentFrame [[texture(0)]],    // 当前帧 (RGBA32Float)
    texture2d<float, access::read_write> accumulation [[texture(1)]], // 累积纹理 (RGBA32Float)
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= currentFrame.get_width() || gid.y >= currentFrame.get_height()) {
        return;
    }

    float4 current = currentFrame.read(gid);
    float4 accumulated = accumulation.read(gid);

    // 累加
    accumulated += current;

    accumulation.write(accumulated, gid);
}

/// 重置累积纹理为黑色
kernel void reset_accumulation_kernel(
    texture2d<float, access::write> accumulation [[texture(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= accumulation.get_width() || gid.y >= accumulation.get_height()) {
        return;
    }

    accumulation.write(float4(0.0, 0.0, 0.0, 0.0), gid);
}
```

#### 3.3.2 Blend Kernel

```metal
// Shaders/Kernels/ColorConversion.metal

#include <metal_stdlib>
using namespace metal;

/// 混合内核：将累积纹理平均并转换为 BGRA8
/// 同时应用 gamma 校正
kernel void rgb_to_bgra8(
    texture2d<float, access::read> accumulation [[texture(0)]],   // 输入：累积纹理 (RGBA32Float)
    texture2d<uchar, access::write> output [[texture(1)]],        // 输出：显示纹理 (BGRA8)
    constant float& sampleCount [[buffer(0)]],                    // 采样数
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= accumulation.get_width() || gid.y >= accumulation.get_height()) {
        return;
    }

    // 读取累积结果
    float4 accumulated = accumulation.read(gid);

    // 平均
    float3 color = accumulated.rgb / sampleCount;

    // Gamma 校正 (gamma = 2.0)
    color = sqrt(color);

    // 箝位到 [0, 1]
    color = clamp(color, 0.0f, 1.0f);

    // 转换为 8 位 BGRA (注意颜色通道顺序)
    uchar4 bgra;
    bgra.b = uchar(color.r * 255.0);  // B <- R
    bgra.g = uchar(color.g * 255.0);  // G <- G
    bgra.r = uchar(color.b * 255.0);  // R <- B
    bgra.a = 255;

    output.write(bgra, gid);
}
```

---

### 3.4 输入控制系统

#### 3.4.1 InputController.swift

```swift
// Sources/Window/InputController.swift

import Cocoa
import simd

class InputController {
    // 相机
    var camera: Camera

    // 鼠标状态
    var mouseCaptured: Bool = false
    var firstMouse: Bool = true
    var yaw: Double = 0.0
    var pitch: Double = 0.0
    var rollAngle: Double = 0.0

    // 控制参数
    var movementSpeed: Double = 5.0       // 单位/秒
    var mouseSensitivity: Double = 0.002  // 弧度/像素

    // 键盘状态（存储按键是否按下）
    var keyStates: [UInt16: Bool] = [:]

    init(camera: Camera) {
        self.camera = camera

        // 从 look direction 计算初始 yaw/pitch
        let direction = normalize(camera.config.lookAt - camera.config.lookFrom)
        yaw = atan2(Double(direction.x), Double(direction.z))
        pitch = asin(Double(-direction.y))
    }

    /// 处理键盘按下事件
    func keyDown(with event: NSEvent) {
        keyStates[event.keyCode] = true

        // 处理特殊按键
        switch event.keyCode {
        case 53:  // ESC
            if mouseCaptured {
                releaseMouse()
            }
        case 24:  // +/=
            camera.config.defocusAngle = min(camera.config.defocusAngle + 0.1, 10.0)
        case 27:  // -
            camera.config.defocusAngle = max(camera.config.defocusAngle - 0.1, 0.0)
        case 12:  // Q
            rollAngle += Double.pi / 180.0  // 1 度
            updateVup()
        case 14:  // E
            rollAngle -= Double.pi / 180.0
            updateVup()
        default:
            break
        }
    }

    /// 处理键盘释放事件
    func keyUp(with event: NSEvent) {
        keyStates[event.keyCode] = false
    }

    /// 处理鼠标点击
    func mouseDown(with event: NSEvent) {
        if !mouseCaptured {
            captureMouse()
        }
    }

    /// 处理鼠标移动
    func mouseMoved(with event: NSEvent) {
        if !mouseCaptured { return }

        if firstMouse {
            firstMouse = false
            return
        }

        // 更新 yaw 和 pitch
        yaw -= Double(event.deltaX) * mouseSensitivity
        pitch += Double(event.deltaY) * mouseSensitivity

        // 限制 pitch
        let maxPitch = Double.pi / 2.0 - 0.01
        pitch = max(-maxPitch, min(maxPitch, pitch))

        updateLookAt()
    }

    /// 处理鼠标滚轮
    func scrollWheel(with event: NSEvent) {
        if event.deltaY > 0 {
            camera.config.focusDist = max(camera.config.focusDist - 0.5, 0.1)
        } else if event.deltaY < 0 {
            camera.config.focusDist = min(camera.config.focusDist + 0.5, 100.0)
        }
    }

    /// 更新（每帧调用）
    func update(deltaTime: TimeInterval) {
        if !mouseCaptured { return }

        // 计算前进方向（投影到 XZ 平面）
        let forward3D = camera.config.lookAt - camera.config.lookFrom
        var forwardXZ = SIMD3<Float>(forward3D.x, 0.0, forward3D.z)
        let forwardLength = length(forwardXZ)

        if forwardLength < 0.001 {
            forwardXZ = SIMD3<Float>(1.0, 0.0, 0.0)
        } else {
            forwardXZ = normalize(forwardXZ)
        }

        // 右方向
        let rightXZ = SIMD3<Float>(forwardXZ.z, 0.0, -forwardXZ.x)

        // 移动速度
        let velocity = Float(movementSpeed * deltaTime)

        var movement = SIMD3<Float>(0, 0, 0)

        // WASD 移动
        if keyStates[13] == true {  // W
            movement += forwardXZ * velocity
        }
        if keyStates[1] == true {   // S
            movement -= forwardXZ * velocity
        }
        if keyStates[0] == true {   // A
            movement += rightXZ * velocity
        }
        if keyStates[2] == true {   // D
            movement -= rightXZ * velocity
        }

        // 上下移动
        if keyStates[49] == true {  // Space
            movement.y += velocity
        }
        if keyStates[56] == true {  // Shift
            movement.y -= velocity
        }

        // 应用移动
        camera.config.lookFrom += movement
        camera.config.lookAt += movement
    }

    // MARK: - 私有方法

    private func captureMouse() {
        CGDisplayHideCursor(CGMainDisplayID())
        CGAssociateMouseAndMouseCursorPosition(0)
        mouseCaptured = true
        firstMouse = true
    }

    private func releaseMouse() {
        CGDisplayShowCursor(CGMainDisplayID())
        CGAssociateMouseAndMouseCursorPosition(1)
        mouseCaptured = false
    }

    private func updateLookAt() {
        var direction = SIMD3<Float>()
        direction.x = Float(cos(pitch) * sin(yaw))
        direction.y = Float(-sin(pitch))
        direction.z = Float(cos(pitch) * cos(yaw))

        camera.config.lookAt = camera.config.lookFrom + direction
    }

    private func updateVup() {
        let forward = normalize(camera.config.lookAt - camera.config.lookFrom)
        let worldUp = SIMD3<Float>(0, 1, 0)
        let right = normalize(cross(forward, worldUp))
        let baseUp = normalize(cross(right, forward))

        camera.config.vup = baseUp * Float(cos(rollAngle)) + right * Float(sin(rollAngle))
    }
}
```

---

### 3.5 相机状态跟踪

#### 3.5.1 CameraStateTracker.swift

```swift
// Sources/Window/CameraStateTracker.swift

import simd

/// 相机状态跟踪器：检测相机是否移动
struct CameraStateTracker {
    private var lastLookFrom: SIMD3<Float>
    private var lastLookAt: SIMD3<Float>
    private var lastVup: SIMD3<Float>
    private var lastFocusDist: Float
    private var lastDefocusAngle: Float
    private var lastVfov: Float

    init(config: CameraConfig) {
        self.lastLookFrom = config.lookFrom
        self.lastLookAt = config.lookAt
        self.lastVup = config.vup
        self.lastFocusDist = config.focusDist
        self.lastDefocusAngle = config.defocusAngle
        self.lastVfov = config.vfov
    }

    /// 检测相机是否移动
    func hasMoved(config: CameraConfig) -> Bool {
        let epsilon: Float = 0.0001

        return distance(config.lookFrom, lastLookFrom) > epsilon ||
               distance(config.lookAt, lastLookAt) > epsilon ||
               distance(config.vup, lastVup) > epsilon ||
               abs(config.focusDist - lastFocusDist) > epsilon ||
               abs(config.defocusAngle - lastDefocusAngle) > epsilon ||
               abs(config.vfov - lastVfov) > epsilon
    }

    /// 更新状态
    mutating func update(config: CameraConfig) {
        self.lastLookFrom = config.lookFrom
        self.lastLookAt = config.lookAt
        self.lastVup = config.vup
        self.lastFocusDist = config.focusDist
        self.lastDefocusAngle = config.defocusAngle
        self.lastVfov = config.vfov
    }
}
```

---

### 3.6 HUD 渲染

#### 3.6.1 HUDRenderer.swift

使用 Metal 文字渲染或 CoreText + Metal 纹理显示统计信息：
- FPS
- 帧时间
- 采样数 (spp)
- 相机位置
- 焦距、光圈、FOV

```swift
// Sources/Window/HUDRenderer.swift

import MetalKit

class HUDRenderer {
    let device: MTLDevice
    var font: CTFont

    init(device: MTLDevice) {
        self.device = device
        self.font = CTFontCreateWithName("Monaco" as CFString, 14, nil)
    }

    func drawHUD(
        drawable: CAMetalDrawable,
        fps: Double,
        sampleCount: Int,
        cameraPos: SIMD3<Float>,
        focusDist: Float,
        defocusAngle: Float,
        vfov: Float,
        rollDegrees: Double
    ) {
        // 使用 CoreText 渲染文字到纹理
        // 然后使用 render pipeline 绘制到 drawable

        let lines = [
            "FPS: \(String(format: "%.1f", fps))",
            "Samples: \(sampleCount) spp",
            "Pos: (\(String(format: "%.1f", cameraPos.x)), \(String(format: "%.1f", cameraPos.y)), \(String(format: "%.1f", cameraPos.z)))",
            "Focus: \(String(format: "%.2f", focusDist))",
            "Aperture: \(String(format: "%.2f", defocusAngle))°",
            "FOV: \(String(format: "%.1f", vfov))°",
            "Roll: \(String(format: "%.1f", rollDegrees))°"
        ]

        // ... (实现文字渲染) ...
    }
}
```

---

## 4. 实施步骤

### 阶段 1: 基础窗口显示（1-2 天）
- [ ] 创建 `Sources/Window/` 目录
- [ ] 实现 `AppDelegate.swift`（双模式支持）
- [ ] 实现 `RealtimeRenderer.swift`（基础 MTKViewDelegate）
- [ ] 测试：能否显示黑色窗口

### 阶段 2: 单帧渲染显示（1 天）
- [ ] 修改 `Renderer.swift` 添加 `renderToTexture()` 方法
- [ ] 在 `RealtimeRenderer.draw(in:)` 中调用渲染
- [ ] 使用 blit encoder 显示到 drawable
- [ ] 测试：能否显示渲染结果（无累积）

### 阶段 3: 累积渲染（1 天）
- [ ] 创建 `Shaders/Kernels/Accumulation.metal`
- [ ] 实现 `accumulate_kernel` 和 `reset_accumulation_kernel`
- [ ] 实现 `RealtimeRenderer.accumulateFrame()`
- [ ] 测试：静止时图像质量是否提升

### 阶段 4: 颜色混合和显示（0.5 天）
- [ ] 创建 `Shaders/Kernels/ColorConversion.metal`
- [ ] 实现 `rgb_to_bgra8` kernel（平均 + gamma 校正）
- [ ] 在 `draw(in:)` 中使用 blendAccumulation()
- [ ] 测试：颜色是否正确显示

### 阶段 5: 输入控制（2 天）
- [ ] 实现 `InputController.swift`（键盘 + 鼠标）
- [ ] 实现 `CameraStateTracker.swift`
- [ ] 在 `RealtimeRenderer` 中集成输入处理
- [ ] 处理 macOS 事件（keyDown, mouseDown, mouseMoved 等）
- [ ] 测试：WASD 移动、鼠标环顾

### 阶段 6: HUD 显示（1 天）
- [ ] 实现 `HUDRenderer.swift`（文字渲染）
- [ ] 在 `draw(in:)` 中绘制 HUD
- [ ] 显示 FPS、采样数、相机参数
- [ ] 测试：HUD 是否正确显示

### 阶段 7: 质量预设和优化（0.5 天）
- [ ] 添加质量预设切换（1/2/3/4 键）
- [ ] 优化性能（减少不必要的 waitUntilCompleted）
- [ ] 测试：切换质量预设是否生效

---

## 5. 关键技术要点

### 5.1 Metal 纹理格式选择

- **累积纹理**: `RGBA32Float`（高精度，避免累加误差）
- **显示纹理**: `BGRA8Unorm`（MTKView 默认格式）
- **输出纹理**: `RGBA32Float`（渲染器输出）

### 5.2 性能优化

1. **零拷贝**：纹理数据不回传到 CPU
2. **异步渲染**：使用 `commandBuffer.addCompletedHandler()` 而不是 `waitUntilCompleted()`
3. **纹理复用**：累积纹理只在分辨率改变时重新创建
4. **批次大小**：实时模式使用 `batchSize = 1`

### 5.3 兼容性

- 保持现有的 `render()` 方法用于离线模式
- 新增 `renderToTexture()` 用于实时模式
- 主程序 `main.swift` 根据 `--mode` 参数选择模式

---

## 6. 测试计划

### 6.1 单元测试

- [ ] `RealtimeRenderer` 初始化成功
- [ ] 累积纹理创建正确
- [ ] 输入控制器响应键盘事件
- [ ] 相机状态跟踪检测移动

### 6.2 集成测试

- [ ] 窗口显示正确的渲染结果
- [ ] 累积渲染达到 100 spp
- [ ] 相机移动时累积重置
- [ ] HUD 显示正确的统计信息

### 6.3 性能测试

| 场景 | 分辨率 | 目标 FPS | 实际 FPS |
|------|-------|---------|---------|
| Cornell Box | 600×600 | 60 FPS | ? |
| Bouncing Spheres | 800×450 | 60 FPS | ? |
| Final Scene | 800×800 | 30 FPS | ? |

---

## 7. 预期成果

### 功能完整性
- ✅ 实时窗口渲染（60 FPS @ 1 spp）
- ✅ 累积渲染（静止累积到 100 spp）
- ✅ FPS 相机控制（WASD + 鼠标）
- ✅ 质量预设切换（1/2/3/4 键）
- ✅ 实时 HUD 显示

### 性能目标
- Cornell Box (600×600): **60+ FPS**
- Bouncing Spheres (800×450): **60+ FPS**
- Final Scene (800×800): **30+ FPS**

### 代码质量
- 复用现有 Renderer 代码
- 最小化 Metal ↔ CPU 数据传输
- 清晰的模块化设计

---

## 8. 未来扩展

### 8.1 高级功能
- 自适应采样（快速收敛区域减少采样）
- 时间抗锯齿 (TAA)
- 降噪（AI-based Denoiser）

### 8.2 UI 增强
- ImGui 集成（参数编辑面板）
- 场景层次树显示
- 材质编辑器

---

**文档版本**: v1.0
**最后更新**: 2025-12-03
**状态**: 规划完成 → 待实施
