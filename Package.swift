// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MLXMenu",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LocalLLMCore", targets: ["LocalLLMCore"]),
        .library(name: "LocalInferenceBackends", targets: ["LocalInferenceBackends"]),
        .executable(name: "MLXMenu", targets: ["MLXMenu"]),
        .executable(name: "RouterEvaluation", targets: ["RouterEvaluation"]),
        .executable(name: "MultimodalSmoke", targets: ["MultimodalSmoke"]),
        .executable(name: "ConstructionTracer", targets: ["ConstructionTracer"]),
        .executable(name: "PreconEvaluation", targets: ["PreconEvaluation"]),
    ],
    targets: [
        .target(name: "LocalLLMCore"),
        .target(name: "LocalInferenceBackends", dependencies: ["LocalLLMCore"]),
        .executableTarget(name: "MLXMenu", dependencies: ["LocalLLMCore", "LocalInferenceBackends"], exclude: ["Resources"]),
        .executableTarget(name: "RouterEvaluation", dependencies: ["LocalLLMCore"]),
        .executableTarget(name: "MultimodalSmoke", dependencies: ["LocalLLMCore", "LocalInferenceBackends"]),
        .executableTarget(name: "ConstructionTracer", dependencies: ["LocalLLMCore", "LocalInferenceBackends"]),
        .executableTarget(name: "PreconEvaluation", dependencies: ["LocalLLMCore", "LocalInferenceBackends"]),
        .testTarget(name: "LocalLLMCoreTests", dependencies: ["LocalLLMCore"], resources: [.copy("Fixtures/precon-eval")]),
    ]
)
