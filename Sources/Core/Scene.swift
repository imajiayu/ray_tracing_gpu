// Scene.swift
// 统一场景结构，包含几何体、材质和相机配置

import simd
import Metal

/// 场景容器
/// 统一管理几何体、材质、纹理、变换和相机配置
struct Scene {
    var geometry: GeometryList
    var materials: [Material]
    var textures: [GPUTexture]
    var imageTextures: [MTLTexture]  // Metal 纹理数组（用于图片纹理）
    var cpuTransforms: [Transform]   // CPU端Transform（用于BVH构建）
    var transforms: [GPUTransform]   // GPU端Transform（用于渲染）
    var camera: CameraConfig

    // MARK: - 初始化

    init(geometry: GeometryList, materials: [Material], textures: [GPUTexture], imageTextures: [MTLTexture], transforms: [GPUTransform], camera: CameraConfig) {
        self.geometry = geometry
        self.materials = materials
        self.textures = textures
        self.imageTextures = imageTextures
        self.cpuTransforms = []
        self.transforms = transforms
        self.camera = camera
    }

    init() {
        self.geometry = GeometryList()
        self.materials = []
        self.textures = []
        self.imageTextures = []
        self.cpuTransforms = []
        self.transforms = []
        self.camera = CameraConfig()
    }

    // MARK: - 添加内容

    /// 添加球体
    mutating func add(_ sphere: Sphere) {
        geometry.add(sphere)
    }

    /// 添加 Quad
    mutating func add(_ quad: Quad) {
        geometry.add(quad)
    }

    /// 添加体积雾
    mutating func add(_ constantMedium: ConstantMedium) {
        geometry.add(constantMedium)
    }

    /// 添加材质，返回材质索引
    @discardableResult
    mutating func addMaterial(_ material: Material) -> UInt32 {
        let index = UInt32(materials.count)
        materials.append(material)
        return index
    }

    /// 添加纹理，返回纹理索引
    @discardableResult
    mutating func addTexture(_ texture: any TextureProtocol) -> Int32 {
        let index = Int32(textures.count)
        textures.append(texture.toGPU())
        return index
    }

    /// 添加变换，返回变换索引
    @discardableResult
    mutating func addTransform(_ transform: Transform) -> Int32 {
        let index = Int32(transforms.count)
        cpuTransforms.append(transform)  // 保存CPU端Transform
        transforms.append(transform.toGPU())
        return index
    }

    /// 添加图片纹理，返回图片纹理索引
    @discardableResult
    mutating func addImageTexture(_ texture: MTLTexture) -> Int32 {
        let index = Int32(imageTextures.count)
        imageTextures.append(texture)
        return index
    }

    // MARK: - GPU 数据转换

    /// 转换为 GPU 数据
    func toGPU() -> (spheres: [GPUSphere], quads: [GPUQuad], constantMediums: [GPUConstantMedium], materials: [GPUMaterial], textures: [GPUTexture], transforms: [GPUTransform]) {
        let (gpuSpheres, gpuQuads, gpuConstantMediums) = geometry.toGPU()
        let gpuMaterials = materials.map { $0.toGPU() }
        return (gpuSpheres, gpuQuads, gpuConstantMediums, gpuMaterials, textures, transforms)
    }

    // MARK: - 调试信息

    /// 打印场景统计信息
    func printStats() {
        print("[Scene] Geometry: \(geometry.count) objects (\(geometry.getSpheres().count) spheres, \(geometry.getQuads().count) quads)")
        print("[Scene] Materials: \(materials.count)")
        print("[Scene] Textures: \(textures.count)")
        print("[Scene] Transforms: \(transforms.count)")
        print("[Scene] Camera: \(camera.imageWidth)×\(Int(Float(camera.imageWidth) / camera.aspectRatio)), \(camera.samplesPerPixel) spp")
    }
}
