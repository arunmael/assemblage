// swift-tools-version:5.9
import PackageDescription

// Zwei Ziele mit klarer Trennlinie:
//
// • AssemblageModel — reine, plattformunabhängige Datenstrukturen (Codable
//   structs/enums, kein AppKit/Core Image/Core Animation/Vision). Läuft und
//   testet auch unter Linux; genau das prüft die CI (.github/workflows).
//
// • AssemblageKit — die eigentliche Mac-App (AppKit-Canvas, Core Image, Core
//   Animation, Vision) als Bibliothek, damit sie testbar ist; `Assemblage`
//   ist nur der Einstiegspunkt darum herum. Beide werden unten nur auf macOS
//   deklariert, damit die Linux-CI weiterhin durchläuft.
//
// Gebaut wird die App nicht mit `swift build` allein, sondern über
// Scripts/make-app.sh — nur als echtes .app-Bundle bekommt sie Icon,
// Dokumenttypen und Versionsverwaltung (siehe Kommentar im Skript).

var targets: [Target] = [
    .target(name: "AssemblageModel"),
    .testTarget(name: "AssemblageModelTests", dependencies: ["AssemblageModel"])
]

var products: [Product] = [
    .library(name: "AssemblageModel", targets: ["AssemblageModel"])
]

#if os(macOS)
targets.append(contentsOf: [
    .target(name: "AssemblageKit", dependencies: ["AssemblageModel"]),
    .executableTarget(name: "Assemblage", dependencies: ["AssemblageKit"]),
    .testTarget(name: "AssemblageKitTests", dependencies: ["AssemblageKit"])
])
products.append(
    .executable(name: "Assemblage", targets: ["Assemblage"])
)
#endif

let package = Package(
    name: "Assemblage",
    // macOS 26 als Minimum: die App setzt ohnehin Apple Silicon voraus und
    // nutzt die Liquid-Glass-Optik sowie Sidecar Direct Touch (Plan 2.2, 4.5),
    // die es vorher nicht gibt.
    platforms: [.macOS("26.0")],
    products: products,
    targets: targets
)
