// swift-tools-version:5.9
import PackageDescription

// AssemblageModel enthält bewusst nur reine, plattformunabhängige Datenstrukturen
// (Codable structs/enums, kein AppKit/Core Image/Core Animation/Vision) — damit
// lässt sich das Kern-Datenmodell schon jetzt auf Windows entwickeln und testen.
// Die eigentliche AppKit-/Rendering-/Vision-Pipeline kommt später als separates
// Xcode-Ziel dazu, sobald am Mac weitergearbeitet wird (siehe README).
let package = Package(
    name: "AssemblageModel",
    products: [
        .library(name: "AssemblageModel", targets: ["AssemblageModel"])
    ],
    targets: [
        .target(name: "AssemblageModel"),
        .testTarget(name: "AssemblageModelTests", dependencies: ["AssemblageModel"])
    ]
)
