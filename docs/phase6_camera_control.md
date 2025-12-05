# Phase 6: 相机控制与累积渲染策略

**创建日期**: 2025-12-04
**状态**: 设计完成 → 待实施

---

## 📋 概述

本文档定义了实时窗口模式下的相机控制系统和累积渲染缓冲区管理策略。

**核心目标**:
1. 实现流畅的 FPS 风格相机控制
2. 智能管理累积渲染缓冲区，避免画面突变
3. 提供平滑的用户体验

---

## 🎮 键鼠操作映射

### 1. 鼠标控制

| 操作 | 功能 | 说明 |
|------|------|------|
| **左键点击** | 捕获鼠标 | 进入 FPS 控制模式，隐藏光标 |
| **ESC 键** | 释放鼠标 / 退出程序 | 第一次：退出 FPS 模式<br>第二次（未捕获状态）：关闭窗口 |
| **鼠标移动** | 视角旋转 | 捕获状态下，左右旋转（Yaw），上下俯仰（Pitch）|
| **鼠标滚轮↑** | 减小焦距 | `focus_dist -= 0.5` (最小 0.1) |
| **鼠标滚轮↓** | 增加焦距 | `focus_dist += 0.5` (最大 100.0) |

### 2. 键盘移动控制

| 按键 | 功能 | 说明 |
|------|------|------|
| **W** | 向前移动 | 沿水平面（XZ 平面）向前移动 |
| **S** | 向后移动 | 沿水平面（XZ 平面）向后移动 |
| **A** | 向左平移 | 沿水平面（XZ 平面）向左平移 |
| **D** | 向右平移 | 沿水平面（XZ 平面）向右平移 |
| **Space** | 向上移动 | 沿世界 Y 轴向上移动 |
| **Left Shift** | 向下移动 | 沿世界 Y 轴向下移动 |

**技术要点**:
- WASD 移动仅在 XZ 平面，不受相机俯仰角影响
- 使用 `delta_time` 确保帧率无关的移动速度
- 移动同时更新 `look_from` 和 `look_at`，保持视角方向

### 3. 键盘相机调整

| 按键 | 功能 | 说明 |
|------|------|------|
| **Q** | 相机右滚 | 视角右倾斜 1°（Camera Roll Right）|
| **E** | 相机左滚 | 视角左倾斜 1°（Camera Roll Left）|
| **+** / **=** | 增加光圈 | `defocus_angle += 0.1` (最大 10.0) |
| **-** | 减小光圈 | `defocus_angle -= 0.1` (最小 0.0) |

### 4. 质量和 UI 控制

| 按键 | 功能 | 说明 |
|------|------|------|
| **1** | Preview 质量 | `batch_size = 1` spp/frame（快速预览）|
| **2** | Medium 质量 | `batch_size = 4` spp/frame（平衡模式）|
| **3** | High 质量 | `batch_size = 8` spp/frame（高质量）|
| **Tab** | 切换 HUD 显示 | 显示/隐藏实时统计信息 |

**注意**: 初始 batch_size 由用户启动窗口程序时的命令行参数 `--spp` 决定，1/2/3 键可在运行时切换。

---

## 🧠 累积渲染缓冲区管理策略

### 核心问题

累积渲染通过逐帧叠加样本来降低噪声，但当相机参数改变时，历史样本可能失效。

**关键问题**:
- 哪些参数变化需要重置累积？
- 如何避免画面突变（噪点爆炸）？
- 如何在响应速度和画质之间平衡？

---

### 参数变化分类

#### 1. **主要参数变化** - 完全重置 ❌

| 参数 | 原因 |
|------|------|
| `look_from` (相机位置) | 视点改变，所有像素的光线起点变化 |
| `look_at` (观察点) | 视角方向改变，所有像素的光线方向变化 |
| `vup` (上方向) | 相机滚转，视口旋转 |
| `vfov` (视野角) | 视口大小改变，所有像素的光线方向变化 |

**处理策略**: 使用 **预渲染缓冲区** (见下文)

#### 2. **次要参数变化** - 权重衰减 ⚠️

| 参数 | 原因 |
|------|------|
| `defocus_angle` (光圈) | 只影响景深，主体场景不变 |
| `focus_dist` (焦距) | 只影响景深，主体场景不变 |

**处理策略**:
```swift
// 降低历史权重，让新样本快速占主导
accumulatedSamples = min(accumulatedSamples / 2, 10)
// 不清空缓冲区，保留部分正确的采样
```

**优点**:
- 画面平滑过渡，无突变
- 保留焦点附近的正确采样
- 2-3 秒收敛到新参数

**缺点**:
- 焦外区域短暂"鬼影"（旧景深 + 新景深混合）

#### 3. **UI 参数变化** - 无需重置 ✅

| 参数 | 原因 |
|------|------|
| `batch_size` (质量预设) | 只影响每帧采样数，不影响渲染结果 |
| `HUD 显示开关` | UI 参数 |

**处理策略**: 保持累积，无任何操作

