// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Stickling",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Stickling",
            path: "Sources/Stickling",
            linkerSettings: [
                .linkedFramework("Carbon"),
                // Apple Intelligence and Translate exist only on newer macOS: weak linking lets the app start on older systems
                .unsafeFlags(["-Xlinker", "-weak_framework", "-Xlinker", "FoundationModels",
                              "-Xlinker", "-weak_framework", "-Xlinker", "Translation"]),
            ]
        )
    ]
)
