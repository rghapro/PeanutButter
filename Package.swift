// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "PeanutButter",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "PeanutButter", targets: ["PeanutButter"])
    ],
    targets: [
        .target(
            name: "CRubberBand",
            path: "Sources/CRubberBand",
            exclude: [
                "vendor/src",
                "vendor/rubberband",
                "vendor/COPYING"
            ],
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("vendor"),
                .define("USE_BQRESAMPLER", to: "1"),
                .define("NO_TIMING", to: "1"),
                .define("NO_THREADING", to: "1"),
                .define("NO_THREAD_CHECKS", to: "1"),
                .define("HAVE_VDSP", to: "1")
            ],
            linkerSettings: [
                .linkedFramework("Accelerate")
            ]
        ),
        .target(
            name: "CLame",
            path: "Sources/CLame",
            exclude: [
                "COPYING"
            ],
            sources: [
                "src"
            ],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("src"),
                .headerSearchPath("include"),
                .define("HAVE_CONFIG_H", to: "1")
            ]
        ),
        .executableTarget(
            name: "PeanutButter",
            dependencies: ["CRubberBand", "CLame"],
            path: "Sources/PeanutButter",
            resources: [
                .copy("Resources")
            ]
        ),
        .testTarget(
            name: "PeanutButterTests",
            dependencies: ["PeanutButter"],
            path: "Tests/PeanutButterTests"
        )
    ],
    cxxLanguageStandard: .cxx17
)
