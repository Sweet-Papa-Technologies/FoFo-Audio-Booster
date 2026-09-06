// swift-tools-version: 5.10
import PackageDescription
let package = Package(
    name: "FoFoBooster",
    defaultLocalization: "en",
    platforms: [.macOS("14.4")],
    products: [.executable(name: "FoFoBooster", targets: ["FoFoBooster"])],
    targets: [
        .target(name: "AudioDSP", publicHeadersPath: "include", cxxSettings: [.headerSearchPath("include")],
                linkerSettings: [.linkedFramework("AudioToolbox"), .linkedFramework("CoreAudio")]),
        .executableTarget(name: "FoFoBooster", dependencies: ["AudioDSP"], resources: [.process("Resources")],
                          linkerSettings: [.linkedFramework("Carbon"), .linkedFramework("MetalKit"), .linkedFramework("Accelerate")]),
        .testTarget(name: "FoFoBoosterTests", dependencies: ["FoFoBooster"])
    ], cxxLanguageStandard: .cxx17
)
