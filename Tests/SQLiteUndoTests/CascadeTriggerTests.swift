import Foundation
import SQLiteData
import Testing

@testable import SQLiteUndo

@Suite(.serialized)
struct CascadeTriggerTests {

  @Suite
  struct SameRowCascade {

    @Test
    func undoRevertsOriginalValues() throws {
      // App trigger: AFTER UPDATE OF value → sets flag=1 on the same row
      // Undo should restore both value and flag to their originals
      let (database, engine) = try makeCascadeDatabase(trigger: .sameRowFlag)

      try withUndoDisabled {
        try database.write { db in
          try db.execute(
            sql: """
              INSERT INTO "cascadeItems" ("id", "value", "flag") VALUES (1, 'original', 0)
              """)
        }
      }

      let barrierId = try engine.beginBarrier("Update Value")
      try database.write { db in
        try db.execute(
          sql: """
            UPDATE "cascadeItems" SET "value" = 'changed' WHERE "id" = 1
            """)
      }
      let barrier = try engine.endBarrier(barrierId)!

      // Verify the cascade fired: flag should be 1
      try database.read { db in
        let item = try CascadeItem.find(1).fetchOne(db)!
        #expect(item.value == "changed")
        #expect(item.flag == 1)
      }

      try engine.performUndo(barrier: barrier)

      // After undo: both value and flag should be restored to originals
      try database.read { db in
        let item = try CascadeItem.find(1).fetchOne(db)!
        #expect(item.value == "original")
        #expect(item.flag == 0)
      }
    }
  }

  @Suite
  struct CrossRowCascade {

    @Test
    func undoRevertsBothRows() throws {
      // App trigger: AFTER UPDATE OF value ON cascadeItems
      //   → UPDATE cascadeItems SET flag=1 WHERE id != NEW.id
      // Updating row A cascades to set flag=1 on row B.
      // Undo should revert both.
      let (database, engine) = try makeCascadeDatabase(trigger: .crossRowFlag)

      try withUndoDisabled {
        try database.write { db in
          try db.execute(
            sql: """
              INSERT INTO "cascadeItems" ("id", "value", "flag") VALUES (1, 'A', 0);
              INSERT INTO "cascadeItems" ("id", "value", "flag") VALUES (2, 'B', 0);
              """)
        }
      }

      let barrierId = try engine.beginBarrier("Update A")
      try database.write { db in
        try db.execute(
          sql: """
            UPDATE "cascadeItems" SET "value" = 'A-changed' WHERE "id" = 1
            """)
      }
      let barrier = try engine.endBarrier(barrierId)!

      // Verify cascade: row A updated, row B got flag=1
      try database.read { db in
        let a = try CascadeItem.find(1).fetchOne(db)!
        #expect(a.value == "A-changed")
        let b = try CascadeItem.find(2).fetchOne(db)!
        #expect(b.flag == 1)
      }

      try engine.performUndo(barrier: barrier)

      // After undo: both rows should be restored
      try database.read { db in
        let a = try CascadeItem.find(1).fetchOne(db)!
        #expect(a.value == "A")
        #expect(a.flag == 0)
        let b = try CascadeItem.find(2).fetchOne(db)!
        #expect(b.value == "B")
        #expect(b.flag == 0)
      }
    }
  }

  @Suite
  struct EdgeCases {

    @Test
    func insertThenDeleteIsNoOp() throws {
      let (database, engine) = try makeCascadeDatabase(trigger: .none)

      let barrierId = try engine.beginBarrier("Insert Then Delete")
      try database.write { db in
        try db.execute(
          sql: """
            INSERT INTO "cascadeItems" ("id", "value", "flag") VALUES (1, 'temp', 0)
            """)
        try db.execute(
          sql: """
            DELETE FROM "cascadeItems" WHERE "id" = 1
            """)
      }
      let barrier = try engine.endBarrier(barrierId)

      // The barrier may be nil (if reconciliation removes all entries)
      // or non-nil but undo should be a no-op
      if let barrier {
        try engine.performUndo(barrier: barrier)
      }

      try database.read { db in
        let count = try CascadeItem.all.fetchCount(db)
        #expect(count == 0)
      }
    }

