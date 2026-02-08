import Dependencies
import DependenciesTestSupport
import Foundation
import InlineSnapshotTesting
import SnapshotTestingCustomDump
import StructuredQueries
import Testing

@testable import SQLiteUndo

@Suite(
  .serialized,
  .snapshots(record: .failed)
)
enum UndoEngineTests {

  @Suite
  struct TriggerGenerationTests {
    @Test
    func triggers() {
      let triggers = TestRecord.generateUndoTriggers()
      assertInlineSnapshot(of: triggers.joined(separator: "\n\n"), as: .lines) {
        """
        CREATE TEMPORARY TRIGGER IF NOT EXISTS _undo_testRecords_insert
        AFTER INSERT ON "testRecords"
        WHEN (SELECT isActive FROM undoState WHERE id = 1)
        BEGIN
          INSERT INTO undolog(tableName, sql)
          VALUES('testRecords', 'DELETE FROM "testRecords" WHERE rowid='||NEW.rowid);
        END

        CREATE TEMPORARY TRIGGER IF NOT EXISTS _undo_testRecords_update
        AFTER UPDATE ON "testRecords"
        WHEN (SELECT isActive FROM undoState WHERE id = 1)
        BEGIN
          INSERT INTO undolog(tableName, sql)
          VALUES('testRecords', 'UPDATE "testRecords" SET '||'"id"='||quote(OLD."id")||','||'"name"='||quote(OLD."name")||','||'"value"='||quote(OLD."value")||' WHERE rowid='||OLD.rowid);
        END

        CREATE TEMPORARY TRIGGER IF NOT EXISTS _undo_testRecords_delete
        AFTER DELETE ON "testRecords"
        WHEN (SELECT isActive FROM undoState WHERE id = 1)
        BEGIN
          INSERT INTO undolog(tableName, sql)
          VALUES('testRecords', 'INSERT INTO "testRecords"(rowid,"id","name","value") VALUES('||OLD.rowid||','||quote(OLD."id")||','||quote(OLD."name")||','||quote(OLD."value")||')');
        END
        """
      }
    }
  }

  @Suite
  struct BarrierTests {

    @Test
    func beginAndEndBarrier() throws {
      let (database, engine) = try makeTestDatabaseWithUndo()

      let barrierId = try engine.beginBarrier("Test Action")
      #expect(barrierId != UUID())

      try database.write { db in
        try TestRecord.insert { TestRecord(id: 1, name: "Test") }.execute(db)
      }

      let barrier = try engine.endBarrier(barrierId)
      #expect(barrier != nil)
      #expect(barrier?.name == "Test Action")
      #expect(barrier?.count ?? 0 > 0)
    }

    @Test
    func endBarrierWithNoChanges() throws {
      let (_, engine) = try makeTestDatabaseWithUndo()

      let barrierId = try engine.beginBarrier("Empty Action")
      let barrier = try engine.endBarrier(barrierId)

      #expect(barrier == nil)
    }

