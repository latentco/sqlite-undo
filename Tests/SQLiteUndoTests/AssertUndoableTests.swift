import DependenciesTestSupport
import InlineSnapshotTesting
import SQLiteUndo
import SQLiteUndoTestHelpers
import Testing

@MainActor
@Suite(
  .dependencies {
    $0.defaultDatabase = try makeTestDatabase()
    $0.defaultUndoEngine = try UndoEngine(for: $0.defaultDatabase, tables: TestRecord.self)
    try $0.defaultDatabase.write { db in
      try TestRecord.insert {
        TestRecord(id: 1, name: "Blob")
      }.execute(db)
    }
  },
  .snapshots(record: true),
)
struct AssertUndoableTests {

  @Dependency(\.defaultDatabase) var database

  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  @Test func assertUndoableBasic() async throws {
    try await assertUndoable(
      "Set Name",
      query: TestRecord.select(\.name)
    ) {
      try undoable("Set Name") {
        try database.write { db in
          try TestRecord.update { $0.name = "Blob Jr" }.execute(db)
        }
      }
    } before: {
      """
      ┌────────┐
      │ "Blob" │
      └────────┘
      """
    } after: {
      """
      ┌───────────┐
      │ "Blob Jr" │
      └───────────┘
      """
    }
  }

  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  @Test func assertUndoableNoUndoableOperation() async throws {
    await withKnownIssue {
      try await assertUndoable(
        "Set Name",
        query: TestRecord.select(\.name)
      ) {
        try database.write { db in
          try TestRecord.update { $0.name = "Blob Jr" }.execute(db)
        }
      } before: {
        """
        ┌────────┐
        │ "Blob" │
        └────────┘
        """
      } after: {
        """
        ┌───────────┐
        │ "Blob Jr" │
        └───────────┘
        """
      }
    }
  }

  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  @Test func assertUndoableWrongUndoName() async throws {
    await withKnownIssue {
      try await assertUndoable(
        "Change Name",
        query: TestRecord.select(\.name)
      ) {
        try undoable("Set Name") {
          try database.write { db in
            try TestRecord.update { $0.name = "Blob Jr" }.execute(db)
          }
        }
      } before: {
        """
        ┌────────┐
        │ "Blob" │
        └────────┘
        """
      } after: {
        """
        ┌───────────┐
        │ "Blob Jr" │
        └───────────┘
        """
      }
    }
  }

  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  @Test func assertUndoableNotReversed() async throws {
    await withKnownIssue {
      try await assertUndoable(
        "Set Name",
        query: TestRecord.select(\.name)
      ) {
        try database.write { db in
          try TestRecord.update { $0.name = "Blob Sr" }.execute(db)
        }
        try undoable("Set Name") {
          try database.write { db in
            try TestRecord.update { $0.name = "Blob Jr" }.execute(db)
          }
        }
      } before: {
        """
        ┌────────┐
        │ "Blob" │
        └────────┘
        """
      } after: {
        """
        ┌───────────┐
        │ "Blob Jr" │
        └───────────┘
        """
      }
    }
  }
}

@Table
private struct TestRecord: Identifiable {
  var id: Int
  var name: String
}

private func makeTestDatabase() throws -> any DatabaseWriter {
  let database = try DatabaseQueue(configuration: Configuration())
  try database.write { db in
    try db.execute(
      sql: """
        CREATE TABLE "testRecords" (
          "id" INTEGER PRIMARY KEY,
          "name" TEXT NOT NULL DEFAULT ''
        )
        """
    )
  }
  return database
}
