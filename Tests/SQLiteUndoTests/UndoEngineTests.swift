import CustomDump
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
        WHEN "sqliteundo_isActive"() AND "sqliteundo_barrierID"() IS NOT NULL
        BEGIN
          INSERT INTO undolog(barrierID, tableName, trackedRowid, sql)
          VALUES("sqliteundo_barrierID"(), 'testRecords', NEW.rowid, 'D'||char(9)||'testRecords'||char(9)||NEW.rowid);
        END

        CREATE TEMPORARY TRIGGER IF NOT EXISTS _undo_testRecords_update
        BEFORE UPDATE ON "testRecords"
        WHEN "sqliteundo_isActive"() AND "sqliteundo_barrierID"() IS NOT NULL
          AND (OLD."id" IS NOT NEW."id" OR OLD."name" IS NOT NEW."name" OR OLD."value" IS NOT NEW."value")
        BEGIN
          INSERT INTO undolog(barrierID, tableName, trackedRowid, sql)
          VALUES("sqliteundo_barrierID"(), 'testRecords', OLD.rowid,
            'U'||char(9)||'testRecords'||char(9)||OLD.rowid
            || CASE WHEN OLD."id" IS NOT NEW."id" THEN char(9)||'id'||char(9)||quote(OLD."id") ELSE '' END
              || CASE WHEN OLD."name" IS NOT NEW."name" THEN char(9)||'name'||char(9)||quote(OLD."name") ELSE '' END
              || CASE WHEN OLD."value" IS NOT NEW."value" THEN char(9)||'value'||char(9)||quote(OLD."value") ELSE '' END
          );
        END

        CREATE TEMPORARY TRIGGER IF NOT EXISTS _undo_testRecords_delete
        BEFORE DELETE ON "testRecords"
        WHEN "sqliteundo_isActive"() AND "sqliteundo_barrierID"() IS NOT NULL
        BEGIN
          INSERT INTO undolog(barrierID, tableName, trackedRowid, sql)
          VALUES("sqliteundo_barrierID"(), 'testRecords', OLD.rowid,
            'I'||char(9)||'testRecords'||char(9)||OLD.rowid
            || char(9)||'id'||char(9)||quote(OLD."id")
              || char(9)||'name'||char(9)||quote(OLD."name")
              || char(9)||'value'||char(9)||quote(OLD."value")
          );
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

      let barrier = try engine.withBarrier("Test Action") {
        try database.write { db in
          try TestRecord.insert { TestRecord(id: 1, name: "Test") }.execute(db)
        }
      }

      #expect(barrier != nil)
      #expect(barrier?.name == "Test Action")
      #expect(barrier?.count ?? 0 > 0)
    }

    @Test
    func endBarrierWithNoChanges() throws {
      let (_, engine) = try makeTestDatabaseWithUndo()

      let barrier = try engine.withBarrier("Empty Action") {}

      #expect(barrier == nil)
    }

    @Test
    func cancelBarrier() throws {
      let (database, engine) = try makeTestDatabaseWithUndo()

      struct CancelError: Error {}
      #expect(throws: CancelError.self) {
        try engine.withBarrier("Cancelled Action") {
          try database.write { db in
            try TestRecord.insert { TestRecord(id: 1, name: "Test") }.execute(db)
          }
          throw CancelError()
        }
      }

      // Verify the undolog entries were removed
      let undoLogCount = try database.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM undolog")
      }
      #expect(undoLogCount == 0)
    }
  }

  @Suite
  @MainActor
  struct ScopeRoutingTests {

    /// Two "windows" share one database and engine but each has its own
    /// UndoStack/UndoManager, supplied by its own dependency scope.
    @Test
    func barriersRegisterWithTheScopesUndoManager() throws {
      let managerA = UndoManager()
      let managerB = UndoManager()

      try withDependencies {
        let database = try! makeTestDatabase()
        $0.defaultDatabase = database
        $0.defaultUndoEngine = try! UndoEngine(for: database, tables: TestRecord.self)
      } operation: {
        @Dependency(\.defaultDatabase) var database

        try withDependencies {
          $0.defaultUndoStack = .live(managerA)
        } operation: {
          try undoable("From A") {
            try database.write { db in
              try TestRecord.insert { TestRecord(id: 1, name: "a") }.execute(db)
            }
          }
        }

        try withDependencies {
          $0.defaultUndoStack = .live(managerB)
        } operation: {
          try undoable("From B") {
            try database.write { db in
              try TestRecord.insert { TestRecord(id: 2, name: "b") }.execute(db)
            }
          }
        }

        #expect(managerA.undoActionName == "From A")
        #expect(managerB.undoActionName == "From B")

        // Undoing in A reverts only A's row.
        managerA.undo()

        try database.read { db in
          let rowA = try TestRecord.find(1).fetchOne(db)
          let rowB = try TestRecord.find(2).fetchOne(db)
          #expect(rowA == nil)
          #expect(rowB?.name == "b")
        }

        #expect(managerA.canUndo == false)
        #expect(managerB.canUndo == true)
      }
    }

    /// An undo performed in one window must not notify the other.
    @Test
    func undoEventsReachOnlyTheScopeThatPerformedThem() async throws {
      let managerA = UndoManager()
      let managerB = UndoManager()
      let stackA = UndoStack.live(managerA)
      let stackB = UndoStack.live(managerB)

      var eventsA = stackA.events().makeAsyncIterator()
      var eventsB = stackB.events().makeAsyncIterator()

      try withDependencies {
        let database = try! makeTestDatabase()
        $0.defaultDatabase = database
        $0.defaultUndoEngine = try! UndoEngine(for: database, tables: TestRecord.self)
      } operation: {
        @Dependency(\.defaultDatabase) var database

        try withDependencies {
          $0.defaultUndoStack = stackA
        } operation: {
          try undoable("From A") {
            try database.write { db in
              try TestRecord.insert { TestRecord(id: 1, name: "a") }.execute(db)
            }
          }
        }
        try withDependencies {
          $0.defaultUndoStack = stackB
        } operation: {
          try undoable("From B") {
            try database.write { db in
              try TestRecord.insert { TestRecord(id: 2, name: "b") }.execute(db)
            }
          }
        }

        managerA.undo()
      }

      let a = await eventsA.next()
      expectNoDifference(
        a,
        UndoEvent(
          kind: .undo,
          name: "From A",
          affectedItems: [AffectedItem(table: TestRecord.self, rowid: 1)]
        ))

      // B performed no undo, so its stream has nothing pending.
      stackB.emit(UndoEvent(kind: .redo, name: "sentinel", affectedItems: []))
      let b = await eventsB.next()
      #expect(b?.name == "sentinel")
    }

    /// Sharing one stack between windows silently sends every window's undo to
    /// whichever mounted last, so it must be reported rather than left to discover.
    /// This fires on the second window's mount, before any action is taken.
    @Test
    func warnsWhenOneStackIsHandedASecondUndoManager() {
      let managerA = UndoManager()
      let managerB = UndoManager()
      let shared = UndoStack.live()

      shared.setUndoManager(managerA)  // window A mounts

      withKnownIssue {
        shared.setUndoManager(managerB)  // window B mounts against the same stack
      } matching: { issue in
        issue.description.contains("installDefaultUndoStack")
      }
    }

    @Test
    func noWarningWhenTheSameUndoManagerIsSetAgain() {
      let manager = UndoManager()
      let stack = UndoStack.live()

      // `.task(id: undoManager)` re-fires with the same manager; not a misconfiguration.
      stack.setUndoManager(manager)
      stack.setUndoManager(manager)
    }

    @Test
    func noWarningWhenThePreviousUndoManagerIsGone() {
      let stack = UndoStack.live()

      // A window that closed: its manager deallocated, so the weak reference is
      // already nil and the next window is not a conflict.
      do {
        let closing = UndoManager()
        stack.setUndoManager(closing)
      }
      stack.setUndoManager(UndoManager())

      // Clearing is likewise not a conflict.
      stack.setUndoManager(nil)
    }

    /// A barrier that could not be registered is unreachable, so its undolog
    /// entries must not accumulate.
    @Test
    func unregisterableBarrierDiscardsItsEntries() throws {
      try withDependencies {
        let database = try! makeTestDatabase()
        $0.defaultDatabase = database
        $0.defaultUndoEngine = try! UndoEngine(for: database, tables: TestRecord.self)
        $0.defaultUndoStack = .live()  // never given an UndoManager
      } operation: {
        @Dependency(\.defaultDatabase) var database

        try withKnownIssue {
          try undoable("Nowhere to register") {
            try database.write { db in
              try TestRecord.insert { TestRecord(id: 1, name: "a") }.execute(db)
            }
          }
        } matching: { issue in
          issue.description.contains("No UndoManager set")
        }

        let undoLogCount = try database.read { db in
          try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM undolog")
        }
        #expect(undoLogCount == 0, "entries for an unregisterable barrier should be discarded")

        // The write itself still stands — it just isn't undoable.
        try database.read { db in
          let count = try TestRecord.all.fetchCount(db)
          #expect(count == 1)
        }
      }
    }

    /// NSUndoManager does not retain its registration target, so the stack that
    /// registered a barrier may be released long before the undo is performed.
    @Test
    func undoWorksAfterTheRegisteringStackIsReleased() throws {
      let manager = UndoManager()

      try withDependencies {
        let database = try! makeTestDatabase()
        $0.defaultDatabase = database
        $0.defaultUndoEngine = try! UndoEngine(for: database, tables: TestRecord.self)
      } operation: {
        @Dependency(\.defaultDatabase) var database

        // The stack is owned by this scope alone and released when it exits.
        try withDependencies {
          $0.defaultUndoStack = .live(manager)
        } operation: {
          try undoable("Insert") {
            try database.write { db in
              try TestRecord.insert { TestRecord(id: 1, name: "test") }.execute(db)
            }
          }
        }

        manager.undo()

        try database.read { db in
          let count = try TestRecord.all.fetchCount(db)
          #expect(count == 0)
        }

        manager.redo()

        try database.read { db in
          let row = try TestRecord.find(1).fetchOne(db)
          #expect(row?.name == "test")
        }
      }
    }
  }

  @Suite
  struct BarrierOwnershipTests {

    @Test
    func openBarrierDoesNotClaimAnotherBarriersChanges() throws {
      let (database, engine) = try makeTestDatabaseWithUndo()

      // "Inner" opens, writes, and closes while "Outer" is still open.
      var inner: UndoBarrier?
      let outer = try engine.withBarrier("Outer") {
        try database.write { db in
          try TestRecord.insert { TestRecord(id: 1, name: "outer") }.execute(db)
        }
        inner = try engine.withBarrier("Inner") {
          try database.write { db in
            try TestRecord.insert { TestRecord(id: 2, name: "inner") }.execute(db)
          }
        }
      }!

      #expect(outer.count == 1)
      #expect(inner?.count == 1)

      // Undoing "Outer" must not revert "Inner"'s row.
      try engine.performUndo(barrier: outer)

      try database.read { db in
        let outerRow = try TestRecord.find(1).fetchOne(db)
        let innerRow = try TestRecord.find(2).fetchOne(db)
        #expect(outerRow == nil)
        #expect(innerRow?.name == "inner")
      }

      // "Inner" is still independently undoable.
      try engine.performUndo(barrier: inner!)

      try database.read { db in
        let count = try TestRecord.all.fetchCount(db)
        #expect(count == 0)
      }
    }

    @Test
    func concurrentBarriersOwnOnlyTheirOwnChanges() async throws {
      let (database, engine) = try makeTestDatabaseWithUndo()

      // Two barriers racing, as two windows would. Whatever the interleaving,
      // each must end up owning exactly its own row.
      async let a = engine.withBarrier("A") {
        try await database.write { db in
          try TestRecord.insert { TestRecord(id: 1, name: "a") }.execute(db)
        }
      }
      async let b = engine.withBarrier("B") {
        try await database.write { db in
          try TestRecord.insert { TestRecord(id: 2, name: "b") }.execute(db)
        }
      }
      let (barrierA, barrierB) = try await (a!, b!)

      #expect(barrierA.count == 1)
      #expect(barrierB.count == 1)

      try engine.performUndo(barrier: barrierA)

      let (rowA, rowB) = try await database.read { db in
        (try TestRecord.find(1).fetchOne(db), try TestRecord.find(2).fetchOne(db))
      }
      #expect(rowA == nil)
      #expect(rowB?.name == "b")
    }

    @Test
    func writesOutsideAnyBarrierAreNotTracked() throws {
      let (database, _) = try makeTestDatabaseWithUndo()

      try database.write { db in
        try TestRecord.insert { TestRecord(id: 1, name: "untracked") }.execute(db)
      }

      let undoLogCount = try database.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM undolog")
      }
      #expect(undoLogCount == 0)

      try database.read { db in
        let count = try TestRecord.all.fetchCount(db)
        #expect(count == 1)
      }
    }

    @Test
    func asyncBarrierCapturesChanges() async throws {
      // Guards the mechanism the whole design rests on: the barrier TaskLocal
      // must survive GRDB's async write, which hops to its own executor.
      let (database, engine) = try makeTestDatabaseWithUndo()

      let barrier = try await engine.withBarrier("Async Insert") {
        try await database.write { db in
          try TestRecord.insert { TestRecord(id: 1, name: "Test") }.execute(db)
        }
      }

      #expect(barrier?.count == 1)

      try engine.performUndo(barrier: barrier!)

      let count = try await database.read { db in
        try TestRecord.all.fetchCount(db)
      }
      #expect(count == 0)
    }

    @Test
    func detachedTaskWritesAreNotTracked() async throws {
      // Documented limitation: a detached task starts a fresh task context, so it
      // is outside the barrier. Its writes apply but are not undoable.
      let (database, engine) = try makeTestDatabaseWithUndo()

      let barrier = try await engine.withBarrier("Detached") {
        try await Task.detached {
          try await database.write { db in
            try TestRecord.insert { TestRecord(id: 1, name: "detached") }.execute(db)
          }
        }.value
      }

      #expect(barrier == nil)

      let count = try await database.read { db in
        try TestRecord.all.fetchCount(db)
      }
      #expect(count == 1)
    }

    @Test
    func ownershipSurvivesRepeatedUndoRedoCycles() throws {
      let (database, engine) = try makeTestDatabaseWithUndo()

      let first = try engine.withBarrier("First") {
        try database.write { db in
          try TestRecord.insert { TestRecord(id: 1, name: "first") }.execute(db)
        }
      }!
      let second = try engine.withBarrier("Second") {
        try database.write { db in
          try TestRecord.insert { TestRecord(id: 2, name: "second") }.execute(db)
        }
      }!

      // Cycle the first barrier repeatedly; entries move to new seq positions
      // each time but must stay owned by their barrier.
      for _ in 1...3 {
        try engine.performUndo(barrier: first)
        try database.read { db in
          let firstRow = try TestRecord.find(1).fetchOne(db)
          let secondRow = try TestRecord.find(2).fetchOne(db)
          #expect(firstRow == nil)
          #expect(secondRow != nil)
        }
        try engine.performRedo(barrier: first)
        try database.read { db in
          let firstRow = try TestRecord.find(1).fetchOne(db)
          #expect(firstRow?.name == "first")
        }
      }

      // The second barrier is unaffected by all that churn.
      try engine.performUndo(barrier: second)
      try database.read { db in
        let firstRow = try TestRecord.find(1).fetchOne(db)
        let secondRow = try TestRecord.find(2).fetchOne(db)
        #expect(firstRow?.name == "first")
        #expect(secondRow == nil)
      }
    }
  }

  @Suite
  struct UndoRedoTests {

    @Test
    func undoInsert() throws {
      let (database, engine) = try makeTestDatabaseWithUndo()

      let barrier = try engine.withBarrier("Insert Item") {
        try database.write { db in
          try TestRecord.insert { TestRecord(id: 1, name: "Test") }.execute(db)
        }
      }!

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

      try withUndoDisabled {
        try database.write { db in
          try TestRecord.insert { TestRecord(id: 1, name: "Original", value: 10) }.execute(db)
        }
      }

      let barrier = try engine.withBarrier("Update Item") {
        try database.write { db in
          try TestRecord.find(1).update {
            $0.name = "Updated"
            $0.value = 20
          }.execute(db)
        }
      }!

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

      try withUndoDisabled {
        try database.write { db in
          try TestRecord.insert { TestRecord(id: 1, name: "ToDelete", value: 42) }.execute(db)
        }
      }

      let barrier = try engine.withBarrier("Delete Item") {
        try database.write { db in
          try TestRecord.find(1).delete().execute(db)
        }
      }!

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

      try withUndoDisabled {
        try database.write { db in
          try TestRecord.insert { TestRecord(id: 1, name: "Test", value: nil) }.execute(db)
        }
      }

      let barrier = try engine.withBarrier("Set Value") {
        try database.write { db in
          try TestRecord.find(1).update { $0.value = 100 }.execute(db)
        }
      }!

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

      let barrier = try engine.withBarrier("Batch Insert") {
        try database.write { db in
          for i in 1...5 {
            try TestRecord.insert { TestRecord(id: i, name: "Item \(i)") }.execute(db)
          }
        }
      }!

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
  struct ReplayStateTests {

    @Test
    func isReplayingTrueDuringUndo() throws {
      let (database, engine) = try makeTestDatabaseWithUndo()

      // Create an audit table and a trigger that only fires when NOT replaying
      try database.write { db in
        try db.execute(
          sql: """
            CREATE TABLE "auditLog" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "action" TEXT NOT NULL)
            """)
        try db.execute(
          sql: """
            CREATE TEMPORARY TRIGGER audit_insert
            AFTER INSERT ON "testRecords"
            WHEN NOT "sqliteundo_isReplaying"()
            BEGIN
              INSERT INTO "auditLog"("action") VALUES('insert ' || NEW."name");
            END
            """)
        try db.execute(
          sql: """
            CREATE TEMPORARY TRIGGER audit_delete
            AFTER DELETE ON "testRecords"
            WHEN NOT "sqliteundo_isReplaying"()
            BEGIN
              INSERT INTO "auditLog"("action") VALUES('delete ' || OLD."name");
            END
            """)
      }

      // Normal insert — trigger should fire
      let barrier = try engine.withBarrier("Insert") {
        try database.write { db in
          try TestRecord.insert { TestRecord(id: 1, name: "Alice") }.execute(db)
        }
      }!

      try database.read { db in
        let actions = try String.fetchAll(db, sql: "SELECT action FROM auditLog ORDER BY id")
        #expect(actions == ["insert Alice"])
      }

      // Undo — trigger should NOT fire (isReplaying is true)
      try engine.performUndo(barrier: barrier)

      try database.read { db in
        let count = try TestRecord.all.fetchCount(db)
        #expect(count == 0, "Row should be deleted by undo")

        let actions = try String.fetchAll(db, sql: "SELECT action FROM auditLog ORDER BY id")
        #expect(actions == ["insert Alice"], "No new audit entry during replay")
      }
    }
  }

  @Suite
  struct DisabledTrackingTests {

    @Test
    func disablesUndoTracking() throws {
      let (database, _) = try makeTestDatabaseWithUndo()

      try withUndoDisabled {
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

        try undoable("Set Name") {
          try database.write { db in
            try TestRecord.insert { TestRecord(id: 1, name: "Test") }.execute(db)
          }
        }

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

        try undoable("Insert") {
          try database.write { db in
            try TestRecord.insert { TestRecord(id: 1, name: "Test") }.execute(db)
          }
        }

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

        try withUndoDisabled {
          try database.write { db in
            try TestRecord.insert { TestRecord(id: 1, name: "Original") }.execute(db)
          }
        }

        try undoable("Update") {
          try database.write { db in
            try TestRecord.find(1).update { $0.name = "Updated" }.execute(db)
          }
        }

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

        try undoable("Create Item 1") {
          try database.write { db in
            try TestRecord.insert { TestRecord(id: 1, name: "Item 1") }.execute(db)
          }
        }

        try undoable("Create Item 2") {
          try database.write { db in
            try TestRecord.insert { TestRecord(id: 2, name: "Item 2") }.execute(db)
          }
        }

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
          "Item 1 should be back after first redo"
        )

        // Redo should bring back item 2
        #expect(testUndoManager.redoActionName == "Create Item 2")
        testUndoManager.redo()
        #expect(try database.read { db in try TestRecord.all.fetchCount(db) } == 2)
        #expect(
          try database.read { db in try TestRecord.find(2).fetchOne(db) } != nil,
          "Item 2 should be back after second redo"
        )
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

        // Run the whole barrier from a background thread
        DispatchQueue.global().sync {
          try! undoable("Background Insert") {
            try database.write { db in
              try TestRecord.insert { TestRecord(id: 1, name: "Test") }.execute(db)
            }
          }
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
        @Dependency(\.defaultUndoStack) var undoStack

        // Initial state
        #expect(undoStack.currentState() == UndoStackState(undo: [], redo: []))

        // Do "A"
        try undoable("A") {
          try database.write { db in
            try TestRecord.insert { TestRecord(id: 1, name: "A") }.execute(db)
          }
        }

        #expect(undoStack.currentState() == UndoStackState(undo: ["A"], redo: []))

        // Do "B"
        try undoable("B") {
          try database.write { db in
            try TestRecord.find(1).update { $0.name = "B" }.execute(db)
          }
        }

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
        try undoable("C") {
          try database.write { db in
            try TestRecord.find(1).update { $0.name = "C" }.execute(db)
          }
        }

        #expect(undoStack.currentState() == UndoStackState(undo: ["C", "B", "A"], redo: []))

        // Undo "C", then do "D" - redo should be cleared
        testUndoManager.undo()
        #expect(undoStack.currentState() == UndoStackState(undo: ["B", "A"], redo: ["C"]))

        try undoable("D") {
          try database.write { db in
            try TestRecord.find(1).update { $0.name = "D" }.execute(db)
          }
        }

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

      try undoable("Add Item") {
        try database.write { db in
          try TestRecord.insert { TestRecord(id: 1, name: "Item 1") }.execute(db)
        }
      }

      #expect(undoStack.currentState() == ["Add Item"])

      try undoable("Update Item") {
        try database.write { db in
          try TestRecord.find(1).update { $0.name = "Updated" }.execute(db)
        }
      }

      // Most recent first
      #expect(undoStack.currentState() == ["Update Item", "Add Item"])
    }

    @Test
    func newActionClearsRedoStack() throws {
      try undoable("First Action") {
        try database.write { db in
          try TestRecord.insert { TestRecord(id: 1, name: "Item 1") }.execute(db)
        }
      }

      #expect(undoStack.currentState() == ["First Action"])

      // New action should clear redo stack (even though we can't undo in test mode)
      try undoable("Second Action") {
        try database.write { db in
          try TestRecord.insert { TestRecord(id: 2, name: "Item 2") }.execute(db)
        }
      }

      // Most recent first
      #expect(undoStack.currentState() == ["Second Action", "First Action"])
    }

    @Test
    func emptyBarrierNotTracked() throws {
      // No database changes
      try undoable("Empty Action") {}

      #expect(undoStack.currentState() == [])
    }
  }
  @Suite
  struct BulkOperationTests {

    @Test
    func bulkInsertUndoRedo() throws {
      let (database, engine) = try makeTestDatabaseWithUndo()

      let barrier = try engine.withBarrier("Bulk Insert") {
        try database.write { db in
          for i in 1...1000 {
            try TestRecord.insert { TestRecord(id: i, name: "Item \(i)", value: i) }.execute(db)
          }
        }
      }!

      try database.read { db in
        let count = try TestRecord.all.fetchCount(db)
        #expect(count == 1000)
      }

      try engine.performUndo(barrier: barrier)

      try database.read { db in
        let count = try TestRecord.all.fetchCount(db)
        #expect(count == 0)
      }

      try engine.performRedo(barrier: barrier)

      try database.read { db in
        let count = try TestRecord.all.fetchCount(db)
        #expect(count == 1000)
        let first = try TestRecord.find(1).fetchOne(db)!
        #expect(first.name == "Item 1")
        #expect(first.value == 1)
        let last = try TestRecord.find(1000).fetchOne(db)!
        #expect(last.name == "Item 1000")
        #expect(last.value == 1000)
      }
    }

    @Test
    func bulkDeleteUndoRedo() throws {
      let (database, engine) = try makeTestDatabaseWithUndo()

      try withUndoDisabled {
        try database.write { db in
          for i in 1...1000 {
            try TestRecord.insert { TestRecord(id: i, name: "Item \(i)", value: i) }.execute(db)
          }
        }
      }

      let barrier = try engine.withBarrier("Bulk Delete") {
        try database.write { db in
          try TestRecord.all.delete().execute(db)
        }
      }!

      try database.read { db in
        let count = try TestRecord.all.fetchCount(db)
        #expect(count == 0)
      }

      try engine.performUndo(barrier: barrier)

      try database.read { db in
        let count = try TestRecord.all.fetchCount(db)
        #expect(count == 1000)
        let first = try TestRecord.find(1).fetchOne(db)!
        #expect(first.name == "Item 1")
        #expect(first.value == 1)
      }

      try engine.performRedo(barrier: barrier)

      try database.read { db in
        let count = try TestRecord.all.fetchCount(db)
        #expect(count == 0)
      }
    }

    @Test
    func bulkUpdateUndoRedo() throws {
      let (database, engine) = try makeTestDatabaseWithUndo()

      try withUndoDisabled {
        try database.write { db in
          for i in 1...1000 {
            try TestRecord.insert { TestRecord(id: i, name: "Item \(i)", value: nil) }.execute(db)
          }
        }
      }

      let barrier = try engine.withBarrier("Bulk Update") {
        try database.write { db in
          try TestRecord.all.update { $0.value = 42 }.execute(db)
        }
      }!

      try engine.performUndo(barrier: barrier)

      try database.read { db in
        let records = try TestRecord.all.fetchAll(db)
        #expect(records.count == 1000)
        #expect(records.allSatisfy { $0.value == nil })
      }

      try engine.performRedo(barrier: barrier)

      try database.read { db in
        let records = try TestRecord.all.fetchAll(db)
        #expect(records.count == 1000)
        #expect(records.allSatisfy { $0.value == 42 })
      }
    }

    @Test
    func bulkMixedOperations() throws {
      let (database, engine) = try makeTestDatabaseWithUndo()

      let barrier = try engine.withBarrier("Mixed Ops") {
        try database.write { db in
          for i in 1...500 {
            try TestRecord.insert { TestRecord(id: i, name: "Item \(i)") }.execute(db)
          }
          for i in 1...250 {
            try TestRecord.find(i).update { $0.value = 99 }.execute(db)
          }
          for i in 251...500 {
            try TestRecord.find(i).delete().execute(db)
          }
        }
      }!

      try database.read { db in
        let count = try TestRecord.all.fetchCount(db)
        #expect(count == 250)
      }

      try engine.performUndo(barrier: barrier)

      try database.read { db in
        let count = try TestRecord.all.fetchCount(db)
        #expect(count == 0)
      }

      try engine.performRedo(barrier: barrier)

      try database.read { db in
        let count = try TestRecord.all.fetchCount(db)
        #expect(count == 250)
        let record = try TestRecord.find(1).fetchOne(db)!
        #expect(record.value == 99)
      }
    }
  }

  @Suite
  struct UndoEventTests {

    @Test
    func eventReturnedFromUndo() async throws {
      let (database, coordinator) = try makeTestDatabaseWithUndo()

      let barrier = try await coordinator.withBarrier("Insert Item") {
        try await database.write { db in
          try TestRecord.insert { TestRecord(id: 1, name: "Test") }.execute(db)
        }
      }!

      let event = try coordinator.performUndo(barrier: barrier)
      expectNoDifference(
        event,
        UndoEvent(
          kind: .undo,
          name: "Insert Item",
          affectedItems: [AffectedItem(table: TestRecord.self, rowid: 1)]
        ))
    }

    @Test
    func eventReturnedFromRedo() async throws {
      let (database, coordinator) = try makeTestDatabaseWithUndo()

      let barrier = try await coordinator.withBarrier("Insert Item") {
        try await database.write { db in
          try TestRecord.insert { TestRecord(id: 1, name: "Test") }.execute(db)
        }
      }!

      let undoEvent = try coordinator.performUndo(barrier: barrier)
      #expect(undoEvent?.kind == .undo)

      let redoEvent = try coordinator.performRedo(barrier: barrier)
      expectNoDifference(
        redoEvent,
        UndoEvent(
          kind: .redo,
          name: "Insert Item",
          affectedItems: [AffectedItem(table: TestRecord.self, rowid: 1)]
        ))
    }

    @Test
    func affectedItemsForMultiRowBarrier() async throws {
      let (database, coordinator) = try makeTestDatabaseWithUndo()

      let barrier = try await coordinator.withBarrier("Batch Insert") {
        try await database.write { db in
          for i in 1...3 {
            try TestRecord.insert { TestRecord(id: i, name: "Item \(i)") }.execute(db)
          }
        }
      }!

      let event = try coordinator.performUndo(barrier: barrier)
      expectNoDifference(
        event,
        UndoEvent(
          kind: .undo,
          name: "Batch Insert",
          affectedItems: [
            AffectedItem(table: TestRecord.self, rowid: 1),
            AffectedItem(table: TestRecord.self, rowid: 2),
            AffectedItem(table: TestRecord.self, rowid: 3),
          ]
        ))
    }

    @Test
    func affectedItemIdAs() {
      let item = AffectedItem(table: TestRecord.self, rowid: 42)
      #expect(item.id(as: TestRecord.self) == 42)
    }

    @Test
    func eventsBroadcastToAllSubscribersOfAStack() async {
      let stack = UndoStack.live()
      var first = stack.events().makeAsyncIterator()
      var second = stack.events().makeAsyncIterator()

      stack.emit(UndoEvent(kind: .undo, name: "Insert", affectedItems: []))

      let firstEvent = await first.next()
      let secondEvent = await second.next()
      #expect(firstEvent?.kind == .undo)
      expectNoDifference(firstEvent, secondEvent)
    }

    @Test
    func resubscribingAfterCancellationStillReceivesEvents() async {
      let stack = UndoStack.live()

      let abandoned = stack.events()
      let task = Task { for await _ in abandoned {} }
      task.cancel()
      await task.value

      var iterator = stack.events().makeAsyncIterator()
      stack.emit(UndoEvent(kind: .undo, name: "Insert", affectedItems: []))

      let event = await iterator.next()
      #expect(event?.kind == .undo)
    }

    @Test
    func eventsAreNotReplayedToLaterSubscribers() async {
      let stack = UndoStack.live()

      stack.emit(UndoEvent(kind: .undo, name: "First", affectedItems: []))

      var iterator = stack.events().makeAsyncIterator()
      stack.emit(UndoEvent(kind: .undo, name: "Second", affectedItems: []))

      let event = await iterator.next()
      #expect(event?.name == "Second")
    }

    @Test
    func eventsDoNotCrossScopes() async {
      let stackA = UndoStack.live()
      let stackB = UndoStack.live()

      var fromA = stackA.events().makeAsyncIterator()
      var fromB = stackB.events().makeAsyncIterator()

      stackA.emit(UndoEvent(kind: .undo, name: "From A", affectedItems: []))
      stackB.emit(UndoEvent(kind: .undo, name: "From B", affectedItems: []))

      let a = await fromA.next()
      let b = await fromB.next()
      #expect(a?.name == "From A")
      #expect(b?.name == "From B")
    }

    @Test
    func eventIdsForTable() {
      let event = UndoEvent(
        kind: .undo,
        name: "Test",
        affectedItems: [
          AffectedItem(table: TestRecord.self, rowid: 1),
          AffectedItem(table: TestRecord.self, rowid: 3),
        ]
      )
      expectNoDifference(event.ids(for: TestRecord.self), [1, 3])
      #expect(event.ids(for: UntrackedRecord.self) == nil)
    }
  }
}

@Table
private struct TestRecord: Identifiable {
  @Column(primaryKey: true) var id: Int
  var name: String = ""
  var value: Int?
}

@Table
private struct UntrackedRecord: Identifiable {
  @Column(primaryKey: true) var id: Int
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
