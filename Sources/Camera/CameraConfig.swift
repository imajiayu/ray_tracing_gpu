// CameraConfig.swift
// Camera configuration structure

import simd

/// Camera configuration
struct CameraConfig {
    // MARK: - Image Settings
    var aspectRatio: Float = 16.0 / 9.0
    var imageWidth: Int = 800

    // MARK: - Sampling Settings
    var samplesPerPixel: UInt32 = 100
    var maxDepth: UInt32 = 50

    // MARK: - Camera Pose
    var lookFrom: Point3 = SIMD3<Float>(0, 0, 0)
    var lookAt: Point3 = SIMD3<Float>(0, 0, -1)
    var vup: Vec3 = SIMD3<Float>(0, 1, 0)

    // MARK: - Field of View
    var vfov: Float = 90.0

    // MARK: - Depth of Field
    var defocusAngle: Float = 0.0
    var focusDist: Float = 10.0

    // MARK: - Background Color
    var background: SIMD3<Float> = SIMD3<Float>(0, 0, 0)
    var useBackground: Bool = true

    // MARK: - Computed Properties
    var imageHeight: Int {
        max(1, Int(Float(imageWidth) / aspectRatio))
    }

    /// Default configuration
    static let `default` = CameraConfig()
}

/// Camera state tracker - detect camera movement for accumulation buffer reset
class CameraStateTracker {
    private var lastConfig: CameraConfig

    init(config: CameraConfig) {
        self.lastConfig = config
    }

    /// Check if camera has moved
    func hasMoved(current: CameraConfig) -> Bool {
        // Check position
        if !vec3Equals(current.lookFrom, lastConfig.lookFrom) { return true }

        // Check look direction
        if !vec3Equals(current.lookAt, lastConfig.lookAt) { return true }

        // Check vup (lens roll)
        if !vec3Equals(current.vup, lastConfig.vup) { return true }

        // Check FOV
        if current.vfov != lastConfig.vfov { return true }

        // Check defocus parameters
        if current.defocusAngle != lastConfig.defocusAngle { return true }
        if current.focusDist != lastConfig.focusDist { return true }

        return false
    }

    /// Update tracked state
    func update(config: CameraConfig) {
        lastConfig = config
    }

    /// Get last configuration
    func getLastConfig() -> CameraConfig {
        return lastConfig
    }

    // MARK: - Helper
    private func vec3Equals(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Bool {
        let diff = a - b
        return simd_length_squared(diff) < 1e-6
    }
}