---

### 🚀 预渲染缓冲区策略（核心创新）

**问题**: 主要参数变化时，传统做法是立即清空累积缓冲区 → 用户看到噪点画面 → 体验差

**解决方案**: 延迟显示，先预渲染到足够质量再呈现

#### 实现机制

```swift
enum RenderState {
    case normal              // 正常累积渲染
    case preRendering        // 预渲染中（不显示）
}

class RealtimeRenderer {
    var renderState: RenderState = .normal
    var preRenderTargetSamples: UInt32 = 0  // 预渲染目标样本数
    var hiddenAccumulationBuffer: MTLTexture?  // 隐藏的累积缓冲区

    func handleMajorCameraChange() {
        // 1. 切换到预渲染模式
        renderState = .preRendering
        preRenderTargetSamples = 16  // 目标：16 spp
        accumulatedSamples = 0

        // 2. 清空隐藏缓冲区
        resetAccumulationBuffer(hiddenAccumulationBuffer)

        // 3. 不清空显示缓冲区（保持旧画面）
        // 用户继续看到旧画面，不会看到噪点
    }

    func draw(in view: MTKView) {
        if renderState == .preRendering {
            // 渲染到隐藏缓冲区
            renderToTexture(hiddenAccumulationBuffer, samples: accumulatedSamples)
            accumulatedSamples += batchSize

            // 检查是否达到目标
            if accumulatedSamples >= preRenderTargetSamples {
                // 切换显示：隐藏缓冲区 → 显示缓冲区
                swap(&hiddenAccumulationBuffer, &accumulationBuffer)
                renderState = .normal
            } else {
                // 继续显示旧画面（不更新屏幕）
                return
            }
        } else {
            // 正常累积渲染
            renderToTexture(accumulationBuffer, samples: accumulatedSamples)
            accumulatedSamples += batchSize
        }

        // 显示到屏幕
        blitToScreen(view, from: accumulationBuffer)
    }
}
```

#### 参数调优

| 质量预设 | batch_size | 预渲染目标 spp | 预渲染延迟 |
|----------|-----------|---------------|-----------|
| **Preview** | 1 | 8 spp | ~8 帧 (~133 ms @ 60 FPS) |
| **Medium** | 4 | 16 spp | ~4 帧 (~67 ms @ 60 FPS) |
| **High** | 8 | 24 spp | ~3 帧 (~50 ms @ 60 FPS) |

**用户体验**:
- 移动相机后，画面"冻结" 50-133 ms
- 然后直接切换到高质量画面（16-24 spp）
- 避免噪点画面闪烁

#### 优势

✅ **无噪点闪烁**: 用户永远看不到低质量画面
✅ **延迟可控**: 50-133 ms 几乎无感知
✅ **实现简单**: 只需双缓冲区 + 状态机
✅ **自适应**: 根据质量预设自动调整目标 spp

#### 潜在问题与优化

**问题 1**: 快速连续移动相机时，预渲染可能被频繁打断

**解决方案**:
```swift
var lastCameraChangeTime: TimeInterval = 0
let cameraChangeDebounce: TimeInterval = 0.1  // 100ms 防抖

func handleCameraChange() {
    let now = CACurrentMediaTime()
    if now - lastCameraChangeTime < cameraChangeDebounce {
        // 忽略过快的变化
        return
    }
    lastCameraChangeTime = now
    startPreRendering()
}
```

**问题 2**: 显存占用翻倍（双缓冲区）

**解决方案**:
- Cornell Box (600×600): `600×600×16B×2 = 11 MB` → 可接受
- Final Scene (800×800): `800×800×16B×2 = 20 MB` → 可接受
- 现代 GPU 完全可以承受

---

### 最终策略总结

| 参数变化类型 | 重置策略 | 用户体验 |
|-------------|---------|----------|
| **位置/视角/FOV** | 预渲染缓冲区 (16-24 spp) | 画面冻结 50-133 ms，然后切换到高质量画面 |
| **光圈/焦距** | 权重衰减 (samples/2) | 平滑过渡，2-3 秒收敛 |
| **质量预设** | 无操作 | 立即生效，无中断 |

---

## 🏗️ 技术架构

### 核心组件

#### 1. InputController (Sources/Window/InputController.swift)

**职责**:
- 处理键盘鼠标输入
- 更新 CameraConfig
- 触发相机变化事件

**关键方法**:
```swift
class InputController {
    var config: CameraConfig
    var isMouseCaptured: Bool
    var yaw: Float
    var pitch: Float
    var rollAngle: Float

    func processEvent(_ event: NSEvent) -> Bool
    func update(deltaTime: TimeInterval)
    func setMovementSpeed(_ speed: Float)
    func setMouseSensitivity(_ sensitivity: Float)
}
```

**参考实现**: `~/ray_tracing/include/camera/input_controller.h`

#### 2. CameraStateTracker (Sources/Camera/CameraConfig.swift)

**职责**:
- 检测相机参数变化
- 分类变化类型（major/minor/none）

