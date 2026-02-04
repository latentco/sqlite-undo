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
      let database = try makeTestDatabase()
      let engine = UndoEngine(database: database)

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
      let database = try makeTestDatabase()
      let engine = UndoEngine(database: database)

      let barrierId = try engine.beginBarrier("Empty Action")
      let barrier = try engine.endBarrier(barrierId)

      #expect(barrier == nil)
    }

    @Test
    func cancelBarrier() throws {
      let database = try makeTestDatabase()
      let engine = UndoEngine(database: database)

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
      let database = try makeTestDatabase()
      let engine = UndoEngine(database: database)

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
      let database = try makeTestDatabase()
      let engine = UndoEngine(database: database)

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
      let database = try makeTestDatabase()
      let engine = UndoEngine(database: database)

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
      let database = try makeTestDatabase()
      let engine = UndoEngine(database: database)

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
      let database = try makeTestDatabase()
      let engine = UndoEngine(database: database)

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
      let database = try makeTestDatabase()
      let engine = UndoEngine(database: database)

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

  @Suite(
    .dependencies {
      let database = try! makeTestDatabase()
      $0.defaultDatabase = database
      $0.undoClient = .make(database: database)
    }
  )
  @MainActor
  struct UndoClientIntegrationTests {

    @Dependency(\.defaultDatabase) var database
    @Dependency(\.undoClient) var undoClient

    @Test
    func undoManagerReceivesRegistration() throws {
      let testUndoManager = UndoManager()
      undoClient.setUndoManager(testUndoManager)

      let barrierId = try undoClient.beginBarrier("Set Name")
      try database.write { db in
        try TestRecord.insert { TestRecord(id: 1, name: "Test") }.execute(db)
      }
      try undoClient.endBarrier(barrierId)

      #expect(testUndoManager.canUndo == true)
      #expect(testUndoManager.undoActionName == "Set Name")
    }

    @Test
    func undoManagerUndoTriggersUndo() throws {
      let testUndoManager = UndoManager()
      undoClient.setUndoManager(testUndoManager)

      let barrierId = try undoClient.beginBarrier("Insert")
      try database.write { db in
        try TestRecord.insert { TestRecord(id: 1, name: "Test") }.execute(db)
      }
      try undoClient.endBarrier(barrierId)

      let countBefore = try database.read { db in try TestRecord.all.fetchCount(db) }
      #expect(countBefore == 1)

      testUndoManager.undo()

      let countAfter = try database.read { db in try TestRecord.all.fetchCount(db) }
      #expect(countAfter == 0)
    }

    @Test
    func undoManagerRedoAfterUndo() throws {
      let testUndoManager = UndoManager()
      undoClient.setUndoManager(testUndoManager)

      try undoClient.withUndoDisabled {
        try database.write { db in
          try TestRecord.insert { TestRecord(id: 1, name: "Original") }.execute(db)
        }
      }

      let barrierId = try undoClient.beginBarrier("Update")
      try database.write { db in
        try TestRecord.find(1).update { $0.name = "Updated" }.execute(db)
      }
      try undoClient.endBarrier(barrierId)

      testUndoManager.undo()

      let nameAfterUndo = try database.read { db in try TestRecord.find(1).fetchOne(db)!.name }
      #expect(nameAfterUndo == "Original")

      #expect(testUndoManager.canRedo == true)

      testUndoManager.redo()

      let nameAfterRedo = try database.read { db in try TestRecord.find(1).fetchOne(db)!.name }
      #expect(nameAfterRedo == "Updated")
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

  try database.installUndoSystem()

  try database.write { db in
    for sql in TestRecord.generateUndoTriggers() {
      try db.execute(sql: sql)
    }
  }

  return database
}
