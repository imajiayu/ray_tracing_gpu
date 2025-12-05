// RenderStats.swift
// 渲染统计模块 - 提供进度条、计时、FPS 等统计信息

import Foundation

/// 线程安全的日志工具
class ThreadSafeLogger {
    static let shared = ThreadSafeLogger()

    private var lastLineWasProgress = false
    private let mutex = NSLock()

    private init() {}

    /// 输出普通日志
    func log(_ message: String) {
        mutex.lock()
        defer { mutex.unlock() }

        if lastLineWasProgress {
            print()  // 进度条后换行
            lastLineWasProgress = false
        }
        print(message, terminator: "")
        fflush(stdout)
    }

    /// 输出带换行的日志
    func logln(_ message: String) {
        mutex.lock()
        defer { mutex.unlock() }

        if lastLineWasProgress {
            print()  // 进度条后换行
            lastLineWasProgress = false
        }
        print(message)
        fflush(stdout)
    }

    /// 更新进度条（覆盖当前行）
    func updateProgress(_ message: String) {
        mutex.lock()
        defer { mutex.unlock() }

        // 使用 \r 回到行首并覆盖之前的内容
        print("\r\(message)", terminator: "")
        fflush(stdout)
        lastLineWasProgress = true
    }

    /// 完成进度（换行）
    func finishProgress(_ message: String) {
        mutex.lock()
        defer { mutex.unlock() }

        print("\r\(message)")
        fflush(stdout)
        lastLineWasProgress = false
    }
}

/// 图片模式渲染统计
class ImageRenderStats {
    private let sceneName: String
    private let width: Int
    private let height: Int
    private let spp: Int
    private let maxDepth: Int
    private let totalBatches: Int
    private let cameraConfig: CameraConfig

    private let startTime: Date
    private let logger = ThreadSafeLogger.shared

    init(sceneName: String, width: Int, height: Int, spp: Int, maxDepth: Int, totalBatches: Int, cameraConfig: CameraConfig) {
        self.sceneName = sceneName
        self.width = width
        self.height = height
        self.spp = spp
        self.maxDepth = maxDepth
        self.totalBatches = totalBatches
        self.cameraConfig = cameraConfig
        self.startTime = Date()
    }

    /// 打印渲染头部信息
    func printHeader(sphereCount: Int, quadCount: Int, bvhNodeCount: Int, lightsCount: Int) {
        logger.logln("")
        logger.logln("╔══════════════════════════════════════════════════════════╗")
        logger.logln("║          Ray Tracing GPU - Offline Renderer             ║")
        logger.logln("╚══════════════════════════════════════════════════════════╝")
        logger.logln("")
        logger.logln("Scene:         \(sceneName)")
        logger.logln("Resolution:    \(width) × \(height) (\(width * height) pixels)")
        logger.logln("Samples/Pixel: \(spp)")
        logger.logln("Max Depth:     \(maxDepth)")
        logger.logln("──────────────────────────────────────────────────────────")
        logger.logln("Geometry:      \(sphereCount) spheres, \(quadCount) quads")
        logger.logln("BVH:           \(bvhNodeCount) nodes")
        logger.logln("Lights:        \(lightsCount) lights (MIS enabled)")
        logger.logln("──────────────────────────────────────────────────────────")

        // 打印相机参数
        let cam = cameraConfig
        logger.logln("Camera:")
        logger.logln("  Position:    (\(String(format: "%.2f", cam.lookFrom.x)), \(String(format: "%.2f", cam.lookFrom.y)), \(String(format: "%.2f", cam.lookFrom.z)))")
        logger.logln("  Look At:     (\(String(format: "%.2f", cam.lookAt.x)), \(String(format: "%.2f", cam.lookAt.y)), \(String(format: "%.2f", cam.lookAt.z)))")
        logger.logln("  VUp:         (\(String(format: "%.2f", cam.vup.x)), \(String(format: "%.2f", cam.vup.y)), \(String(format: "%.2f", cam.vup.z)))")
        logger.logln("  VFov:        \(String(format: "%.1f", cam.vfov))°")
        logger.logln("  Focus Dist:  \(String(format: "%.2f", cam.focusDist))")
        logger.logln("  Defocus:     \(String(format: "%.2f", cam.defocusAngle))° \(cam.defocusAngle > 0 ? "(DoF enabled)" : "(DoF disabled)")")
        logger.logln("──────────────────────────────────────────────────────────")
        logger.logln("")
    }

