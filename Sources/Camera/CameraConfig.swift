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

    // MARK: - Camera Control
    var movementSpeed: Float = 5.0  // Units per second (WASD/Space/Shift)

    // MARK: - Computed Properties
    var imageHeight: Int {
        max(1, Int(Float(imageWidth) / aspectRatio))
    }

    /// Default configuration
    static let `default` = CameraConfig()
}

/// Camera change type classification
enum CameraChangeType {
    case none    // No change - keep accumulating
    case minor   // Depth-of-field changes - weight decay
    case major   // Position/direction/FOV changes - pre-render
}

/// Camera state tracker - detect camera movement for accumulation buffer reset
class CameraStateTracker {
    private var lastConfig: CameraConfig

    init(config: CameraConfig) {
        self.lastConfig = config
    }

    /// Check if camera has moved (legacy compatibility)
    func hasMoved(current: CameraConfig) -> Bool {
        return detectChange(current: current) != .none
    }

    /// Detect camera change type
    func detectChange(current: CameraConfig) -> CameraChangeType {
        // Check major parameters (position, direction, FOV)
        if !vec3Equals(current.lookFrom, lastConfig.lookFrom) { return .major }
        if !vec3Equals(current.lookAt, lastConfig.lookAt) { return .major }
        if !vec3Equals(current.vup, lastConfig.vup) { return .major }
        if current.vfov != lastConfig.vfov { return .major }

        // Check minor parameters (depth-of-field)
        if current.defocusAngle != lastConfig.defocusAngle { return .minor }
        if current.focusDist != lastConfig.focusDist { return .minor }

        return .none
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
