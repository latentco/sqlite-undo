import DependenciesTestSupport
import Foundation
import SQLiteData
import SQLiteUndo
import StructuredQueries
import Testing

@Suite
@MainActor
struct UndoableWriteTests {

  @Test
  func undoableWriteCreatesBarrier() throws {
    let testUndoManager = UndoManager()

    try withDependencies {
      let database = try! makeDatabase()
      $0.defaultDatabase = database
      $0.defaultUndoStack = .live(testUndoManager)
      $0.defaultUndoEngine = try! UndoEngine(for: database, tables: Item.self)
    } operation: {
      @Dependency(\.defaultDatabase) var database

      try database.undoableWrite("Insert Item") { db in
        try Item.insert { Item(id: 1, name: "Test") }.execute(db)
      }

      let count = try database.read { db in try Item.all.fetchCount(db) }
      #expect(count == 1)
      #expect(testUndoManager.canUndo == true)
      #expect(testUndoManager.undoActionName == "Insert Item")
    }
  }

  @Test
  func undoableWriteUndoWorks() throws {
    let testUndoManager = UndoManager()

    try withDependencies {
      let database = try! makeDatabase()
      $0.defaultDatabase = database
      $0.defaultUndoStack = .live(testUndoManager)
      $0.defaultUndoEngine = try! UndoEngine(for: database, tables: Item.self)
    } operation: {
      @Dependency(\.defaultDatabase) var database

      try database.undoableWrite("Insert Item") { db in
        try Item.insert { Item(id: 1, name: "Test") }.execute(db)
      }

      #expect(try database.read { db in try Item.all.fetchCount(db) } == 1)

      testUndoManager.undo()

      #expect(try database.read { db in try Item.all.fetchCount(db) } == 0)
    }
  }

  @Test
  func undoableWriteReturnsValue() throws {
    try withDependencies {
      let database = try! makeDatabase()
      $0.defaultDatabase = database
      $0.defaultUndoStack = .testValue
      $0.defaultUndoEngine = try! UndoEngine(for: database, tables: Item.self)
    } operation: {
      @Dependency(\.defaultDatabase) var database

      let insertedName = try database.undoableWrite("Insert Item") { db in
        try Item.insert { Item(id: 1, name: "Test") }.execute(db)
        return "Test"
      }

      #expect(insertedName == "Test")
    }
  }

  @Test
  func undoableWriteCancelsBarrierOnError() throws {
    try withDependencies {
      let database = try! makeDatabase()
      $0.defaultDatabase = database
      $0.defaultUndoStack = .testValue
      $0.defaultUndoEngine = try! UndoEngine(for: database, tables: Item.self)
    } operation: {
      @Dependency(\.defaultDatabase) var database
      @Dependency(\.defaultUndoStack) var undoStack

      struct TestError: Error {}

      do {
        try database.undoableWrite("Will Fail") { db in
          try Item.insert { Item(id: 1, name: "Test") }.execute(db)
          throw TestError()
        }
      } catch is TestError {
        // Expected
      }

      // Barrier should be cancelled, not registered
      #expect(undoStack.currentState() == [])
    }
  }

  @Test
  func asyncUndoableWriteWorks() async throws {
    let testUndoManager = UndoManager()

    try await withDependencies {
      let database = try! makeDatabase()
      $0.defaultDatabase = database
      $0.defaultUndoStack = .live(testUndoManager)
      $0.defaultUndoEngine = try! UndoEngine(for: database, tables: Item.self)
    } operation: {
      @Dependency(\.defaultDatabase) var database

      try await database.undoableWrite("Insert Item") { db in
        try Item.insert { Item(id: 1, name: "Test") }.execute(db)
      }

      let count = try await database.read { db in try Item.all.fetchCount(db) }
      #expect(count == 1)
      #expect(testUndoManager.canUndo == true)
    }
  }
}

@Table
private struct Item: Identifiable {
  @Column(primaryKey: true) var id: Int
  var name: String = ""
}

private func makeDatabase() throws -> any DatabaseWriter {
  let database = try DatabaseQueue(configuration: Configuration())
  try database.write { db in
    try #sql(
      """
      CREATE TABLE "items" (
        "id" INTEGER PRIMARY KEY,
        "name" TEXT NOT NULL DEFAULT ''
      )
      """
    ).execute(db)
  }
  return database
}
