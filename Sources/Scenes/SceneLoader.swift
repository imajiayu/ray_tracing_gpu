// SceneLoader.swift
// 场景加载器 - 确保所有场景在程序启动时被注册

import Foundation

/// 场景加载器 - 必须在主程序启动时调用
struct SceneLoader {
    /// 加载所有场景
    /// 必须在使用任何场景之前调用此函数
    static func loadAllScenes() {
        // 注册所有场景
        SceneRegistry.register(name: "bouncingSpheres", creator: createBouncingSpheresScene)
        SceneRegistry.register(name: "cornellBox", creator: createCornellBoxScene)
        SceneRegistry.register(name: "finalScene", creator: createFinalScene)
    }
}
