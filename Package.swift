// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CouchKeys",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "CouchKeys", targets: ["CouchKeys"])],
    targets: [.executableTarget(name: "CouchKeys", path: "src/native")],
    swiftLanguageModes: [.v6]
)
