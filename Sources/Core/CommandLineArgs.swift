// CommandLineArgs.swift
// 命令行参数解析

import Foundation

/// 命令行参数结构
struct CommandLineArgs {
    var sceneName: String = "bouncingSpheres"
    var mode: String = "image"  // 当前只支持 image
    var outputFile: String = "output.ppm"
    var spp: Int? = nil  // 总采样数，nil 表示使用场景默认值
    var batchSize: Int = 10  // 每批 GPU 计算的采样数
    var maxDepth: Int? = nil  // 最大反弹深度，nil 表示使用场景默认值
    var width: Int? = nil  // 图像宽度，nil 表示使用场景默认值

    /// 打印帮助信息
    static func printHelp(programName: String) {
        print("""
        用法: \(programName) [选项]

        选项:
          --scene <name>        场景选择 (默认: bouncingSpheres)
                                可选: bouncingSpheres, cornellBox, textureTest
          --mode <mode>         渲染模式 (默认: image，当前只支持 image)
          --output <file>       输出文件 (默认: output.ppm)
          --spp <num>           总采样数 (默认: 使用场景配置)
          --batch-size <num>    每批 GPU 计算的采样数 (默认: 10)
          --max-depth <num>     最大光线反弹深度 (默认: 使用场景配置)
          --width <num>         图像宽度 (默认: 使用场景配置)
          --help, -h            显示此帮助信息

        示例:
          # 使用默认参数渲染 bouncingSpheres 场景
          \(programName)

          # 渲染 Cornell Box，500 采样，输出到自定义文件
          \(programName) --scene cornellBox --spp 500 --output cornell.ppm

          # 高质量渲染，1000 采样，更大分辨率
          \(programName) --scene bouncingSpheres --spp 1000 --width 1920 --max-depth 50

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
                args.sceneName = arguments[i + 1]
                i += 2

            case "--mode":
                guard i + 1 < arguments.count else {
                    print("错误: --mode 需要参数")
                    return nil
                }
                let mode = arguments[i + 1]
                if mode != "image" {
                    print("错误: 当前只支持 --mode image")
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

            default:
                print("错误: 未知参数 '\(arg)'")
                print("使用 --help 查看帮助信息")
                return nil
            }
        }

        return args
    }

    /// 获取场景类型
    func getSceneType() -> SceneType? {
        switch sceneName {
        case "bouncingSpheres":
            return .bouncingSpheres
        case "cornellBox":
            return .cornellBox
        case "textureTest":
            return .textureTest
        case "finalScene":
            return .finalScene
        default:
            return nil
        }
    }
}
