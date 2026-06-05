// CommandLineArgs.swift
// 命令行参数解析

import Foundation

/// Tone Mapping 模式
enum TonemapMode: String {
    case none = "none"  // 硬截断（向后兼容）
    case aces = "aces"  // ACES Filmic
}

/// 命令行参数结构
struct CommandLineArgs {
    var sceneName: String = "bouncingSpheres"  // 默认场景（通常是索引 0）
    var mode: String = "image"  // "image" or "window"
    var outputFile: String? = nil  // 输出文件名，nil 表示自动生成
    var spp: Int? = nil  // 总采样数，nil 表示使用默认值或场景值
    var minSpp: Int? = nil  // 最小采样数（启用自适应采样，与 spp 配合使用）
    var batchSize: Int? = nil  // 每批 GPU 计算的采样数，nil 表示使用默认值
    var maxDepth: Int? = nil  // 最大反弹深度，nil 表示使用默认值或场景值
    var width: Int? = nil  // 图像宽度，nil 表示使用默认值或场景值
    var vfov: Float? = nil  // 视野角度（FOV），nil 表示使用场景配置
    var defocusAngle: Float? = nil  // 散焦角度（景深），nil 表示不使用景深
    var focusDist: Float? = nil  // 焦平面距离，nil 表示使用场景默认值或自动计算
    var useBackground: Bool? = nil  // 是否使用天空背景，nil 表示使用场景配置
    var tonemapMode: TonemapMode = .none  // Tone Mapping 模式，默认 none（向后兼容）
    var bloomStrength: Float = 0.0  // Bloom 强度，0.0 = 关闭，0.1-0.5 = 推荐
    var bloomThreshold: Float = 1.0  // Bloom 亮度阈值，默认 1.0
    var filterType: FilterType = .box  // 像素重建滤波器，默认 box（均匀平均）
    var useBlueNoise: Bool = false  // 是否使用蓝噪声采样（R2 序列），默认 false（伪随机）
    var useWeightedVariance: Bool = false  // 是否使用材质加权方差（针对镜面/玻璃优化），默认 false

    // 自适应采样高级参数（仅限 image 模式）
    var adaptiveVarianceThreshold: Float = 0.0000001  // 方差阈值，默认 1e-07（批量采样校准）
    var adaptiveRelativeThreshold: Float = 0.005  // 相对误差阈值，默认 0.005 (0.5%)
    var adaptiveBatchSize: Int = 8  // 自适应批次大小，默认 8

    // 计算属性：是否启用自适应采样
    var useAdaptiveSampling: Bool {
        return minSpp != nil
    }

    // 获取实际的 batchSize（根据模式提供默认值）
    func getEffectiveBatchSize() -> Int {
        if let batchSize = batchSize {
            return batchSize
        }
        // 默认值：image 模式 10，window 模式 1
        return mode == "window" ? 1 : 10
    }

