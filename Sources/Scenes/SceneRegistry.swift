// SceneRegistry.swift
// 场景注册系统 - 支持动态场景注册，无需修改多处代码

import Foundation

/// 场景创建函数类型
typealias SceneCreator = () -> Scene

/// 场景注册表
struct SceneRegistry {
    private static var registry: [String: SceneCreator] = [:]

    /// 注册场景
    static func register(name: String, creator: @escaping SceneCreator) {
        registry[name] = creator
    }

    /// 创建场景
    static func create(name: String) -> Scene? {
        return registry[name]?()
    }

    /// 获取所有可用场景名称
    static func availableScenes() -> [String] {
        return Array(registry.keys).sorted()
    }

    /// 检查场景是否存在
    static func exists(name: String) -> Bool {
        return registry[name] != nil
    }
}

/// 场景注册装饰器
/// 在每个场景文件中使用，自动注册场景
@propertyWrapper
struct RegisterScene {
    let name: String
    let creator: SceneCreator

    init(name: String, _ creator: @escaping SceneCreator) {
        self.name = name
        self.creator = creator
        SceneRegistry.register(name: name, creator: creator)
    }

    var wrappedValue: SceneCreator {
        return creator
    }
}
