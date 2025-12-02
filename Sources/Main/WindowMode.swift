// WindowMode.swift
// Window mode startup

import Foundation
import AppKit
import Metal
import MetalKit

func runWindowMode(
    context: MetalContext,
    scene: Scene,
    camera: Camera,
    bvh: FlatBVH,
    cmdArgs: CommandLineArgs
) {
    print("\n=== Ray Tracing GPU - Window Mode ===")
    print("Scene: \(cmdArgs.sceneName)")
    print("Resolution: \(camera.imageWidth)x\(camera.imageHeight)")
    print("Samples: \(scene.camera.samplesPerPixel) spp")
    print("Max depth: \(scene.camera.maxDepth)")
    print("\nPress ESC to exit\n")
    
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    
    let windowRect = NSRect(x: 0, y: 0, width: camera.imageWidth, height: camera.imageHeight)
    let window = RenderWindow(
        contentRect: windowRect,
        styleMask: [.titled, .closable, .miniaturizable],
        backing: .buffered,
        defer: false
    )
    window.title = "Ray Tracing GPU"
    window.center()
    
    let mtkView = MTKView(frame: windowRect, device: context.device)
    mtkView.colorPixelFormat = .bgra8Unorm
    mtkView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
    mtkView.framebufferOnly = false
    mtkView.preferredFramesPerSecond = 60

    // Force drawable size to match camera resolution (disable Retina scaling)
    mtkView.autoResizeDrawable = false
    mtkView.drawableSize = CGSize(width: camera.imageWidth, height: camera.imageHeight)
    
    // Use WindowRenderer for real-time progressive rendering
    guard let windowRenderer = WindowRenderer(
        context: context,
        scene: scene,
        camera: camera,
        bvh: bvh,
        samplesPerFrame: 1  // Render 1 sample per frame for real-time feedback
    ) else {
        print("❌ Failed to create window renderer")
        return
    }
    
    mtkView.delegate = windowRenderer
    window.contentView = mtkView
    
    let delegate = SimpleWindowDelegate()
    window.delegate = delegate
    
    window.makeKeyAndOrderFront(nil)
    app.activate(ignoringOtherApps: true)
    app.run()
    
    print("\nWindow closed")
}

class SimpleWindowDelegate: NSObject, NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        NSApplication.shared.terminate(nil)
    }
}
