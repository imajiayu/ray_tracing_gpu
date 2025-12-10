// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RayTracingGPU",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "raytracer",
            targets: ["RayTracingGPU"]
        )
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "RayTracingGPU",
            dependencies: [],
            path: "Sources",
            resources: [
                .process("../Shaders"),
                .process("../Resources")
            ]
        )
    ]
)
