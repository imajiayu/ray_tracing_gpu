// SimpleWindowRenderer.swift
// Static image display in window (render once, display continuously)

import AppKit
import Metal
import MetalKit

class SimpleWindowRenderer: NSObject, MTKViewDelegate {
    private let renderer: Renderer
    private let scene: Scene
    private let camera: Camera
    private let bvh: FlatBVH
    private let context: MetalContext

    private var displayTexture: MTLTexture?
    private var conversionPipeline: MTLComputePipelineState?
    private var hasRendered: Bool = false

    init(renderer: Renderer, scene: Scene, camera: Camera, bvh: FlatBVH, context: MetalContext) {
        self.renderer = renderer
        self.scene = scene
        self.camera = camera
        self.bvh = bvh
        self.context = context
        super.init()

        // Create conversion pipeline
        setupConversionPipeline()
    }

    private func setupConversionPipeline() {
        let metalLibPath = "Resources/default.metallib"
        guard let library = try? context.device.makeLibrary(URL: URL(fileURLWithPath: metalLibPath)),
              let function = library.makeFunction(name: "rgb_to_bgra8") else {
            print("Failed to load rgb_to_bgra8 kernel")
            return
        }

        conversionPipeline = try? context.device.makeComputePipelineState(function: function)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        // Render only once
        if !hasRendered {
            print("[Window] Rendering static image...")
            print("[Window] View drawable size: \(view.drawableSize.width) x \(view.drawableSize.height)")
            print("[Window] Camera size: \(camera.imageWidth) x \(camera.imageHeight)")

            let startTime = CFAbsoluteTimeGetCurrent()

            // Render to buffer
            let (pixels, renderTime) = renderer.render(scene: scene, camera: camera, bvh: bvh, batchSize: 1)

            print("[Window] Render completed in \(String(format: "%.2f", renderTime * 1000)) ms")

            // Convert to texture on GPU
            convertToTexture(pixels: pixels, width: camera.imageWidth, height: camera.imageHeight)

            let totalTime = CFAbsoluteTimeGetCurrent() - startTime
            print("[Window] Total setup time: \(String(format: "%.2f", totalTime * 1000)) ms")

            hasRendered = true
        }

        // Display the texture
        guard let texture = displayTexture,
              let drawable = view.currentDrawable else {
            return
        }

        guard let commandBuffer = context.commandQueue.makeCommandBuffer(),
              let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
            return
        }

        // Copy texture to drawable (sizes should match exactly)
        blitEncoder.copy(
            from: texture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
            to: drawable.texture,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )

        blitEncoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func convertToTexture(pixels: [Float], width: Int, height: Int) {
        guard let pipeline = conversionPipeline else {
            print("Conversion pipeline not available")
            return
        }

        // Create output texture
        let descriptor = MTLTextureDescriptor()
        descriptor.width = width
        descriptor.height = height
        descriptor.pixelFormat = .bgra8Unorm
        descriptor.usage = [.shaderWrite, .shaderRead]
        descriptor.storageMode = .private

        guard let texture = context.device.makeTexture(descriptor: descriptor) else {
            print("Failed to create display texture")
            return
        }

        // Create buffer for RGB data
        let bufferSize = pixels.count * MemoryLayout<Float>.stride
        guard let rgbBuffer = context.device.makeBuffer(bytes: pixels, length: bufferSize, options: .storageModeShared) else {
            print("Failed to create RGB buffer")
            return
        }

        // Create spp buffer
        var spp = scene.camera.samplesPerPixel
        guard let sppBuffer = context.device.makeBuffer(bytes: &spp, length: MemoryLayout<UInt32>.stride, options: .storageModeShared) else {
            print("Failed to create SPP buffer")
            return
        }

        // Run conversion kernel
        guard let commandBuffer = context.commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            print("Failed to create command buffer/encoder")
            return
        }

        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(rgbBuffer, offset: 0, index: 0)
        encoder.setBuffer(sppBuffer, offset: 0, index: 1)
        encoder.setTexture(texture, index: 0)

        let threadgroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadgroups = MTLSize(
            width: (width + 15) / 16,
            height: (height + 15) / 16,
            depth: 1
        )

        encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadgroupSize)
        encoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        self.displayTexture = texture
        print("[Window] Texture conversion completed")
    }
}

class SimpleRenderWindow: NSWindow {
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {  // ESC
            close()
        }
    }
}
