// swift-tools-version:5.9
import PackageDescription
import Foundation

// Incorpora Info.plist nel binario: serve a macOS (TCC) per trovare
// NSCameraUsageDescription anche quando l'app non è dentro un .app (swift run / Xcode).
let infoPlist = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Support/Info.plist").path

let package = Package(
    name: "HeadSwitch",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "HeadSwitch",
            path: "Sources/HeadSwitch",
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
                              "-Xlinker", "__info_plist", "-Xlinker", infoPlist])
            ]
        )
    ]
)
