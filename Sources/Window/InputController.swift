// InputController.swift
// FPS-style camera controls for realtime window mode

import Cocoa
import simd

/**
 * InputController - FPS-style camera controls
 *
 * Reference: ~/ray_tracing/include/camera/input_controller.h
 *
 * Features:
 * - WASD movement (forward/backward/strafe)
 * - Mouse look (first-person camera rotation)
 * - Space/Shift for up/down movement
 * - Q/E for camera roll
 * - Mouse sensitivity and movement speed control
 * - Smooth camera updates
 */
class InputController {
    // MARK: - Properties

    /// Camera configuration (modified by this controller)
    var config: CameraConfig

    /// Mouse capture state
    var isMouseCaptured: Bool = false

    /// First mouse movement flag (to filter initial jump)
    var firstMouse: Bool = true

    /// Callback to request mouse release (called when ESC is pressed)
    var onRequestMouseRelease: (() -> Void)?

    // MARK: - Camera Orientation

    /// Yaw angle (rotation around Y axis, in radians)
    private var yaw: Float = 0.0

    /// Pitch angle (rotation around X axis, in radians)
    private var pitch: Float = 0.0

    /// Roll angle (camera roll, in radians)
    private var rollAngle: Float = 0.0

    // MARK: - Control Parameters

    /// Mouse sensitivity (radians per pixel)
    var mouseSensitivity: Float = 0.002

    // MARK: - Keyboard State

    /// Tracked keyboard state
    private var keyState: Set<UInt16> = []

    // MARK: - Initialization

    init(config: CameraConfig) {
        self.config = config

        // Calculate initial yaw and pitch from look direction
        let direction = simd_normalize(config.lookAt - config.lookFrom)

        // Calculate yaw (rotation around Y axis)
        self.yaw = atan2(direction.x, direction.z)

        // Calculate pitch (rotation around X axis)
        self.pitch = asin(-direction.y)
    }

    // MARK: - Event Processing

    /**
     * Process mouse button events
     * @param event Mouse button event
     * @return true if event was handled
     */
    func processMouseButton(_ event: NSEvent) -> Bool {
        if event.type == .leftMouseDown && !isMouseCaptured {
            // Capture mouse on left click
            print("[InputController] Capturing mouse...")

            // 方法 1: 使用 CGAssociateMouseAndMouseCursorPosition
            CGAssociateMouseAndMouseCursorPosition(0)

            // 方法 2: 隐藏光标（多次调用确保生效）
            for _ in 0..<5 {
                NSCursor.hide()
            }

            isMouseCaptured = true
            firstMouse = true
            print("[InputController] Mouse captured")
            return true
        }
        return false
    }

    /**
     * Process mouse movement events
     * @param event Mouse movement event
     * @return true if event was handled
     */
    func processMouseMotion(_ event: NSEvent) -> Bool {
        guard isMouseCaptured else { return false }

        let deltaX = Float(event.deltaX)
        let deltaY = Float(event.deltaY)

        // Skip only if the movement is too large (likely from initial capture)
        if firstMouse {
            firstMouse = false
            if abs(deltaX) > 100 || abs(deltaY) > 100 {
                return true
            }
        }

        processMouseMovement(deltaX: deltaX, deltaY: deltaY)
        return true
    }

    /**
     * Process mouse scroll events (focus distance adjustment)
     * @param event Scroll wheel event
     * @return true if event was handled
     */
    func processScrollWheel(_ event: NSEvent) -> Bool {
        let deltaY = Float(event.scrollingDeltaY)

        // Adjust focus distance (inverted)
        if deltaY > 0 {
            config.focusDist = max(config.focusDist - 0.5, 0.1)
        } else if deltaY < 0 {
            config.focusDist = min(config.focusDist + 0.5, 1000.0)
        }

        return true
    }

    /**
     * Process key down events
     * @param event Key down event
     * @return true if event was handled
     */
    func processKeyDown(_ event: NSEvent) -> Bool {
        let keyCode = event.keyCode
        keyState.insert(keyCode)

        // Handle single-press keys
        switch keyCode {
        case 12:  // Q - Roll left
            rollAngle -= Float.pi / 180.0  // 1 degree increment
            updateVup()
            return true

        case 14:  // E - Roll right
            rollAngle += Float.pi / 180.0  // 1 degree increment
            updateVup()
            return true

        case 27:  // - (Minus) - Decrease aperture
            config.defocusAngle = max(config.defocusAngle - 0.1, 0.0)
            return true

        case 24:  // + (Equals/Plus) - Increase aperture
            config.defocusAngle = min(config.defocusAngle + 0.1, 10.0)
            return true

        case 53:  // ESC - Release mouse or close window
            if isMouseCaptured {
                onRequestMouseRelease?()
                return true
            }
            // If mouse not captured, let it propagate to close window
            return false

        default:
            break
        }

        return false
    }

