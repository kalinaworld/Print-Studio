// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "P900Print",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "CLcms2",
            path: "Sources/CLcms2",
            exclude: ["LICENSE-lcms2.txt"],
            cSettings: [.define("CMS_NO_REGISTER_KEYWORD")]
        ),
        .executableTarget(
            name: "P900Print",
            dependencies: ["CLcms2"],
            path: "Sources/P900Print"
        ),
    ]
)
