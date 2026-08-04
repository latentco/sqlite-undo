// swift-tools-version: 6.1

import Foundation
import PackageDescription

let package = Package(
  name: "sqlite-undo",
  platforms: [
    .iOS(.v16),
    .macOS(.v13),
  ],
  products: [
    .library(name: "SQLiteUndo", targets: ["SQLiteUndo"])
  ],
  traits: [
    .trait(
      name: "ComposableArchitecture",
      description: "Enable undo support for the Composable Architecture"
    )
  ],
  dependencies: [
    .package(
      url: "https://github.com/pointfreeco/swift-composable-architecture.git",
      from: "1.25.0"
    ),
    .package(url: "https://github.com/pointfreeco/swift-custom-dump.git", from: "1.3.3"),
    .package(url: "https://github.com/pointfreeco/swift-dependencies.git", from: "1.9.5"),
    .package(url: "https://github.com/pointfreeco/swift-snapshot-testing.git", from: "1.18.7"),
    .package(url: "https://github.com/pointfreeco/sqlite-data.git", from: "1.9.0"),
  ],
  targets: [
    .target(
      name: "SQLiteUndo",
      dependencies: [
        .product(name: "Dependencies", package: "swift-dependencies"),
        .product(name: "DependenciesMacros", package: "swift-dependencies"),
        .product(name: "SQLiteData", package: "sqlite-data"),
        .product(
          name: "ComposableArchitecture",
          package: "swift-composable-architecture",
          condition: .when(traits: ["ComposableArchitecture"])
        ),
      ]
    ),
    .testTarget(
      name: "SQLiteUndoTests",
      dependencies: [
        "SQLiteUndo",
        .product(name: "CustomDump", package: "swift-custom-dump"),
        .product(name: "DependenciesTestSupport", package: "swift-dependencies"),
        .product(name: "InlineSnapshotTesting", package: "swift-snapshot-testing"),
        .product(name: "SQLiteDataTestSupport", package: "sqlite-data"),
        .product(name: "SnapshotTestingCustomDump", package: "swift-snapshot-testing"),
        .product(
          name: "ComposableArchitecture",
          package: "swift-composable-architecture",
          condition: .when(traits: ["ComposableArchitecture"])
        ),
      ]
    ),
  ]
)

// NB: Xcode provides no way to select traits for the package you have open, so
// uncomment the '|| true' below to work on the trait-gated code there.
if ProcessInfo.processInfo.environment["SPI_GENERATE_DOCS"] != nil  // || true
{
  package.traits.insert(
    .default(enabledTraits: ["ComposableArchitecture"])
  )
}
