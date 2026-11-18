// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Wordlit",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Wordlit", targets: ["DictionaryApp"])
    ],
    targets: [
        .executableTarget(
            name: "DictionaryApp",
            path: "Sources/DictionaryApp",
            resources: [.copy("Resources/EnglishDictionary"), .copy("Resources/Pronunciation"), .copy("Resources/AppIcon.icns"), .copy("Resources/ReadingSample.html")]
        ),
        .testTarget(name: "DictionaryAppTests", dependencies: ["DictionaryApp"])
    ]
)