    /// 打印帮助信息
    static func printHelp(programName: String) {
        // 获取所有可用场景
        let scenes = getAvailableScenes()

        print("""
        ╔══════════════════════════════════════════════════════════════════╗
        ║         Ray Tracing GPU - Metal 光线追踪渲染器                  ║
        ╚══════════════════════════════════════════════════════════════════╝

        用法: \(programName) [选项]

        ┌──────────────────────────────────────────────────────────────────┐
        │ 渲染模式                                                         │
        └──────────────────────────────────────────────────────────────────┘
          --mode <mode>         渲染模式
                                  image  - 离线图片渲染 (输出 PPM 文件)
                                  window - 实时窗口预览 (60 FPS 交互)
                                  系统默认: image

        ┌──────────────────────────────────────────────────────────────────┐
        │ 场景选择                                                         │
        └──────────────────────────────────────────────────────────────────┘
          --scene <name|num>    场景名称或编号
                                  系统默认: 0 (bouncingSpheres)
        """)

        // 动态列出所有场景（带编号）
        for (index, scene) in scenes.enumerated() {
            let marker = index == 0 ? " (默认)" : ""
            print("                                  \(index) - \(scene)\(marker)")
        }

        print("""

        ┌──────────────────────────────────────────────────────────────────┐
        │ 渲染质量 (优先级: 用户设置 > 场景配置 > 系统默认)              │
        └──────────────────────────────────────────────────────────────────┘
          --spp <num>           总采样数（固定或自适应的预算）
                                  固定采样: 仅用 --spp
                                  自适应采样: --spp + --min-spp
                                  推荐: 10-100 (预览), 500-1000 (高质量)
                                  系统默认: image 模式 1000, window 模式无限累积
          --min-spp <num>       自适应采样：每个像素的最小采样数
                                  必须配合 --spp 使用
                                  总预算 = width × height × spp
                                  每个像素至少采样 min-spp 次
                                  剩余预算优先分配给高方差区域
                                  推荐: 4-32
          --max-depth <num>     光线最大反弹深度
                                  推荐: 10-50
                                  系统默认: 50
          --batch-size <num>    每批 GPU 采样数
                                  window 模式: 1-8 (影响帧率和质量)
                                  系统默认: image 模式 10, window 模式 1

        ┌──────────────────────────────────────────────────────────────────┐
        │ 相机参数 (优先级: 用户设置 > 场景配置 > 系统默认)              │
        └──────────────────────────────────────────────────────────────────┘
          --width <num>         图像宽度 (像素)
                                  系统默认: 1024
          --vfov <degrees>      相机视野角度 (度)
                                  推荐: 广角 90-120, 标准 40-60, 长焦 10-30
                                  系统默认: 使用场景配置 (通常 40° 或 90°)
          --defocus-angle <deg> 景深散焦角度 (度)
                                  0 = 无景深, 0.5-2.0 = 适度景深
                                  系统默认: 使用场景配置 (通常为 0)
          --focus-dist <dist>   焦平面距离
                                  系统默认: 使用场景配置 (自动计算)

        ┌──────────────────────────────────────────────────────────────────┐
        │ 渲染选项 (优先级: 用户设置 > 场景配置)                         │
        └──────────────────────────────────────────────────────────────────┘
          --background          启用天空背景渐变
          --no-background       禁用天空背景 (纯黑背景)
                                  系统默认: 使用场景配置 (通常开启)
                                  适用: 室外场景用 --background, 室内场景用 --no-background
          --tonemap <mode>      Tone Mapping 模式
                                  none - 硬截断 (当前默认，向后兼容)
                                  aces - ACES Filmic (好莱坞标准，保留高光细节)
                                  系统默认: none
          --bloom <strength>    Bloom 光晕强度 (0.0-1.0)
                                  0.0 = 关闭 (默认), 0.2-0.3 = 推荐
                                  注意: 开启 Bloom 会自动启用 ACES Tone Mapping
                                  系统默认: 0.0
          --bloom-threshold <val> Bloom 亮度阈值 (0.5-2.0)
                                  只有亮度超过此值的像素才产生光晕
                                  系统默认: 1.0
          --filter <type>         像素重建滤波器
                                  box      - 均匀平均 (最快，默认)
                                  tent     - 三角形/锥形 (平滑)
                                  gaussian - 高斯 (自然)
                                  mitchell - Mitchell-Netravali (平衡)
                                  lanczos  - Lanczos (最高质量)
                                  系统默认: box
          --blue-noise            启用蓝噪声采样 (R2 低差异序列)
                                  优点: 低 spp 下视觉质量更好，噪点分布均匀
                                  推荐: 实时模式 (1-8 spp/frame) 或快速预览 (spp < 16)
                                  系统默认: 关闭（伪随机采样）

        ┌──────────────────────────────────────────────────────────────────┐
        │ 自适应采样高级参数 (仅在使用 --min-spp 时有效)                   │
        └──────────────────────────────────────────────────────────────────┘
          --weighted-variance       启用材质加权方差（实验性）
                                  针对镜面反射/玻璃透射优化
                                  根据像素颜色特征估计材质类型
                                  对高亮区域（镜面/玻璃）使用更严格的阈值
                                  推荐: Cornell Box 等包含镜面/玻璃的场景
                                  系统默认: 关闭（标准方差）
          --adaptive-threshold <val> 方差阈值（绝对值）
                                  更小 = 更高质量，更多采样
                                  系统默认: 1e-07
          --adaptive-relative-error <val> 相对误差阈值（百分比）
                                  系统默认: 0.005 (0.5%)
          --adaptive-batch-size <N> 每批次增量采样数
                                  推荐范围: 4-16
                                  系统默认: 8

        ┌──────────────────────────────────────────────────────────────────┐
        │ 输出选项 (仅限 image 模式)                                      │
        └──────────────────────────────────────────────────────────────────┘
          --output <file>       输出文件路径
                                  系统默认: 自动根据渲染参数生成
                                  格式: <scene>_<width>x<height>_<spp>_d<depth>[_options].ppm

        ┌──────────────────────────────────────────────────────────────────┐
        │ 其他                                                             │
        └──────────────────────────────────────────────────────────────────┘
          --help, -h            显示此帮助信息

        ╔══════════════════════════════════════════════════════════════════╗
        ║ 使用示例                                                         ║
        ╚══════════════════════════════════════════════════════════════════╝

        # 1. 快速预览（使用场景编号）
        \(programName) --mode window --scene 0
        \(programName) --mode window --scene 1 --width 800

        # 2. 离线渲染 - 固定采样（默认模式）
        \(programName) --scene cornellBox --spp 100
        \(programName) --scene 2 --spp 500 --output final.ppm

        # 3. 离线渲染 - 自适应采样（推荐，节省 30-60% 渲染时间）
        \(programName) --scene cornellBox --spp 100 --min-spp 16
        \(programName) --scene bouncingSpheres --spp 64 --min-spp 4 --width 800

        # 4. 高质量渲染
        \(programName) --scene 1 --spp 1000 --width 1920 --max-depth 50

        # 5. 实时窗口 + 高质量
        \(programName) --mode window --scene cornellBox --batch-size 4

        # 6. 景深效果
        \(programName) --scene finalScene --defocus-angle 0.6 --spp 200

        ╔══════════════════════════════════════════════════════════════════╗
        ║ 实时窗口控制 (--mode window)                                    ║
        ╚══════════════════════════════════════════════════════════════════╝
          Left Click     - 捕获鼠标 (启用相机控制)
          ESC            - 释放鼠标 / 退出
          WASD           - 移动相机 (前后左右)
          Space/Shift    - 上升/下降
          Mouse          - 环顾视角
          Q/E            - 相机滚转
          Wheel          - 调节焦距
          +/-            - 调节景深光圈
          1/2/3/4        - 质量预设 (1/2/4/8 spp/frame)
          Tab            - 切换 HUD 显示

        ═══════════════════════════════════════════════════════════════════
        版本: v7.0 | 文档: docs/ | 问题反馈: GitHub Issues
        ═══════════════════════════════════════════════════════════════════

        """)
    }

