import Foundation
import SQLiteData
import StructuredQueries
import Testing

@testable import SQLiteUndo

@Suite(.serialized)
struct ForeignKeyTests {

  @Test
  func undoDeleteChildThenParent() throws {
    let (database, engine) = try makeFKDatabase()

    try withUndoDisabled {
      try database.write { db in
        try db.execute(sql: """
          INSERT INTO "parents" ("id", "name") VALUES (1, 'Parent');
          INSERT INTO "children" ("id", "parentId", "name") VALUES (1, 1, 'Child');
          """)
      }
    }

    let barrierId = try engine.beginBarrier("Delete Both")
    try database.write { db in
      try db.execute(sql: """
        DELETE FROM "children" WHERE "id" = 1;
        DELETE FROM "parents" WHERE "id" = 1;
        """)
    }
    let barrier = try engine.endBarrier(barrierId)!

    try engine.performUndo(barrier: barrier)

    let (parentCount, childCount) = try database.read { db in
      (
        try Parent.all.fetchCount(db),
        try Child.all.fetchCount(db)
      )
    }
    #expect(parentCount == 1)
    #expect(childCount == 1)
  }

  @Test
  func undoDeleteParentCascade() throws {
    let (database, engine) = try makeFKDatabase()

    try withUndoDisabled {
      try database.write { db in
        try db.execute(sql: """
          INSERT INTO "parents" ("id", "name") VALUES (1, 'Parent');
          INSERT INTO "children" ("id", "parentId", "name") VALUES (1, 1, 'Child');
          """)
      }
    }

    let barrierId = try engine.beginBarrier("Delete Parent")
    try database.write { db in
      try db.execute(sql: """
        DELETE FROM "parents" WHERE "id" = 1
        """)
    }
    let barrier = try engine.endBarrier(barrierId)!

    try engine.performUndo(barrier: barrier)

    let (parentCount, childCount) = try database.read { db in
      (
        try Parent.all.fetchCount(db),
        try Child.all.fetchCount(db)
      )
    }
    #expect(parentCount == 1)
    #expect(childCount == 1)
  }

  @Test
  func undoCascadeDeleteMultipleChildren() throws {
    let (database, engine) = try makeFKDatabase()

    try withUndoDisabled {
      try database.write { db in
        try db.execute(sql: """
          INSERT INTO "parents" ("id", "name") VALUES (1, 'Parent');
          INSERT INTO "children" ("id", "parentId", "name") VALUES (1, 1, 'Child A');
          INSERT INTO "children" ("id", "parentId", "name") VALUES (2, 1, 'Child B');
          """)
      }
    }

    let barrierId = try engine.beginBarrier("Delete Parent")
    try database.write { db in
      try db.execute(sql: """
        DELETE FROM "parents" WHERE "id" = 1
        """)
    }
    let barrier = try engine.endBarrier(barrierId)!

    let counts = try database.read { db in
      (try Parent.all.fetchCount(db), try Child.all.fetchCount(db))
    }
    #expect(counts.0 == 0)
    #expect(counts.1 == 0)

    try engine.performUndo(barrier: barrier)

    let restored = try database.read { db in
      (
        try Parent.all.fetchCount(db),
        try Child.all.fetchCount(db),
        try Child.all.order(by: \.id).fetchAll(db)
      )
    }
    #expect(restored.0 == 1)
    #expect(restored.1 == 2)
    #expect(restored.2.map(\.name) == ["Child A", "Child B"])
  }

  @Test
  func undoRedoCascadeRoundTrip() throws {
    let (database, engine) = try makeFKDatabase()

    try withUndoDisabled {
      try database.write { db in
        try db.execute(sql: """
          INSERT INTO "parents" ("id", "name") VALUES (1, 'Parent');
          INSERT INTO "children" ("id", "parentId", "name") VALUES (1, 1, 'Child');
          """)
      }
    }

    let barrierId = try engine.beginBarrier("Delete Parent")
    try database.write { db in
      try db.execute(sql: """
        DELETE FROM "parents" WHERE "id" = 1
        """)
    }
    let barrier = try engine.endBarrier(barrierId)!

    // Undo — restore parent and child
    try engine.performUndo(barrier: barrier)
    var counts = try database.read { db in
      (try Parent.all.fetchCount(db), try Child.all.fetchCount(db))
    }
    #expect(counts == (1, 1))

    // Redo — delete again
    try engine.performRedo(barrier: barrier)
    counts = try database.read { db in
      (try Parent.all.fetchCount(db), try Child.all.fetchCount(db))
    }
    #expect(counts == (0, 0))

    // Undo again — restore once more
    try engine.performUndo(barrier: barrier)
    counts = try database.read { db in
      (try Parent.all.fetchCount(db), try Child.all.fetchCount(db))
    }
    #expect(counts == (1, 1))
  }

  @Test
  func cascadeCaptureRespectsUndoDisabled() throws {
    let (database, _) = try makeFKDatabase()

    try withUndoDisabled {
      try database.write { db in
        try db.execute(sql: """
          INSERT INTO "parents" ("id", "name") VALUES (1, 'Parent');
          INSERT INTO "children" ("id", "parentId", "name") VALUES (1, 1, 'Child');
          """)
      }
    }

    try withUndoDisabled {
      try database.write { db in
        try db.execute(sql: """
          DELETE FROM "parents" WHERE "id" = 1
          """)
      }
    }

    let undoLogCount = try database.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM undolog")
    }
    #expect(undoLogCount == 0)
  }
}

@Table("parents")
private struct Parent: Identifiable {
  @Column(primaryKey: true) var id: Int
  var name: String = ""
}

@Table("children")
private struct Child: Identifiable {
  @Column(primaryKey: true) var id: Int
  var parentId: Int
  var name: String = ""
}

private func makeFKDatabase() throws -> (any DatabaseWriter, UndoCoordinator) {
  var config = Configuration()
  config.prepareDatabase { db in
    try db.execute(sql: "PRAGMA foreign_keys = ON")
  }
  let database = try DatabaseQueue(configuration: config)

  try database.write { db in
    try db.execute(sql: """
      CREATE TABLE "parents" (
        "id" INTEGER PRIMARY KEY,
        "name" TEXT NOT NULL DEFAULT ''
      );
      CREATE TABLE "children" (
        "id" INTEGER PRIMARY KEY,
        "parentId" INTEGER NOT NULL REFERENCES "parents"("id") ON DELETE CASCADE,
        "name" TEXT NOT NULL DEFAULT ''
      );
      """)
  }

  try database.installUndoSystem()
  try database.write { db in
    try Parent.installUndoTriggers(db)
    try Child.installUndoTriggers(db)
  }

  return (database, UndoCoordinator(database: database))
}