    /// 更新渲染进度
    func updateProgress(batch: Int, samplesPerBatch: Int) {
        let progress = Double(batch + 1) / Double(totalBatches)
        let barWidth = 30  // 减小进度条宽度以适应终端
        let filled = Int(progress * Double(barWidth))

        // 计算 ETA
        let elapsed = Date().timeIntervalSince(startTime)

        var progressBar = "["
        for i in 0..<barWidth {
            if i < filled {
                progressBar += "█"
            } else {
                progressBar += "░"
            }
        }
        progressBar += "] \(String(format: "%3d", batch + 1))/\(totalBatches) (\(String(format: "%5.1f", progress * 100))%)"

        // 添加 ETA 和速度信息
        if batch > 0 && batch < totalBatches - 1 {
            let avgTimePerBatch = elapsed / Double(batch + 1)
            let remainingBatches = totalBatches - (batch + 1)
            let eta = avgTimePerBatch * Double(remainingBatches)

            progressBar += " | ETA: "
            if eta < 1 {
                progressBar += String(format: "%3dms", Int(eta * 1000))
            } else if eta < 60 {
                progressBar += String(format: "%4.1fs", eta)
            } else {
                let minutes = Int(eta / 60)
                let seconds = Int(eta.truncatingRemainder(dividingBy: 60))
                progressBar += String(format: "%dm%02ds", minutes, seconds)
            }

            // 添加采样速度
            let totalPixels = width * height
            let samplesCompleted = samplesPerBatch * (batch + 1)
            let raysPerSecond = Double(totalPixels * samplesCompleted) / elapsed
            progressBar += String(format: " | %.1fM rays/s", raysPerSecond / 1_000_000)
        }

        // 填充空格清除旧内容（最多 10 个空格，避免过长）
        let padding = String(repeating: " ", count: 10)
        progressBar += padding

        if batch == totalBatches - 1 {
            logger.finishProgress(progressBar)
        } else {
            logger.updateProgress(progressBar)
        }
    }

    /// 打印渲染总结
    func printSummary(renderTime: TimeInterval) {
        logger.logln("")
        logger.logln("──────────────────────────────────────────────────────────")
        logger.logln("")
        logger.logln("✓ Rendering Complete")
        logger.logln("")

        let timeMs = renderTime * 1000
        logger.logln(String(format: "Total Time:    %.0f ms (%.2f seconds)", timeMs, renderTime))

        // 计算吞吐量
        let totalPixels = width * height
        let totalRays = totalPixels * spp
        let pixelsPerSecond = Double(totalPixels) / renderTime
        let raysPerSecond = Double(totalRays) / renderTime

        logger.logln(String(format: "Throughput:    %.0fK pixels/s, %.1fM rays/s",
                           pixelsPerSecond / 1000,
                           raysPerSecond / 1_000_000))

        logger.logln(String(format: "Time/Pixel:    %.2f μs", renderTime * 1_000_000 / Double(totalPixels)))

        logger.logln("")
        logger.logln("══════════════════════════════════════════════════════════")
        logger.logln("")
    }
}

/// 窗口模式渲染统计
class WindowRenderStats {
    private let sceneName: String
    private let width: Int
    private let height: Int
    private let batchSize: Int
    private var cameraConfig: CameraConfig

    private let startTime: Date
    private let logger = ThreadSafeLogger.shared

    private var fpsSmooth: Double = 0.0
    private var lastFrameTime: Date = Date()
    private var frameCount: Int = 0
    private var lastStatsTime: Date = Date()

    init(sceneName: String, width: Int, height: Int, batchSize: Int, cameraConfig: CameraConfig) {
        self.sceneName = sceneName
        self.width = width
        self.height = height
        self.batchSize = batchSize
        self.cameraConfig = cameraConfig
        self.startTime = Date()
        self.lastFrameTime = Date()
        self.lastStatsTime = Date()
    }

