import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import SQLiteData
import SQLiteUndo
import StructuredQueries
import Testing

@testable import SQLiteUndoTCA

@Suite(
  .serialized,
  .dependencies {
    let database = try! makeTestDatabase()
    $0.defaultDatabase = database
    $0.defaultUndoEngine = try! UndoEngine(for: database, tables: TestRecord.self)
  }
)
@MainActor
struct UndoableEffectTests {

  @Dependency(\.defaultDatabase) var database
  @Dependency(\.defaultUndoEngine) var undoEngine

  @Test
  func effectUndoableCreatesBarrier() async throws {
    let testUndoManager = UndoManager()
    undoEngine.setUndoManager(testUndoManager)

    let store = TestStore(initialState: TestFeature.State()) {
      TestFeature()
    }

    await store.send(.insertItem)
    await store.receive(\.itemInserted)

    let count = try await database.read { db in try TestRecord.all.fetchCount(db) }
    #expect(count == 1)
    #expect(testUndoManager.canUndo == true)
    #expect(testUndoManager.undoActionName == "Insert Item")
  }

  @Test
  func effectUndoableUndoWorks() async throws {
    let testUndoManager = UndoManager()
    undoEngine.setUndoManager(testUndoManager)

    let store = TestStore(initialState: TestFeature.State()) {
      TestFeature()
    }

    await store.send(.insertItem)
    await store.receive(\.itemInserted)

    let countBefore = try await database.read { db in try TestRecord.all.fetchCount(db) }
    #expect(countBefore == 1)

    testUndoManager.undo()

    let countAfter = try await database.read { db in try TestRecord.all.fetchCount(db) }
    #expect(countAfter == 0)
  }
}

// MARK: - Test Feature

@Reducer
private struct TestFeature {
  @ObservableState
  struct State: Equatable {}

  enum Action {
    case insertItem
    case itemInserted
  }

  @Dependency(\.defaultDatabase) var database

  var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .insertItem:
        return .run { [database] send in
          try await undoable("Insert Item") {
            try await database.write { db in
              try TestRecord.insert { TestRecord(id: 1, name: "Test") }.execute(db)
            }
          }
          await send(.itemInserted)
        }

      case .itemInserted:
        return .none
      }
    }
  }
}

// MARK: - Test Helpers

@Table
private struct TestRecord: Identifiable, UndoTracked {
  @Column(primaryKey: true) var id: Int
  var name: String = ""
  var value: Int?
}

private func makeTestDatabase() throws -> any DatabaseWriter {
  let database = try DatabaseQueue(configuration: Configuration())

  try database.write { db in
    try db.execute(
      sql: """
        CREATE TABLE "testRecords" (
          "id" INTEGER PRIMARY KEY,
          "name" TEXT NOT NULL DEFAULT '',
          "value" INTEGER
        )
        """
    )
  }

  return database
}