    @Test
    func insertThenUpdateUndoDeletesRow() throws {
      let (database, engine) = try makeCascadeDatabase(trigger: .none)

      let barrierId = try engine.beginBarrier("Insert Then Update")
      try database.write { db in
        try db.execute(
          sql: """
            INSERT INTO "cascadeItems" ("id", "value", "flag") VALUES (1, 'initial', 0)
            """)
        try db.execute(
          sql: """
            UPDATE "cascadeItems" SET "value" = 'modified' WHERE "id" = 1
            """)
      }
      let barrier = try engine.endBarrier(barrierId)!

      try database.read { db in
        let item = try CascadeItem.find(1).fetchOne(db)!
        #expect(item.value == "modified")
      }

      // Undo should delete the row (reverse of the INSERT)
      try engine.performUndo(barrier: barrier)

      try database.read { db in
        let count = try CascadeItem.all.fetchCount(db)
        #expect(count == 0)
      }
    }

    @Test
    func updateThenDeleteUndoReInsertsOriginal() throws {
      let (database, engine) = try makeCascadeDatabase(trigger: .none)

      try withUndoDisabled {
        try database.write { db in
          try db.execute(
            sql: """
              INSERT INTO "cascadeItems" ("id", "value", "flag") VALUES (1, 'original', 0)
              """)
        }
      }

      let barrierId = try engine.beginBarrier("Update Then Delete")
      try database.write { db in
        try db.execute(
          sql: """
            UPDATE "cascadeItems" SET "value" = 'modified' WHERE "id" = 1
            """)
        try db.execute(
          sql: """
            DELETE FROM "cascadeItems" WHERE "id" = 1
            """)
      }
      let barrier = try engine.endBarrier(barrierId)!

      try database.read { db in
        let count = try CascadeItem.all.fetchCount(db)
        #expect(count == 0)
      }

      // Undo should re-insert with original pre-update values
      try engine.performUndo(barrier: barrier)

      try database.read { db in
        let item = try CascadeItem.find(1).fetchOne(db)!
        #expect(item.value == "original")
        #expect(item.flag == 0)
      }
    }

    @Test
    func undoRedoRoundTrip() throws {
      let (database, engine) = try makeCascadeDatabase(trigger: .sameRowFlag)

      try withUndoDisabled {
        try database.write { db in
          try db.execute(
            sql: """
              INSERT INTO "cascadeItems" ("id", "value", "flag") VALUES (1, 'original', 0)
              """)
        }
      }

      let barrierId = try engine.beginBarrier("Update")
      try database.write { db in
        try db.execute(
          sql: """
            UPDATE "cascadeItems" SET "value" = 'changed' WHERE "id" = 1
            """)
      }
      let barrier = try engine.endBarrier(barrierId)!

      // Undo
      try engine.performUndo(barrier: barrier)
      try database.read { db in
        let item = try CascadeItem.find(1).fetchOne(db)!
        #expect(item.value == "original")
        #expect(item.flag == 0)
      }

      // Redo
      try engine.performRedo(barrier: barrier)
      try database.read { db in
        let item = try CascadeItem.find(1).fetchOne(db)!
        #expect(item.value == "changed")
        #expect(item.flag == 1)
      }

      // Undo again
      try engine.performUndo(barrier: barrier)
      try database.read { db in
        let item = try CascadeItem.find(1).fetchOne(db)!
        #expect(item.value == "original")
        #expect(item.flag == 0)
      }
    }
  }
}

@Table("cascadeItems")
private struct CascadeItem: Identifiable {
  @Column(primaryKey: true) var id: Int
  var value: String = ""
  var flag: Int = 0
}

private enum CascadeTrigger {
  case none
  case sameRowFlag
  case crossRowFlag
}

private func makeCascadeDatabase(
  trigger: CascadeTrigger
) throws -> (any DatabaseWriter, UndoCoordinator) {
  let database = try DatabaseQueue(configuration: Configuration())

  try database.write { db in
    try db.execute(
      sql: """
        CREATE TABLE "cascadeItems" (
          "id" INTEGER PRIMARY KEY,
          "value" TEXT NOT NULL DEFAULT '',
          "flag" INTEGER NOT NULL DEFAULT 0
        )
        """)
  }

  try database.installUndoSystem()
  try database.write { db in
    for sql in CascadeItem.generateUndoTriggers() {
      try db.execute(sql: sql)
    }
  }

  if trigger != .none {
    try database.write { db in
      let whereClause: String
      switch trigger {
      case .none:
        fatalError()
      case .sameRowFlag:
        whereClause = "rowid = NEW.rowid"
      case .crossRowFlag:
        whereClause = "id != NEW.id"
      }
      try db.execute(
        sql: """
          CREATE TEMPORARY TRIGGER cascade_trigger
          AFTER UPDATE OF "value" ON "cascadeItems"
          WHEN NOT "sqliteundo_isReplaying"()
          BEGIN
            UPDATE "cascadeItems" SET "flag" = 1 WHERE \(whereClause);
          END
          """)
    }
  }

  return (database, UndoCoordinator(database: database))
}
