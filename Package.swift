// swift-tools-version: 6.1

import PackageDescription

let package = Package(
  name: "sqlite-undo",
  platforms: [
    .iOS(.v13),
    .macOS(.v12),
  ],
  products: [
    .library(name: "SQLiteUndo", targets: ["SQLiteUndo"]),
    .library(name: "SQLiteUndoTCA", targets: ["SQLiteUndoTCA"]),
  ],
  dependencies: [
    .package(
      url: "https://github.com/pointfreeco/swift-composable-architecture.git", from: "1.22.3"),
    .package(url: "https://github.com/pointfreeco/swift-custom-dump.git", from: "1.3.3"),
    .package(url: "https://github.com/pointfreeco/swift-dependencies.git", from: "1.9.5"),
    .package(url: "https://github.com/pointfreeco/swift-snapshot-testing.git", from: "1.18.7"),
    .package(url: "https://github.com/pointfreeco/sqlite-data.git", from: "1.3.0"),
  ],
  targets: [
    .target(
      name: "SQLiteUndo",
      dependencies: [
        .product(name: "Dependencies", package: "swift-dependencies"),
        .product(name: "DependenciesMacros", package: "swift-dependencies"),
        .product(name: "SQLiteData", package: "sqlite-data"),
      ]
    ),
    .target(
      name: "SQLiteUndoTCA",
      dependencies: [
        "SQLiteUndo",
        .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
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
      ]
    ),
    .testTarget(
      name: "SQLiteUndoTCATests",
      dependencies: [
        "SQLiteUndoTCA",
        .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
        .product(name: "DependenciesTestSupport", package: "swift-dependencies"),
        .product(name: "SQLiteDataTestSupport", package: "sqlite-data"),
      ]
    ),
  ]
)