    /// 打印窗口模式头部信息
    func printHeader(sphereCount: Int, quadCount: Int, bvhNodeCount: Int, lightsCount: Int) {
        logger.logln("")
        logger.logln("╔══════════════════════════════════════════════════════════╗")
        logger.logln("║          Ray Tracing GPU - Realtime Renderer            ║")
        logger.logln("╚══════════════════════════════════════════════════════════╝")
        logger.logln("")
        logger.logln("Scene:         \(sceneName)")
        logger.logln("Resolution:    \(width) × \(height)")
        logger.logln("Samples/Frame: \(batchSize) spp")
        logger.logln("──────────────────────────────────────────────────────────")
        logger.logln("Geometry:      \(sphereCount) spheres, \(quadCount) quads")
        logger.logln("BVH:           \(bvhNodeCount) nodes")
        logger.logln("Lights:        \(lightsCount) lights (MIS enabled)")
        logger.logln("──────────────────────────────────────────────────────────")

        // 打印初始相机参数
        let cam = cameraConfig
        logger.logln("Camera (Initial):")
        logger.logln("  Position:    (\(String(format: "%.2f", cam.lookFrom.x)), \(String(format: "%.2f", cam.lookFrom.y)), \(String(format: "%.2f", cam.lookFrom.z)))")
        logger.logln("  Look At:     (\(String(format: "%.2f", cam.lookAt.x)), \(String(format: "%.2f", cam.lookAt.y)), \(String(format: "%.2f", cam.lookAt.z)))")
        logger.logln("  VUp:         (\(String(format: "%.2f", cam.vup.x)), \(String(format: "%.2f", cam.vup.y)), \(String(format: "%.2f", cam.vup.z)))")
        logger.logln("  VFov:        \(String(format: "%.1f", cam.vfov))°")
        logger.logln("  Focus Dist:  \(String(format: "%.2f", cam.focusDist))")
        logger.logln("  Defocus:     \(String(format: "%.2f", cam.defocusAngle))° \(cam.defocusAngle > 0 ? "(DoF enabled)" : "(DoF disabled)")")
        logger.logln("──────────────────────────────────────────────────────────")
        logger.logln("")
        logger.logln("Controls:")
        logger.logln("  Left Click - Capture mouse (enable camera control)")
        logger.logln("  ESC        - Release mouse / Exit")
        logger.logln("  WASD       - Move camera")
        logger.logln("  Space      - Move up")
        logger.logln("  Shift      - Move down")
        logger.logln("  Mouse      - Look around")
        logger.logln("  Q/E        - Camera roll")
        logger.logln("  Wheel      - Adjust focus distance")
        logger.logln("  +/-        - Adjust aperture")
        logger.logln("  1/2/3/4    - Quality presets")
        logger.logln("══════════════════════════════════════════════════════════")
        logger.logln("")
    }

    /// 更新帧统计（带实时相机参数）
    func updateFrame(deltaTime: TimeInterval, sampleCount: Int, currentCamera: CameraConfig) {
        frameCount += 1
        self.cameraConfig = currentCamera  // 更新相机状态

        // 更新平滑 FPS
        let instantFPS = 1.0 / deltaTime
        let alpha = 0.1

        if fpsSmooth == 0.0 {
            fpsSmooth = instantFPS
        } else {
            fpsSmooth = alpha * instantFPS + (1.0 - alpha) * fpsSmooth
        }

        // 每帧更新统计（覆盖当前行）
        let totalPixels = width * height
        let raysPerSecond = fpsSmooth * Double(totalPixels) * Double(batchSize)

        let cam = currentCamera
        var statsLine = String(format: "F:%4d | FPS:%5.1f | spp:%4d | %.1fM r/s | Pos:(%.1f,%.1f,%.1f) | Foc:%.1f | DoF:%.2f°",
                               frameCount,
                               fpsSmooth,
                               sampleCount,
                               raysPerSecond / 1_000_000,
                               cam.lookFrom.x, cam.lookFrom.y, cam.lookFrom.z,
                               cam.focusDist,
                               cam.defocusAngle)

        // 填充空格清除旧内容
        statsLine += String(repeating: " ", count: 10)

        logger.updateProgress(statsLine)
        lastStatsTime = Date()
    }

    /// 获取当前 FPS
    func getCurrentFPS() -> Double {
        return fpsSmooth
    }
}