    /// 解析命令行参数
    static func parse() -> CommandLineArgs? {
        var args = CommandLineArgs()
        let arguments = CommandLine.arguments

        var i = 1  // 跳过程序名
        while i < arguments.count {
            let arg = arguments[i]

            switch arg {
            case "--help", "-h":
                printHelp(programName: arguments[0])
                return nil

            case "--scene":
                guard i + 1 < arguments.count else {
                    print("错误: --scene 需要参数")
                    return nil
                }
                let sceneArg = arguments[i + 1]

                // 支持数字索引（如 "0", "1", "2"）
                if let sceneIndex = Int(sceneArg) {
                    let availableScenes = getAvailableScenes()
                    guard sceneIndex >= 0 && sceneIndex < availableScenes.count else {
                        print("错误: 场景编号 \(sceneIndex) 无效，可用编号: 0-\(availableScenes.count - 1)")
                        print("使用 --help 查看所有可用场景")
                        return nil
                    }
                    args.sceneName = availableScenes[sceneIndex]
                } else {
                    // 使用场景名称
                    args.sceneName = sceneArg
                }
                i += 2

            case "--mode":
                guard i + 1 < arguments.count else {
                    print("错误: --mode 需要参数")
                    return nil
                }
                let mode = arguments[i + 1]
                if mode != "image" && mode != "window" {
                    print("错误: --mode 必须是 'image' 或 'window'")
                    return nil
                }
                args.mode = mode
                i += 2

            case "--output":
                guard i + 1 < arguments.count else {
                    print("错误: --output 需要参数")
                    return nil
                }
                args.outputFile = arguments[i + 1]
                i += 2

            case "--spp":
                guard i + 1 < arguments.count else {
                    print("错误: --spp 需要参数")
                    return nil
                }
                guard let value = Int(arguments[i + 1]), value > 0 else {
                    print("错误: --spp 必须是正整数")
                    return nil
                }
                args.spp = value
                i += 2

            case "--min-spp":
                guard i + 1 < arguments.count else {
                    print("错误: --min-spp 需要参数")
                    return nil
                }
                guard let value = Int(arguments[i + 1]), value > 0 else {
                    print("错误: --min-spp 必须是正整数")
                    return nil
                }
                args.minSpp = value
                i += 2

            case "--batch-size":
                guard i + 1 < arguments.count else {
                    print("错误: --batch-size 需要参数")
                    return nil
                }
                guard let value = Int(arguments[i + 1]), value > 0 else {
                    print("错误: --batch-size 必须是正整数")
                    return nil
                }
                args.batchSize = value
                i += 2

            case "--max-depth":
                guard i + 1 < arguments.count else {
                    print("错误: --max-depth 需要参数")
                    return nil
                }
                guard let value = Int(arguments[i + 1]), value > 0 else {
                    print("错误: --max-depth 必须是正整数")
                    return nil
                }
                args.maxDepth = value
                i += 2

            case "--width":
                guard i + 1 < arguments.count else {
                    print("错误: --width 需要参数")
                    return nil
                }
                guard let value = Int(arguments[i + 1]), value > 0 else {
                    print("错误: --width 必须是正整数")
                    return nil
                }
                args.width = value
                i += 2

            case "--vfov":
                guard i + 1 < arguments.count else {
                    print("错误: --vfov 需要参数")
                    return nil
                }
                guard let value = Float(arguments[i + 1]), value > 0 && value <= 180 else {
                    print("错误: --vfov 必须在 0-180 度之间")
                    return nil
                }
                args.vfov = value
                i += 2

            case "--defocus-angle":
                guard i + 1 < arguments.count else {
                    print("错误: --defocus-angle 需要参数")
                    return nil
                }
                guard let value = Float(arguments[i + 1]), value >= 0 else {
                    print("错误: --defocus-angle 必须是非负数")
                    return nil
                }
                args.defocusAngle = value
                i += 2

            case "--focus-dist":
                guard i + 1 < arguments.count else {
                    print("错误: --focus-dist 需要参数")
                    return nil
                }
                guard let value = Float(arguments[i + 1]), value > 0 else {
                    print("错误: --focus-dist 必须是正数")
                    return nil
                }
                args.focusDist = value
                i += 2

            case "--background":
                args.useBackground = true
                i += 1

            case "--no-background":
                args.useBackground = false
                i += 1

            case "--tonemap":
                guard i + 1 < arguments.count else {
                    print("错误: --tonemap 需要参数")
                    return nil
                }
                let modeStr = arguments[i + 1]
                guard let mode = TonemapMode(rawValue: modeStr) else {
                    print("错误: --tonemap 必须是 'none' 或 'aces'")
                    return nil
                }
                args.tonemapMode = mode
                i += 2

            case "--bloom":
                guard i + 1 < arguments.count else {
                    print("错误: --bloom 需要参数")
                    return nil
                }
                guard let value = Float(arguments[i + 1]), value >= 0 && value <= 1.0 else {
                    print("错误: --bloom 必须在 0.0-1.0 之间")
                    return nil
                }
                args.bloomStrength = value
                i += 2

            case "--bloom-threshold":
                guard i + 1 < arguments.count else {
                    print("错误: --bloom-threshold 需要参数")
                    return nil
                }
                guard let value = Float(arguments[i + 1]), value >= 0.5 && value <= 2.0 else {
                    print("错误: --bloom-threshold 必须在 0.5-2.0 之间")
                    return nil
                }
                args.bloomThreshold = value
                i += 2

            case "--filter":
                guard i + 1 < arguments.count else {
                    print("错误: --filter 需要参数")
                    return nil
                }
                let filterStr = arguments[i + 1]
                guard let filter = FilterType(rawValue: filterStr) else {
                    print("错误: --filter 必须是以下值之一:")
                    for f in FilterType.allCases {
                        print("  - \(f.rawValue): \(f.description)")
                    }
                    return nil
                }
                args.filterType = filter
                i += 2

            case "--blue-noise":
                args.useBlueNoise = true
                i += 1

            case "--weighted-variance":
                args.useWeightedVariance = true
                i += 1

            case "--adaptive-threshold":
                guard i + 1 < arguments.count else {
                    print("错误: --adaptive-threshold 需要参数")
                    return nil
                }
                guard let value = Float(arguments[i + 1]), value > 0 else {
                    print("错误: --adaptive-threshold 必须是正数")
                    return nil
                }
                args.adaptiveVarianceThreshold = value
                i += 2

            case "--adaptive-relative-error":
                guard i + 1 < arguments.count else {
                    print("错误: --adaptive-relative-error 需要参数")
                    return nil
                }
                guard let value = Float(arguments[i + 1]), value > 0 else {
                    print("错误: --adaptive-relative-error 必须是正数")
                    return nil
                }
                args.adaptiveRelativeThreshold = value
                i += 2

            case "--adaptive-batch-size":
                guard i + 1 < arguments.count else {
                    print("错误: --adaptive-batch-size 需要参数")
                    return nil
                }
                guard let value = Int(arguments[i + 1]), value > 0 else {
                    print("错误: --adaptive-batch-size 必须是正整数")
                    return nil
                }
                args.adaptiveBatchSize = value
                i += 2

            default:
                print("错误: 未知参数 '\(arg)'")
                print("使用 --help 查看帮助信息")
                return nil
            }
        }

        // 自动启用 ACES Tone Mapping（当 Bloom 开启时）
        if args.bloomStrength > 0.0 && args.tonemapMode == .none {
            args.tonemapMode = .aces
            print("ℹ️  Bloom 已开启，自动启用 ACES Tone Mapping")
        }

        // 验证自适应采样参数
        if args.minSpp != nil && args.spp == nil {
            print("错误: --min-spp 必须配合 --spp 使用")
            print("  --spp 指定总采样预算，--min-spp 指定每个像素的最小采样数")
            return nil
        }
        if let minSpp = args.minSpp, let spp = args.spp {
            if minSpp >= spp {
                print("错误: --min-spp (\(minSpp)) 必须小于 --spp (\(spp))")
                return nil
            }
        }

        return args
    }

