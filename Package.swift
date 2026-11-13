// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TradeMirror",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ReviewEngine", targets: ["ReviewEngine"])
    ],
    targets: [
        .target(name: "ReviewEngine"),
        // ★ Fixtures 是**真的券商截图**:测试里会真跑一遍 Vision OCR。
        //   手抄的截图文字测的是我的想象,不是现实(2026-09-03 栽过一次,四个 bug)。
        .testTarget(name: "ReviewEngineTests", dependencies: ["ReviewEngine"],
                    resources: [.copy("Fixtures")])
    ]
)
