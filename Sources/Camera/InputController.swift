// InputController.swift
// FPS-style camera input controller (based on CPU version, using AppKit NSEvent)

import AppKit
import simd

/// FPS-style camera input controller
/// Support: WASD movement, mouse look, space/shift up/down, QE roll, wheel focus
class InputController {
    // MARK: - Properties
    var config: CameraConfig
    private var mouseCaptured: Bool = false
    private var firstMouse: Bool = true
    private var yaw: Float = 0.0
    private var pitch: Float = 0.0
    private var rollAngle: Float = 0.0

    private var movementSpeed: Float = 5.0
    private var mouseSensitivity: Float = 0.002

    // Keyboard state
    private var keyStates: [UInt16: Bool] = [:]

    // MARK: - Initialization
    init(config: CameraConfig) {
        self.config = config

        // Calculate initial yaw and pitch from look direction
        let direction = simd_normalize(config.lookAt - config.lookFrom)

        // Calculate yaw (rotation around Y axis)
        yaw = atan2(direction.x, direction.z)

        // Calculate pitch (rotation around X axis)
        pitch = asin(-direction.y)
    }

    // MARK: - Event Processing
    func keyDown(with event: NSEvent) {
        keyStates[event.keyCode] = true

        // Handle immediate keys
        switch event.keyCode {
        case 12:  // Q - roll right
            rollAngle += degreesToRadians(1.0)
            updateVup()
        case 14:  // E - roll left
            rollAngle -= degreesToRadians(1.0)
            updateVup()
        case 24:  // + (=) - increase aperture
            config.defocusAngle = min(config.defocusAngle + 0.1, 10.0)
        case 27:  // - - decrease aperture
            config.defocusAngle = max(config.defocusAngle - 0.1, 0.0)
        case 53:  // ESC - release mouse
            if mouseCaptured {
                CGAssociateMouseAndMouseCursorPosition(1)
                NSCursor.unhide()
                mouseCaptured = false
            }
        default:
            break
        }
    }

    func keyUp(with event: NSEvent) {
        keyStates[event.keyCode] = false
    }

    func mouseMoved(deltaX: Float, deltaY: Float) {
        guard mouseCaptured else { return }

        if firstMouse {
            firstMouse = false
            if abs(deltaX) > 100 || abs(deltaY) > 100 {
                return
            }
        }

        // Update yaw and pitch (inverted axes)
        yaw -= deltaX * mouseSensitivity
        pitch += deltaY * mouseSensitivity

        // Clamp pitch to prevent gimbal lock
        let maxPitch = Float.pi / 2.0 - 0.01
        pitch = max(-maxPitch, min(maxPitch, pitch))

        updateLookAt()
    }

    func mouseDown(with event: NSEvent) {
        if event.buttonNumber == 0 && !mouseCaptured {
            CGAssociateMouseAndMouseCursorPosition(0)
            NSCursor.hide()
            mouseCaptured = true
            firstMouse = true
        }
    }

    func scrollWheel(deltaY: Float) {
        if deltaY > 0 {
            config.focusDist = max(config.focusDist - 0.5, 0.1)
        } else if deltaY < 0 {
            config.focusDist = min(config.focusDist + 0.5, 100.0)
        }
    }

    // MARK: - Update
    func update(deltaTime: Float) {
        guard mouseCaptured else { return }

        // Calculate forward direction projected to XZ plane
        let forward3D = config.lookAt - config.lookFrom
        var forwardXZ = SIMD3<Float>(forward3D.x, 0, forward3D.z)
        let forwardLength = simd_length(forwardXZ)

        if forwardLength < 0.001 {
            forwardXZ = SIMD3<Float>(1, 0, 0)
        } else {
            forwardXZ = simd_normalize(forwardXZ)
        }

        // Calculate right direction (XZ plane)
        let rightXZ = SIMD3<Float>(forwardXZ.z, 0, -forwardXZ.x)

        // Movement velocity
        let velocity = movementSpeed * deltaTime

        // Accumulate movement vector
        var movement = SIMD3<Float>(0, 0, 0)

        // WASD movement (XZ plane only)
        if keyStates[13] == true {  // W - forward
            movement += forwardXZ * velocity
        }
        if keyStates[1] == true {   // S - backward
            movement -= forwardXZ * velocity
        }
        if keyStates[0] == true {   // A - strafe left
            movement += rightXZ * velocity
        }
        if keyStates[2] == true {   // D - strafe right
            movement -= rightXZ * velocity
        }

        // Up/down movement (Y axis only)
        if keyStates[49] == true {  // Space - up
            movement += SIMD3<Float>(0, 1, 0) * velocity
        }
        if keyStates[56] == true {  // Left Shift - down
            movement -= SIMD3<Float>(0, 1, 0) * velocity
        }

        // Apply movement
        config.lookFrom += movement
        config.lookAt += movement
    }

    // MARK: - Helpers
    private func updateLookAt() {
        // Calculate direction vector from yaw and pitch
        var direction = SIMD3<Float>(0, 0, 0)
        direction.x = cos(pitch) * sin(yaw)
        direction.y = -sin(pitch)
        direction.z = cos(pitch) * cos(yaw)

        config.lookAt = config.lookFrom + direction
    }

    private func updateVup() {
        // Calculate forward vector
        let forward = simd_normalize(config.lookAt - config.lookFrom)

        // World up
        let worldUp = SIMD3<Float>(0, 1, 0)

        // Calculate right vector
        let right = simd_normalize(simd_cross(forward, worldUp))

        // Calculate base up vector
        let baseUp = simd_normalize(simd_cross(right, forward))

        // Apply roll rotation
        config.vup = simd_normalize(baseUp * cos(rollAngle) + right * sin(rollAngle))
    }

    private func degreesToRadians(_ degrees: Float) -> Float {
        return degrees * Float.pi / 180.0
    }

    // MARK: - Public Getters
    func isActive() -> Bool {
        return mouseCaptured
    }

    func getRollDegrees() -> Float {
        return rollAngle * 180.0 / Float.pi
    }

    func getConfig() -> CameraConfig {
        return config
    }
}
