// Camera.swift
// 相机类，负责计算相机参数并生成 GPU 相机参数

import simd

/// 相机类
/// 负责从 CameraConfig 计算相机矩阵和视口参数
class Camera {
    let config: CameraConfig

    // 图像尺寸
    let imageWidth: Int
    let imageHeight: Int

    // GPU 相机参数
    private(set) var gpuParams: GPUCameraParams

    init(config: CameraConfig) {
        self.config = config

        // 计算图像尺寸
        self.imageWidth = config.imageWidth
        self.imageHeight = Int(Float(config.imageWidth) / config.aspectRatio)

        // 计算相机参数
        self.gpuParams = Camera.computeCameraParams(config: config, imageWidth: imageWidth, imageHeight: imageHeight)
    }

    /// 从 CameraConfig 计算 GPU 相机参数
    /// 参考：~/ray_tracing 的相机实现（与 CPU 版本完全一致）
    private static func computeCameraParams(config: CameraConfig, imageWidth: Int, imageHeight: Int) -> GPUCameraParams {
        let aspectRatio = config.aspectRatio
        let cameraOrigin = config.lookFrom
        let lookAt = config.lookAt
        let vup = config.vup
        let vfov = config.vfov
        let focusDistance = config.focusDist

        // 计算视口尺寸
        let theta = vfov * Float.pi / 180.0
        let h = tan(theta / 2.0)
        let viewportHeight = 2.0 * h * focusDistance
        let viewportWidth = aspectRatio * viewportHeight

        // 相机基向量（右手坐标系，与 CPU 版本一致）
        let w = normalize(cameraOrigin - lookAt)  // 相机看向的反方向（向后）
        let u = normalize(simd_cross(vup, w))     // 右方向
        let v = simd_cross(w, u)                  // 上方向

        // 视口向量（与 CPU 版本一致）
        let viewportU = viewportWidth * u         // 水平方向（右）
        let viewportV = -viewportHeight * v       // 垂直方向（下，注意负号）

        // 计算每个像素的增量（与 CPU 版本一致）
        let pixelDeltaU = viewportU / Float(imageWidth)
        let pixelDeltaV = viewportV / Float(imageHeight)

        // 视口左上角（与 CPU 版本一致）
        let viewportUpperLeft = cameraOrigin - focusDistance * w - viewportU/2 - viewportV/2

        // pixel00 位置：视口左上角 + 半个像素的偏移（与 CPU 版本一致）
        let pixel00Loc = viewportUpperLeft + (pixelDeltaU + pixelDeltaV) * 0.5

        // 计算景深盘向量（与 CPU 版本一致）
        let defocusRadius = focusDistance * tan((config.defocusAngle * Float.pi / 180.0) / 2.0)
        let defocusDiskU = u * defocusRadius
        let defocusDiskV = v * defocusRadius

        // 返回 GPU 参数
        return GPUCameraParams(
            origin: cameraOrigin,
            lowerLeftCorner: pixel00Loc,   // 第一个像素的中心位置
            horizontal: pixelDeltaU,       // 每个像素的 X 增量
            vertical: pixelDeltaV,         // 每个像素的 Y 增量
            defocusDiskU: defocusDiskU,    // 景深盘 U 向量
            defocusDiskV: defocusDiskV,    // 景深盘 V 向量
            defocusAngle: config.defocusAngle,  // 散焦角度
            padding: SIMD3<Float>(0, 0, 0)
        )
    }

    /// 打印相机信息
    func printInfo() {
        print("[Camera] Position: \(config.lookFrom)")
        print("[Camera] Look at: \(config.lookAt)")
        print("[Camera] FOV: \(config.vfov)°")
        print("[Camera] Image size: \(imageWidth)×\(imageHeight)")
        print("[Camera] Aspect ratio: \(String(format: "%.2f", config.aspectRatio))")
    }
}
