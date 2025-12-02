// GeometryList.swift
// 统一几何体容器，类似 CPU 版本的 hittable_list

import simd

/// 统一的几何体容器
/// 类似 CPU 版本的 hittable_list，但适配 GPU 架构
/// 内部管理多种几何类型，对外提供统一接口
struct GeometryList {
    private var spheres: [Sphere] = []
    private var quads: [Quad] = []
    private var constantMediums: [ConstantMedium] = []

    // MARK: - 初始化

    init() {
        self.spheres = []
        self.quads = []
        self.constantMediums = []
    }

    // MARK: - 添加几何体

    /// 添加球体
    mutating func add(_ sphere: Sphere) {
        spheres.append(sphere)
    }

    /// 添加 Quad
    mutating func add(_ quad: Quad) {
        quads.append(quad)
    }

    /// 添加体积雾
    mutating func add(_ constantMedium: ConstantMedium) {
        constantMediums.append(constantMedium)
    }

    /// 批量添加球体
    mutating func addSpheres(_ newSpheres: [Sphere]) {
        spheres.append(contentsOf: newSpheres)
    }

    /// 批量添加 Quad
    mutating func addQuads(_ newQuads: [Quad]) {
        quads.append(contentsOf: newQuads)
    }

    /// 批量添加体积雾
    mutating func addConstantMediums(_ newConstantMediums: [ConstantMedium]) {
        constantMediums.append(contentsOf: newConstantMediums)
    }

    // MARK: - 访问器

    /// 获取所有球体
    func getSpheres() -> [Sphere] {
        return spheres
    }

    /// 获取所有 Quad
    func getQuads() -> [Quad] {
        return quads
    }

    /// 获取所有体积雾
    func getConstantMediums() -> [ConstantMedium] {
        return constantMediums
    }

    /// 获取几何体数量
    var count: Int {
        return spheres.count + quads.count + constantMediums.count
    }

    /// 是否为空
    var isEmpty: Bool {
        return spheres.isEmpty && quads.isEmpty && constantMediums.isEmpty
    }

    // MARK: - GPU 数据转换

    /// 转换为 GPU 数据
    /// 返回 (spheres, quads, constantMediums) 用于创建 GPU 缓冲区
    func toGPU() -> ([GPUSphere], [GPUQuad], [GPUConstantMedium]) {
        let gpuSpheres = spheres.map { $0.toGPU() }
        let gpuQuads = quads.map { $0.toGPU() }
        let gpuConstantMediums = constantMediums.map { $0.toGPU() }
        return (gpuSpheres, gpuQuads, gpuConstantMediums)
    }

    // MARK: - 调试信息

    /// 打印统计信息
    func printStats() {
        print("[GeometryList] \(spheres.count) spheres, \(quads.count) quads, \(constantMediums.count) constant mediums")
    }
}

// MARK: - 便利构造器

extension GeometryList {
    /// 从球体数组创建
    init(spheres: [Sphere]) {
        self.spheres = spheres
        self.quads = []
    }

    /// 从 Quad 数组创建
    init(quads: [Quad]) {
        self.spheres = []
        self.quads = quads
    }

    /// 从球体和 Quad 数组创建
    init(spheres: [Sphere], quads: [Quad]) {
        self.spheres = spheres
        self.quads = quads
        self.constantMediums = []
    }

    /// 从球体、Quad 和体积雾数组创建
    init(spheres: [Sphere], quads: [Quad], constantMediums: [ConstantMedium]) {
        self.spheres = spheres
        self.quads = quads
        self.constantMediums = constantMediums
    }
}
