// swift-tools-version: 5.10
import PackageDescription
let package = Package(name: "WhisperValidation", platforms: [.macOS(.v14)], dependencies: [.package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", revision: "9f99b5cb6a907730543823ad271b82532782a899")], targets: [.executableTarget(name: "Validate", dependencies: [.product(name: "WhisperKit", package: "argmax-oss-swift")])])
