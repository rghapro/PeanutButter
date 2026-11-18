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
        .executableTarget(
            name: "PeanutButter",
            dependencies: ["CRubberBand"],
            path: "Sources/PeanutButter",
            resources: [
                .copy("Resources")
            ]
        )
    ],
    cxxLanguageStandard: .cxx17
)
