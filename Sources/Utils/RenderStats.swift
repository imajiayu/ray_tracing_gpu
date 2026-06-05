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

    /// 更新多行进度条（覆盖前两行，避免累积换行）
    func updateProgressMultiLine(line1: String, line2: String, isFinal: Bool = false) {
        mutex.lock()
        defer { mutex.unlock() }

        // 如果上一条是进度，先回退并清空两行
        if lastLineWasProgress {
            // 当前光标在第二行末尾（因为上次输出时 terminator: ""）
            // 需要上移两行并清空：
            // 1. \r 回到第二行行首
            // 2. [1A 上移到第一行末尾
            // 3. [2K 清空第一行（光标在第一行行首）
            // 4. [1B 下移到第二行行首
            // 5. [2K 清空第二行（光标在第二行行首）
            // 6. \r 确保在行首
            print("\r\u{001B}[1A\u{001B}[2K\u{001B}[1B\u{001B}[2K\r", terminator: "")
        }

        // 写入两行：第一行 + 换行 + 第二行
        let output = "\(line1)\n\(line2)"

        if isFinal {
            // 最后一次：输出并换行
            print(output)
            lastLineWasProgress = false
        } else {
            // 中间更新：输出但不换行，等待下次更新
            // 光标会在第二行末尾
            print(output, terminator: "")
            fflush(stdout)
            lastLineWasProgress = true
        }
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
    private let filterType: FilterType
    private let useBlueNoise: Bool
    private let tonemapMode: TonemapMode
    private let bloomStrength: Float
    private let bloomThreshold: Float

    private let startTime: Date
    private let logger = ThreadSafeLogger.shared

    init(sceneName: String, width: Int, height: Int, spp: Int, maxDepth: Int, totalBatches: Int, cameraConfig: CameraConfig, filterType: FilterType = .box, useBlueNoise: Bool = false, tonemapMode: TonemapMode = .none, bloomStrength: Float = 0.0, bloomThreshold: Float = 1.0) {
        self.sceneName = sceneName
        self.width = width
        self.height = height
        self.spp = spp
        self.maxDepth = maxDepth
        self.totalBatches = totalBatches
        self.cameraConfig = cameraConfig
        self.filterType = filterType
        self.useBlueNoise = useBlueNoise
        self.tonemapMode = tonemapMode
        self.bloomStrength = bloomStrength
        self.bloomThreshold = bloomThreshold
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
        logger.logln("  Background:  \(cam.useBackground ? "enabled" : "disabled")")
        logger.logln("──────────────────────────────────────────────────────────")

        // 打印渲染选项
        logger.logln("Render Options:")
        logger.logln("  Filter:      \(filterType.rawValue) (\(filterType.description))")
        logger.logln("  Sampling:    \(useBlueNoise ? "Blue Noise (R2 sequence)" : "Pseudo-random")")
        logger.logln("  Tonemap:     \(tonemapMode.rawValue == "aces" ? "ACES Filmic" : "None (Hard clamp)")")
        if bloomStrength > 0 {
            logger.logln("  Bloom:       \(String(format: "%.2f", bloomStrength)) (threshold: \(String(format: "%.2f", bloomThreshold)))")
        } else {
            logger.logln("  Bloom:       disabled")
        }
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
    private let filterType: FilterType
    private let useBlueNoise: Bool
    private let tonemapMode: TonemapMode
    private let bloomStrength: Float
    private let bloomThreshold: Float

    private let startTime: Date
    private let logger = ThreadSafeLogger.shared

    private var fpsSmooth: Double = 0.0
    private var lastFrameTime: Date = Date()
    private var frameCount: Int = 0
    private var lastStatsTime: Date = Date()

    init(sceneName: String, width: Int, height: Int, batchSize: Int, cameraConfig: CameraConfig, filterType: FilterType = .box, useBlueNoise: Bool = false, tonemapMode: TonemapMode = .none, bloomStrength: Float = 0.0, bloomThreshold: Float = 1.0) {
        self.sceneName = sceneName
        self.width = width
        self.height = height
        self.batchSize = batchSize
        self.cameraConfig = cameraConfig
        self.filterType = filterType
        self.useBlueNoise = useBlueNoise
        self.tonemapMode = tonemapMode
        self.bloomStrength = bloomStrength
        self.bloomThreshold = bloomThreshold
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
        logger.logln("  Background:  \(cam.useBackground ? "enabled" : "disabled")")
        logger.logln("──────────────────────────────────────────────────────────")

        // 打印渲染选项
        logger.logln("Render Options:")
        logger.logln("  Filter:      \(filterType.rawValue) (\(filterType.description))")
        logger.logln("  Sampling:    \(useBlueNoise ? "Blue Noise (R2 sequence)" : "Pseudo-random")")
        logger.logln("  Tonemap:     \(tonemapMode.rawValue == "aces" ? "ACES Filmic" : "None (Hard clamp)")")
        if bloomStrength > 0 {
            logger.logln("  Bloom:       \(String(format: "%.2f", bloomStrength)) (threshold: \(String(format: "%.2f", bloomThreshold)))")
        } else {
            logger.logln("  Bloom:       disabled")
        }
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
        logger.logln("  1/2/3/4    - Quality presets (1/2/4/8 spp/frame)")
        logger.logln("  Tab        - Toggle HUD display")
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

/// 自适应采样渲染统计
class AdaptiveRenderStats {
    private let sceneName: String
    private let width: Int
    private let height: Int
    private let minSpp: Int
    private let targetSpp: Int
    private let maxDepth: Int
    private let totalBudget: UInt64
    private let cameraConfig: CameraConfig
    private let filterType: FilterType
    private let useBlueNoise: Bool
    private let tonemapMode: TonemapMode
    private let bloomStrength: Float
    private let bloomThreshold: Float

    private let startTime: Date
    private let logger = ThreadSafeLogger.shared

    init(sceneName: String, width: Int, height: Int, minSpp: Int, targetSpp: Int, maxDepth: Int, totalBudget: UInt64, cameraConfig: CameraConfig, filterType: FilterType = .box, useBlueNoise: Bool = false, tonemapMode: TonemapMode = .none, bloomStrength: Float = 0.0, bloomThreshold: Float = 1.0) {
        self.sceneName = sceneName
        self.width = width
        self.height = height
        self.minSpp = minSpp
        self.targetSpp = targetSpp
        self.maxDepth = maxDepth
        self.totalBudget = totalBudget
        self.cameraConfig = cameraConfig
        self.filterType = filterType
        self.useBlueNoise = useBlueNoise
        self.tonemapMode = tonemapMode
        self.bloomStrength = bloomStrength
        self.bloomThreshold = bloomThreshold
        self.startTime = Date()
    }

    /// 更新 Phase 1 进度（初始均匀采样）
    func updatePhase1Progress(currentSamples: Int, totalSamples: Int, samplesPerBatch: Int) {
        let progress = Double(currentSamples) / Double(totalSamples)
        let barWidth = 24  // 控制宽度，避免过长
        let filled = Int(progress * Double(barWidth))

        let elapsed = Date().timeIntervalSince(startTime)

        var progressBar = "["
        for i in 0..<barWidth {
            if i < filled {
                progressBar += "█"
            } else {
                progressBar += "░"
            }
        }
        progressBar += "] Phase 1 \(String(format: "%5.1f", progress * 100))%"

        // 单行显示：进度条 + 详细信息
        var progressLine = progressBar
        progressLine += " | Samples \(currentSamples)/\(totalSamples)"
        if currentSamples > 0 && currentSamples < totalSamples {
            let avgTimePerSample = elapsed / Double(currentSamples)
            let remainingSamples = totalSamples - currentSamples
            let eta = avgTimePerSample * Double(remainingSamples)

            progressLine += " | ETA "
            if eta < 1 {
                progressLine += String(format: "%3dms", Int(eta * 1000))
            } else if eta < 60 {
                progressLine += String(format: "%4.1fs", eta)
            } else {
                let minutes = Int(eta / 60)
                let seconds = Int(eta.truncatingRemainder(dividingBy: 60))
                progressLine += String(format: "%dm%02ds", minutes, seconds)
            }

            let totalPixels = width * height
            let raysPerSecond = Double(totalPixels * currentSamples) / elapsed
            progressLine += String(format: " | %.1fM rays/s", raysPerSecond / 1_000_000)
        }

        // 使用单行进度条，避免多行 ANSI 序列的问题
        if currentSamples >= totalSamples {
            logger.finishProgress(progressLine)
        } else {
            logger.updateProgress(progressLine)
        }
    }

    /// 更新 Phase 2 进度（自适应采样）
    func updatePhase2Progress(usedBudget: UInt64, averageSpp: Float, convergedPercent: Float, iteration: Int) {
        let progress = Double(usedBudget) / Double(totalBudget)
        let barWidth = 24
        let filled = Int(progress * Double(barWidth))

        let elapsed = Date().timeIntervalSince(startTime)

        var progressBar = "["
        for i in 0..<barWidth {
            if i < filled {
                progressBar += "█"
            } else {
                progressBar += "░"
            }
        }
        progressBar += "] Phase 2 \(String(format: "%5.1f", progress * 100))%"

        // 单行显示：进度条 + 详细信息
        var progressLine = progressBar
        progressLine += String(format: " | Avg spp %.1f | Converged %.1f%%", averageSpp, convergedPercent)
        if usedBudget > 0 && usedBudget < totalBudget {
            let avgTimePerBudget = elapsed / Double(usedBudget)
            let remainingBudget = totalBudget - usedBudget
            let eta = avgTimePerBudget * Double(remainingBudget)

            progressLine += " | ETA "
            if eta < 1 {
                progressLine += String(format: "%3dms", Int(eta * 1000))
            } else if eta < 60 {
                progressLine += String(format: "%4.1fs", eta)
            } else {
                let minutes = Int(eta / 60)
                let seconds = Int(eta.truncatingRemainder(dividingBy: 60))
                progressLine += String(format: "%dm%02ds", minutes, seconds)
            }

            let raysPerSecond = Double(usedBudget) / elapsed
            progressLine += String(format: " | %.1fM rays/s", raysPerSecond / 1_000_000)
        }

        // 使用单行进度条，避免多行 ANSI 序列的问题
        logger.updateProgress(progressLine)
    }

    /// 完成 Phase 2（最终状态）
    func finishPhase2(usedBudget: UInt64, averageSpp: Float, convergedPercent: Float) {
        let progress = Double(usedBudget) / Double(totalBudget)
        let barWidth = 24
        let filled = Int(progress * Double(barWidth))

        var progressBar = "["
        for i in 0..<barWidth {
            if i < filled {
                progressBar += "█"
            } else {
                progressBar += "░"
            }
        }
        progressBar += "] Phase 2 \(String(format: "%5.1f", progress * 100))%"

        let progressLine = progressBar + String(format: " | Avg spp %.1f | Converged %.1f%%", averageSpp, convergedPercent)

        logger.finishProgress(progressLine)
    }
}
