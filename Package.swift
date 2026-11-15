// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DictionaryApp",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "DictionaryApp", targets: ["DictionaryApp"])
    ],
    targets: [
        .executableTarget(
            name: "DictionaryApp",
            path: "Sources/DictionaryApp",
            resources: [.copy("Resources/EnglishDictionary"), .copy("Resources/AppIcon.icns"), .copy("Resources/ReadingSample.html")]
        ),
        .testTarget(name: "DictionaryAppTests", dependencies: ["DictionaryApp"])
    ]
)
