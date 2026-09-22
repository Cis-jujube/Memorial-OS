// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "MemoriaRebuild", platforms: [.macOS(.v14)],
  products: [
    .library(name: "MemoriaCore", targets: ["MemoriaCore"]),
    .executable(name: "MemoriaRebuild", targets: ["MemoriaApp"]),
  ],
  targets: [
    .target(name: "MemoriaCore", resources: [.process("Resources")]),
    .executableTarget(name: "MemoriaApp", dependencies: ["MemoriaCore"]),
    .testTarget(name: "MemoriaCoreTests", dependencies: ["MemoriaCore"]),
  ])