    /// 检查场景是否存在
    func sceneExists() -> Bool {
        return SceneRegistry.exists(name: sceneName)
    }

    /// 获取可用场景列表
    static func getAvailableScenes() -> [String] {
        return SceneRegistry.availableScenes()
    }

    /// 生成默认输出文件名（基于渲染参数）
    /// 格式: <scene>_<width>x<height>_<spp|adaptive>_d<depth>[_<optional_params>].ppm
    func generateDefaultOutputFilename(scene: Scene) -> String {
        var parts: [String] = []

        // 1. 场景名（必选）
        parts.append(sceneName)

        // 2. 分辨率（必选）
        let width = self.width ?? scene.camera.imageWidth
        let height = Int(Float(width) / scene.camera.aspectRatio)
        parts.append("\(width)x\(height)")

        // 3. 采样数（必选）
        if useAdaptiveSampling {
            // 自适应采样：显示 minSpp-spp 范围
            let totalSpp = self.spp ?? Int(scene.camera.samplesPerPixel)
            parts.append("adaptive\(minSpp!)-\(totalSpp)s")
        } else {
            let spp = self.spp ?? Int(scene.camera.samplesPerPixel)
            parts.append("\(spp)s")
        }

        // 4. 最大深度（必选）
        let depth = self.maxDepth ?? Int(scene.camera.maxDepth)
        parts.append("d\(depth)")

        // 5. 可选参数（按重要性排序）

        // vfov（视野角度）- 仅当用户明确指定时才显示
        if let vfov = self.vfov {
            parts.append("fov\(Int(vfov))")
        }

        // defocusAngle（景深）
        if let defocusAngle = self.defocusAngle, defocusAngle > 0 {
            parts.append(String(format: "dof%.1f", defocusAngle))
        }

        // focusDist（焦平面距离）- 仅当用户明确指定时才显示
        if let focusDist = self.focusDist {
            parts.append(String(format: "fd%.1f", focusDist))
        }

        // filterType（滤波器）- 非 box 时显示
        if filterType != .box {
            parts.append(filterType.rawValue)
        }

        // useBlueNoise（蓝噪声）
        if useBlueNoise {
            parts.append("bn")
        }

        // tonemapMode（Tone Mapping）
        if tonemapMode == .aces {
            parts.append("aces")
        }

        // bloomStrength（Bloom）
        if bloomStrength > 0 {
            parts.append(String(format: "bloom%.1f", bloomStrength))
        }

        // bloomThreshold（Bloom 阈值）- 仅当非默认值 1.0 且 bloom 启用时
        if bloomStrength > 0 && bloomThreshold != 1.0 {
            parts.append(String(format: "bt%.1f", bloomThreshold))
        }

        // useBackground（背景）- true 时显示 bg
        if let useBackground = self.useBackground, useBackground == true {
            parts.append("bg")
        }

        // 组合所有部分
        let filename = parts.joined(separator: "_") + ".ppm"
        return filename
    }
}