    /**
     * Process key up events
     * @param event Key up event
     * @return true if event was handled
     */
    func processKeyUp(_ event: NSEvent) -> Bool {
        keyState.remove(event.keyCode)
        return false
    }

    /**
     * Process modifier flags changed (Shift, Ctrl, Option, Cmd)
     * @param event Flags changed event
     */
    func processFlagsChanged(_ event: NSEvent) {
        let shiftKeyCode: UInt16 = 56

        if event.modifierFlags.contains(.shift) {
            keyState.insert(shiftKeyCode)
        } else {
            keyState.remove(shiftKeyCode)
        }
    }


    // MARK: - Update

    /**
     * Update camera based on keyboard state
     * @param deltaTime Time since last frame (seconds)
     */
    func update(deltaTime: TimeInterval) {
        guard isMouseCaptured else { return }

        // Calculate forward direction and project onto XZ plane (horizontal plane)
        let forward3D = config.lookAt - config.lookFrom

        // Project forward direction onto XZ plane (set Y to 0)
        var forwardXZ = SIMD3<Float>(forward3D.x, 0.0, forward3D.z)
        let forwardLength = simd_length(forwardXZ)

        // If looking straight up/down, use default forward direction
        if forwardLength < 0.001 {
            forwardXZ = SIMD3<Float>(1.0, 0.0, 0.0)
        } else {
            forwardXZ = simd_normalize(forwardXZ)
        }

        // Calculate right direction in XZ plane (perpendicular to forwardXZ)
        // Right = forward rotated 90° clockwise in XZ plane
        let rightXZ = SIMD3<Float>(forwardXZ.z, 0.0, -forwardXZ.x)

        // Movement speed (from camera config)
        let velocity = config.movementSpeed * Float(deltaTime)

        // Track movement vector
        var movement = SIMD3<Float>(0, 0, 0)

        // WASD movement (only in XZ plane - horizontal)
        if keyState.contains(13) {  // W
            movement += forwardXZ * velocity
        }
        if keyState.contains(1) {   // S
            movement -= forwardXZ * velocity
        }
        if keyState.contains(0) {   // A
            movement += rightXZ * velocity
        }
        if keyState.contains(2) {   // D
            movement -= rightXZ * velocity
        }

        // Up/Down movement (Y axis only)
        let upY = SIMD3<Float>(0, 1, 0)
        if keyState.contains(49) {  // Space
            movement += upY * velocity
        }
        if keyState.contains(56) {  // Left Shift
            movement -= upY * velocity
        }

        // Apply movement to both look_from and look_at to maintain view direction
        config.lookFrom += movement
        config.lookAt += movement
    }

    // MARK: - Mouse Movement

    /**
     * Process mouse movement for camera rotation (called from MTKView)
     * @param deltaX Horizontal mouse movement
     * @param deltaY Vertical mouse movement
     */
    func processMouseMovement(deltaX: Float, deltaY: Float) {
        // Skip first movement to avoid jump from initial capture
        if firstMouse {
            firstMouse = false
            return
        }

        // Always skip abnormally large deltas (from CGWarpMouseCursorPosition)
        if abs(deltaX) > 100 || abs(deltaY) > 100 {
            return
        }

        // Update yaw and pitch (both axes inverted for natural control)
        yaw -= deltaX * mouseSensitivity     // Inverted X axis
        pitch += deltaY * mouseSensitivity   // Inverted Y axis

        // Clamp pitch to prevent gimbal lock
        let maxPitch = Float.pi / 2.0 - 0.01
        pitch = max(-maxPitch, min(maxPitch, pitch))

        updateLookAt()
    }

    /**
     * Update look_at point from yaw and pitch
     */
    private func updateLookAt() {
        // Calculate direction vector from yaw and pitch
        var direction = SIMD3<Float>()
        direction.x = cos(pitch) * sin(yaw)
        direction.y = -sin(pitch)
        direction.z = cos(pitch) * cos(yaw)

        // Update look_at point
        config.lookAt = config.lookFrom + direction

        // Update vup to keep camera upright
        updateVup()
    }

    /**
     * Update vup (camera up vector) from roll angle
     */
    private func updateVup() {
        // Calculate forward direction
        let forward = simd_normalize(config.lookAt - config.lookFrom)

        // World up (typically Y-axis)
        let worldUp = SIMD3<Float>(0, 1, 0)

        // Calculate right vector
        let right = simd_normalize(simd_cross(forward, worldUp))

        // Calculate base up vector (perpendicular to forward and right)
        let baseUp = simd_normalize(simd_cross(right, forward))

        // Apply roll rotation: vup = cos(roll) * base_up + sin(roll) * right
        config.vup = simd_normalize(baseUp * cos(rollAngle) + right * sin(rollAngle))
    }

    // MARK: - Accessors

    /**
     * Get current roll angle in degrees
     */
    func getRollDegrees() -> Float {
        return rollAngle * 180.0 / Float.pi
    }
}