    @Test
    func cancelBarrier() throws {
      let (database, engine) = try makeTestDatabaseWithUndo()

      let barrierId = try engine.beginBarrier("Cancelled Action")

      try database.write { db in
        try TestRecord.insert { TestRecord(id: 1, name: "Test") }.execute(db)
      }

      try engine.cancelBarrier(barrierId)

      // Verify the undolog entries were removed
      let undoLogCount = try database.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM undolog")
      }
      #expect(undoLogCount == 0)
    }
  }

  @Suite
  struct UndoRedoTests {

    @Test
    func undoInsert() throws {
      let (database, engine) = try makeTestDatabaseWithUndo()

      let barrierId = try engine.beginBarrier("Insert Item")
      try database.write { db in
        try TestRecord.insert { TestRecord(id: 1, name: "Test") }.execute(db)
      }
      let barrier = try engine.endBarrier(barrierId)!

      try database.read { db in
        let count = try TestRecord.all.fetchCount(db)
        #expect(count == 1)
      }

      try engine.performUndo(barrier: barrier)

      try database.read { db in
        let count = try TestRecord.all.fetchCount(db)
        #expect(count == 0)
      }
    }

    @Test
    func undoUpdate() throws {
      let (database, engine) = try makeTestDatabaseWithUndo()

      try engine.withUndoDisabled {
        try database.write { db in
          try TestRecord.insert { TestRecord(id: 1, name: "Original", value: 10) }.execute(db)
        }
      }

      let barrierId = try engine.beginBarrier("Update Item")
      try database.write { db in
        try TestRecord.find(1).update {
          $0.name = "Updated"
          $0.value = 20
        }.execute(db)
      }
      let barrier = try engine.endBarrier(barrierId)!

      try database.read { db in
        let record = try TestRecord.find(1).fetchOne(db)!
        #expect(record.name == "Updated")
        #expect(record.value == 20)
      }

      try engine.performUndo(barrier: barrier)

      try database.read { db in
        let record = try TestRecord.find(1).fetchOne(db)!
        #expect(record.name == "Original")
        #expect(record.value == 10)
      }
    }

    @Test
    func undoDelete() throws {
      let (database, engine) = try makeTestDatabaseWithUndo()

      try engine.withUndoDisabled {
        try database.write { db in
          try TestRecord.insert { TestRecord(id: 1, name: "ToDelete", value: 42) }.execute(db)
        }
      }

      let barrierId = try engine.beginBarrier("Delete Item")
      try database.write { db in
        try TestRecord.find(1).delete().execute(db)
      }
      let barrier = try engine.endBarrier(barrierId)!

      try database.read { db in
        let count = try TestRecord.all.fetchCount(db)
        #expect(count == 0)
      }

      try engine.performUndo(barrier: barrier)

      try database.read { db in
        let record = try TestRecord.find(1).fetchOne(db)!
        #expect(record.name == "ToDelete")
        #expect(record.value == 42)
      }
    }

    @Test
    func redo() throws {
      let (database, engine) = try makeTestDatabaseWithUndo()

      try engine.withUndoDisabled {
        try database.write { db in
          try TestRecord.insert { TestRecord(id: 1, name: "Test", value: nil) }.execute(db)
        }
      }

      let barrierId = try engine.beginBarrier("Set Value")
      try database.write { db in
        try TestRecord.find(1).update { $0.value = 100 }.execute(db)
      }
      let barrier = try engine.endBarrier(barrierId)!

      try engine.performUndo(barrier: barrier)

      try database.read { db in
        let record = try TestRecord.find(1).fetchOne(db)!
        #expect(record.value == nil)
      }

      try engine.performRedo(barrier: barrier)

      try database.read { db in
        let record = try TestRecord.find(1).fetchOne(db)!
        #expect(record.value == 100)
      }
    }

    @Test
    func multipleChangesInOneBarrier() throws {
      let (database, engine) = try makeTestDatabaseWithUndo()

      let barrierId = try engine.beginBarrier("Batch Insert")
      try database.write { db in
        for i in 1...5 {
          try TestRecord.insert { TestRecord(id: i, name: "Item \(i)") }.execute(db)
        }
      }
      let barrier = try engine.endBarrier(barrierId)!

      try database.read { db in
        let count = try TestRecord.all.fetchCount(db)
        #expect(count == 5)
      }

      try engine.performUndo(barrier: barrier)

      try database.read { db in
        let count = try TestRecord.all.fetchCount(db)
        #expect(count == 0)
      }
    }
  }

  @Suite
  struct DisabledTrackingTests {

    @Test
    func withUndoDisabled() throws {
      let (database, engine) = try makeTestDatabaseWithUndo()

      try engine.withUndoDisabled {
        try database.write { db in
          try TestRecord.insert { TestRecord(id: 1, name: "Untracked") }.execute(db)
        }
      }

      // Verify no undolog entries were created
      let undoLogCount = try database.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM undolog")
      }
      #expect(undoLogCount == 0)

      // But the data is still there
      try database.read { db in
        let count = try TestRecord.all.fetchCount(db)
        #expect(count == 1)
      }
    }
  }

  @Suite
  @MainActor
  struct UndoManagerIntegrationTests {

    @Test
    func undoManagerReceivesRegistration() throws {
      let testUndoManager = UndoManager()
      try withDependencies {
        let database = try! makeTestDatabase()
        $0.defaultDatabase = database
        $0.defaultUndoStack = .live(testUndoManager)
        $0.defaultUndoEngine = try! UndoEngine(for: database, tables: TestRecord.self)
      } operation: {
        @Dependency(\.defaultDatabase) var database
        @Dependency(\.defaultUndoEngine) var undoEngine

        let barrierId = try undoEngine.beginBarrier("Set Name")
        try database.write { db in
          try TestRecord.insert { TestRecord(id: 1, name: "Test") }.execute(db)
        }
        try undoEngine.endBarrier(barrierId)

        #expect(testUndoManager.canUndo == true)
        #expect(testUndoManager.undoActionName == "Set Name")
      }
    }

    @Test
    func undoManagerUndoTriggersUndo() throws {
      let testUndoManager = UndoManager()
      try withDependencies {
        let database = try! makeTestDatabase()
        $0.defaultDatabase = database
        $0.defaultUndoStack = .live(testUndoManager)
        $0.defaultUndoEngine = try! UndoEngine(for: database, tables: TestRecord.self)
      } operation: {
        @Dependency(\.defaultDatabase) var database
        @Dependency(\.defaultUndoEngine) var undoEngine

        let barrierId = try undoEngine.beginBarrier("Insert")
        try database.write { db in
          try TestRecord.insert { TestRecord(id: 1, name: "Test") }.execute(db)
        }
        try undoEngine.endBarrier(barrierId)

        let countBefore = try database.read { db in try TestRecord.all.fetchCount(db) }
        #expect(countBefore == 1)

        testUndoManager.undo()

        let countAfter = try database.read { db in try TestRecord.all.fetchCount(db) }
        #expect(countAfter == 0)
      }
    }

    @Test
    func undoManagerRedoAfterUndo() throws {
      let testUndoManager = UndoManager()
      try withDependencies {
        let database = try! makeTestDatabase()
        $0.defaultDatabase = database
        $0.defaultUndoStack = .live(testUndoManager)
        $0.defaultUndoEngine = try! UndoEngine(for: database, tables: TestRecord.self)
      } operation: {
        @Dependency(\.defaultDatabase) var database
        @Dependency(\.defaultUndoEngine) var undoEngine

        try undoEngine.withUndoDisabled {
          try database.write { db in
            try TestRecord.insert { TestRecord(id: 1, name: "Original") }.execute(db)
          }
        }

        let barrierId = try undoEngine.beginBarrier("Update")
        try database.write { db in
          try TestRecord.find(1).update { $0.name = "Updated" }.execute(db)
        }
        try undoEngine.endBarrier(barrierId)

        testUndoManager.undo()

        let nameAfterUndo = try database.read { db in try TestRecord.find(1).fetchOne(db)!.name }
        #expect(nameAfterUndo == "Original")

        #expect(testUndoManager.canRedo == true)

        testUndoManager.redo()

        let nameAfterRedo = try database.read { db in try TestRecord.find(1).fetchOne(db)!.name }
        #expect(nameAfterRedo == "Updated")
      }
    }

    @Test
    func multipleUndoThenRedo() throws {
      let testUndoManager = UndoManager()
      testUndoManager.groupsByEvent = false

      try withDependencies {
        let database = try! makeTestDatabase()
        $0.defaultDatabase = database
        $0.defaultUndoStack = .live(testUndoManager)
        $0.defaultUndoEngine = try! UndoEngine(for: database, tables: TestRecord.self)
      } operation: {
        @Dependency(\.defaultDatabase) var database
        @Dependency(\.defaultUndoEngine) var undoEngine

        // Create item 1
        let barrierId1 = try undoEngine.beginBarrier("Create Item 1")
        try database.write { db in
          try TestRecord.insert { TestRecord(id: 1, name: "Item 1") }.execute(db)
        }
        try undoEngine.endBarrier(barrierId1)

        // Create item 2
        let barrierId2 = try undoEngine.beginBarrier("Create Item 2")
        try database.write { db in
          try TestRecord.insert { TestRecord(id: 2, name: "Item 2") }.execute(db)
        }
        try undoEngine.endBarrier(barrierId2)

        // Verify both items exist
        #expect(try database.read { db in try TestRecord.all.fetchCount(db) } == 2)

        // Undo item 2
        testUndoManager.undo()
        #expect(try database.read { db in try TestRecord.all.fetchCount(db) } == 1)
        #expect(try database.read { db in try TestRecord.find(1).fetchOne(db) } != nil)
        #expect(try database.read { db in try TestRecord.find(2).fetchOne(db) } == nil)

        // Undo item 1
        testUndoManager.undo()
        #expect(try database.read { db in try TestRecord.all.fetchCount(db) } == 0)

        // Redo should bring back item 1 first (LIFO)
        #expect(testUndoManager.canRedo == true)
        #expect(testUndoManager.redoActionName == "Create Item 1")
        testUndoManager.redo()
        #expect(try database.read { db in try TestRecord.all.fetchCount(db) } == 1)
        #expect(
          try database.read { db in try TestRecord.find(1).fetchOne(db) } != nil,
          "Item 1 should be back after first redo")

        // Redo should bring back item 2
        #expect(testUndoManager.redoActionName == "Create Item 2")
        testUndoManager.redo()
        #expect(try database.read { db in try TestRecord.all.fetchCount(db) } == 2)
        #expect(
          try database.read { db in try TestRecord.find(2).fetchOne(db) } != nil,
          "Item 2 should be back after second redo")
      }
    }

    @Test
    func endBarrierFromBackgroundThread() throws {
      let testUndoManager = UndoManager()
      try withDependencies {
        let database = try! makeTestDatabase()
        $0.defaultDatabase = database
        $0.defaultUndoStack = .live(testUndoManager)
        $0.defaultUndoEngine = try! UndoEngine(for: database, tables: TestRecord.self)
      } operation: {
        @Dependency(\.defaultDatabase) var database
        @Dependency(\.defaultUndoEngine) var undoEngine

        let barrierId = try undoEngine.beginBarrier("Background Insert")
        try database.write { db in
          try TestRecord.insert { TestRecord(id: 1, name: "Test") }.execute(db)
        }

        // End the barrier from a background thread
        DispatchQueue.global().sync {
          try! undoEngine.endBarrier(barrierId)
        }

        #expect(testUndoManager.canUndo == true)
        #expect(testUndoManager.undoActionName == "Background Insert")

        testUndoManager.undo()

        let count = try database.read { db in try TestRecord.all.fetchCount(db) }
        #expect(count == 0)
      }
    }

    @Test
    func undoRedoStackStateTransitions() throws {
      let testUndoManager = UndoManager()
      testUndoManager.groupsByEvent = false

      try withDependencies {
        let database = try! makeTestDatabase()
        $0.defaultDatabase = database
        $0.defaultUndoStack = .live(testUndoManager)
        $0.defaultUndoEngine = try! UndoEngine(for: database, tables: TestRecord.self)
      } operation: {
        @Dependency(\.defaultDatabase) var database
        @Dependency(\.defaultUndoEngine) var undoEngine
        @Dependency(\.defaultUndoStack) var undoStack

        // Initial state
        #expect(undoStack.currentState() == UndoStackState(undo: [], redo: []))

        // Do "A"
        let barrierId1 = try undoEngine.beginBarrier("A")
        try database.write { db in
          try TestRecord.insert { TestRecord(id: 1, name: "A") }.execute(db)
        }
        try undoEngine.endBarrier(barrierId1)

        #expect(undoStack.currentState() == UndoStackState(undo: ["A"], redo: []))

        // Do "B"
        let barrierId2 = try undoEngine.beginBarrier("B")
        try database.write { db in
          try TestRecord.find(1).update { $0.name = "B" }.execute(db)
        }
        try undoEngine.endBarrier(barrierId2)

        #expect(undoStack.currentState() == UndoStackState(undo: ["B", "A"], redo: []))

        // Undo "B"
        testUndoManager.undo()
        #expect(undoStack.currentState() == UndoStackState(undo: ["A"], redo: ["B"]))

        // Undo "A"
        testUndoManager.undo()
        #expect(undoStack.currentState() == UndoStackState(undo: [], redo: ["A", "B"]))

        // Redo "A"
        testUndoManager.redo()
        #expect(undoStack.currentState() == UndoStackState(undo: ["A"], redo: ["B"]))

        // Redo "B"
        testUndoManager.redo()
        #expect(undoStack.currentState() == UndoStackState(undo: ["B", "A"], redo: []))

        // Do "C" - should clear redo stack
        let barrierId3 = try undoEngine.beginBarrier("C")
        try database.write { db in
          try TestRecord.find(1).update { $0.name = "C" }.execute(db)
        }
        try undoEngine.endBarrier(barrierId3)

        #expect(undoStack.currentState() == UndoStackState(undo: ["C", "B", "A"], redo: []))

        // Undo "C", then do "D" - redo should be cleared
        testUndoManager.undo()
        #expect(undoStack.currentState() == UndoStackState(undo: ["B", "A"], redo: ["C"]))

        let barrierId4 = try undoEngine.beginBarrier("D")
        try database.write { db in
          try TestRecord.find(1).update { $0.name = "D" }.execute(db)
        }
        try undoEngine.endBarrier(barrierId4)

        #expect(undoStack.currentState() == UndoStackState(undo: ["D", "B", "A"], redo: []))
      }
    }
  }

  @Suite(
    .dependencies {
      let database = try! makeTestDatabase()
      $0.defaultDatabase = database
      $0.defaultUndoEngine = try! UndoEngine(for: database, tables: TestRecord.self)
    }
  )
  @MainActor
  struct UndoStackStateTests {

    @Dependency(\.defaultDatabase) var database
    @Dependency(\.defaultUndoEngine) var undoEngine
    @Dependency(\.defaultUndoStack) var undoStack

    @Test
    func startsEmpty() {
      #expect(undoStack.currentState() == [])
    }

    @Test
    func tracksUndoableActions() throws {
      #expect(undoStack.currentState() == [])

      let barrierId1 = try undoEngine.beginBarrier("Add Item")
      try database.write { db in
        try TestRecord.insert { TestRecord(id: 1, name: "Item 1") }.execute(db)
      }
      try undoEngine.endBarrier(barrierId1)

      #expect(undoStack.currentState() == ["Add Item"])

      let barrierId2 = try undoEngine.beginBarrier("Update Item")
      try database.write { db in
        try TestRecord.find(1).update { $0.name = "Updated" }.execute(db)
      }
      try undoEngine.endBarrier(barrierId2)

      // Most recent first
      #expect(undoStack.currentState() == ["Update Item", "Add Item"])
    }

    @Test
    func newActionClearsRedoStack() throws {
      let barrierId1 = try undoEngine.beginBarrier("First Action")
      try database.write { db in
        try TestRecord.insert { TestRecord(id: 1, name: "Item 1") }.execute(db)
      }
      try undoEngine.endBarrier(barrierId1)

      #expect(undoStack.currentState() == ["First Action"])

      // New action should clear redo stack (even though we can't undo in test mode)
      let barrierId2 = try undoEngine.beginBarrier("Second Action")
      try database.write { db in
        try TestRecord.insert { TestRecord(id: 2, name: "Item 2") }.execute(db)
      }
      try undoEngine.endBarrier(barrierId2)

      // Most recent first
      #expect(undoStack.currentState() == ["Second Action", "First Action"])
    }

    @Test
    func emptyBarrierNotTracked() throws {
      let barrierId = try undoEngine.beginBarrier("Empty Action")
      // No database changes
      try undoEngine.endBarrier(barrierId)

      #expect(undoStack.currentState() == [])
    }
  }
}

@Table
private struct TestRecord: Identifiable {
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

private func makeTestDatabaseWithUndo() throws -> (any DatabaseWriter, UndoCoordinator) {
  let database = try makeTestDatabase()
  try database.installUndoSystem()
  try database.write { db in
    for sql in TestRecord.generateUndoTriggers() {
      try db.execute(sql: sql)
    }
  }
  return (database, UndoCoordinator(database: database))
}
