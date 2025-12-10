// main.swift
// Ray Tracing GPU - 程序入口

import Foundation
import AppKit

// 加载所有场景（必须在使用场景之前调用）
SceneLoader.loadAllScenes()

// 检查是否为窗口模式
let args = CommandLine.arguments
let isWindowMode = args.contains("--mode") && args.contains("window") || !args.contains("--mode")

if isWindowMode {
    // 窗口模式：启动 NSApplication
    // AppDelegate 使用 @main 注解会自动处理
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
} else {
    // Image 模式：AppDelegate 会处理
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