**关键方法**:
```swift
enum CameraChangeType {
    case none    // 无变化
    case major   // 位置/视角/FOV → 预渲染
    case minor   // 景深 → 权重衰减
}

class CameraStateTracker {
    func detectChange(current: CameraConfig) -> CameraChangeType
    func update(config: CameraConfig)
}
```

**检测逻辑**:
```swift
func detectChange(current: CameraConfig) -> CameraChangeType {
    // 检查主要参数
    if !vec3Equals(current.lookFrom, last.lookFrom) { return .major }
    if !vec3Equals(current.lookAt, last.lookAt) { return .major }
    if !vec3Equals(current.vup, last.vup) { return .major }
    if current.vfov != last.vfov { return .major }

    // 检查次要参数
    if current.defocusAngle != last.defocusAngle { return .minor }
    if current.focusDist != last.focusDist { return .minor }

    return .none
}
```

#### 3. RealtimeRenderer (Sources/Rendering/RealtimeRenderer.swift)

**职责**:
- 集成 InputController
- 管理累积渲染缓冲区
- 实现预渲染逻辑

**关键状态**:
```swift
enum RenderState {
    case normal
    case preRendering
}

class RealtimeRenderer {
    var renderState: RenderState
    var accumulationBuffer: MTLTexture        // 显示缓冲区
    var hiddenAccumulationBuffer: MTLTexture  // 预渲染缓冲区
    var accumulatedSamples: UInt32
    var batchSize: UInt32  // 质量预设
    var preRenderTargetSamples: UInt32
}
```

#### 4. WindowDelegate (Sources/Window/WindowDelegate.swift)

**职责**:
- 处理窗口事件
- 实现 ESC 双击退出逻辑

**关键逻辑**:
```swift
class WindowDelegate: NSObject, NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // ESC 双击退出逻辑
        if inputController.isMouseCaptured {
            return false  // 第一次 ESC：释放鼠标
        } else {
            return true   // 第二次 ESC：关闭窗口
        }
    }
}
```

---

## 🎯 实施计划

### Phase 6.1: 基础相机控制

- [x] 创建 InputController
- [x] 实现 WASD 移动
- [x] 实现鼠标视角控制
- [x] 实现 Q/E 滚转
- [x] 实现 +/- 光圈调整
- [x] 实现鼠标滚轮焦距调整

### Phase 6.2: 质量与 UI 控制

- [x] 实现 1/2/3 质量预设切换
- [x] 实现 Tab HUD 切换
- [x] 实现 ESC 双击退出

### Phase 6.3: 智能累积管理

- [x] 实现 CameraChangeType 检测
- [x] 实现权重衰减策略（minor change）
- [x] 实现预渲染缓冲区（major change）
- [x] 实现双缓冲区切换逻辑
- [x] 实现相机变化防抖

### Phase 6.4: 集成与测试

- [x] 集成到 RealtimeRenderer
- [x] 测试所有键鼠操作
- [x] 性能测试（60 FPS 目标）
- [x] 优化预渲染参数

---

## 📊 性能目标

| 场景 | 分辨率 | Preview (1 spp) | Medium (4 spp) | High (8 spp) |
|------|-------|-----------------|----------------|--------------|
| Cornell Box | 600×600 | 60+ FPS | 60+ FPS | 30-60 FPS |
| Bouncing Spheres | 800×450 | 60+ FPS | 60+ FPS | 30-60 FPS |
| Final Scene | 800×800 | 60+ FPS | 30-60 FPS | 15-30 FPS |

**预渲染延迟**:
- Preview: ~133 ms (8 帧 @ 60 FPS)
- Medium: ~67 ms (4 帧 @ 60 FPS)
- High: ~50 ms (3 帧 @ 60 FPS)

---

## 🔧 技术参数

| 参数 | 默认值 | 可调范围 | 说明 |
|------|--------|---------|------|
| `movement_speed` | 5.0 | 1.0 - 20.0 | 单位/秒 |
| `mouse_sensitivity` | 0.002 | 0.0005 - 0.01 | 弧度/像素 |
| `pitch_limit` | ±89.4° | - | 防止万向节锁死 |
| `roll_increment` | 1° | - | 每次按键增量 |
| `defocus_increment` | 0.1 | - | 光圈调整步长 |
| `focus_dist_increment` | 0.5 | - | 焦距调整步长 |
| `camera_debounce` | 100 ms | - | 相机变化防抖 |
| `pre_render_samples` | 16-24 | 8-32 | 根据质量预设 |

---

## 📚 参考资源

- **CPU 版本**: `~/ray_tracing/include/camera/input_controller.h`
- **Phase 6 整体设计**: `docs/phase6_realtime_window.md`
- **相机数学**: Peter Shirley - "Ray Tracing in One Weekend"
- **FPS 相机控制**: Learn OpenGL - Camera Tutorial

---

**文档版本**: v1.0
**最后更新**: 2025-12-04
**状态**: 设计完成 → 待实施
