// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Hygieia",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HygieiaDomain", targets: ["HygieiaDomain"]),
        .library(name: "HygieiaScannerCore", targets: ["HygieiaScannerCore"]),
        .library(name: "HygieiaFoundationScanner", targets: ["HygieiaFoundationScanner"]),
        .library(name: "HygieiaVisualization", targets: ["HygieiaVisualization"]),
        .library(name: "HygieiaFileOperations", targets: ["HygieiaFileOperations"]),
        .executable(name: "hygieia", targets: ["HygieiaCLI"]),
        .executable(name: "hygieia-verify", targets: ["HygieiaVerification"]),
        .executable(name: "hygieia-visualization-bench", targets: ["HygieiaVisualizationBenchmarks"]),
    ],
    targets: [
        .target(name: "HygieiaDomain", path: "Domain", exclude: ["Services"]),
        .target(name: "HygieiaScannerCore", dependencies: ["HygieiaDomain"], path: "Scanner", exclude: ["Darwin", "Foundation"]),
        .target(name: "HygieiaFoundationScanner", dependencies: ["HygieiaDomain", "HygieiaScannerCore"], path: "Scanner/Foundation", exclude: ["README.md"]),
        .target(name: "HygieiaVisualization", dependencies: ["HygieiaDomain"], path: "Visualization"),
        .target(name: "HygieiaFileOperations", dependencies: ["HygieiaDomain"], path: "FileOperations"),
        .executableTarget(name: "HygieiaCLI", dependencies: ["HygieiaDomain", "HygieiaScannerCore", "HygieiaFoundationScanner"], path: "CLI"),
        .executableTarget(name: "HygieiaVerification", dependencies: ["HygieiaDomain", "HygieiaScannerCore", "HygieiaFoundationScanner"], path: "Verification"),
        .executableTarget(name: "HygieiaVisualizationBenchmarks", dependencies: ["HygieiaDomain", "HygieiaVisualization"], path: "VisualizationBenchmarks"),
        .testTarget(name: "VisualizationTests", dependencies: ["HygieiaDomain", "HygieiaVisualization"], path: "Tests/VisualizationTests"),
        .testTarget(name: "FileOperationsTests", dependencies: ["HygieiaDomain", "HygieiaFileOperations"], path: "Tests/FileOperationsTests"),
        .testTarget(name: "ScannerTests", dependencies: ["HygieiaDomain", "HygieiaScannerCore", "HygieiaFoundationScanner"], path: "Tests/ScannerTests"),
    ]
)
