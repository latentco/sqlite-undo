import Foundation
import IssueReportingTestSupport
import StructuredQueries
import Testing

@testable import SQLiteUndo

@Suite
struct UnregisteredTableTests {

  @Test
  func warnsWhenModifyingUnregisteredTable() throws {
    let database = try makeDatabase()
    try database.installUndoSystem()

    // Only register ArticleRecord, not AuditRecord
    try database.write { db in
      for sql in ArticleRecord.generateUndoTriggers() {
        try db.execute(sql: sql)
      }
      for sql in AuditRecord.generateUndoTriggers() {
        try db.execute(sql: sql)
      }
    }

    let coordinator = UndoCoordinator(
      database: database,
      registeredTables: [ArticleRecord.tableName]
    )

    let barrierId = try coordinator.beginBarrier("Mixed Changes")
    try database.write { db in
      try ArticleRecord.insert { ArticleRecord(id: 1, name: "Article") }.execute(db)
      try AuditRecord.insert { AuditRecord(id: 1, data: "Created article") }.execute(db)
    }

    try withKnownIssue {
      _ = try coordinator.endBarrier(barrierId)
    } matching: { issue in
      issue.description.contains("auditRecords")
    }
  }

  @Test
  func noWarningWhenModifyingOnlyRegisteredTables() throws {
    let database = try makeDatabase()
    try database.installUndoSystem()

    try database.write { db in
      for sql in ArticleRecord.generateUndoTriggers() {
        try db.execute(sql: sql)
      }
      for sql in AuditRecord.generateUndoTriggers() {
        try db.execute(sql: sql)
      }
    }

    // Both tables registered
    let coordinator = UndoCoordinator(
      database: database,
      registeredTables: [ArticleRecord.tableName, AuditRecord.tableName]
    )

    let barrierId = try coordinator.beginBarrier("Both Registered")
    try database.write { db in
      try ArticleRecord.insert { ArticleRecord(id: 1, name: "Article") }.execute(db)
      try AuditRecord.insert { AuditRecord(id: 1, data: "Audit") }.execute(db)
    }

    let barrier = try coordinator.endBarrier(barrierId)
    #expect(barrier != nil)
  }

  @Test
  func noWarningWhenModifyingUntrackedTable() throws {
    let database = try makeDatabase()
    try database.installUndoSystem()

    try database.write { db in
      for sql in ArticleRecord.generateUndoTriggers() {
        try db.execute(sql: sql)
      }
      for sql in AuditRecord.generateUndoTriggers() {
        try db.execute(sql: sql)
      }
    }

    // AuditRecord is in untracked list
    let coordinator = UndoCoordinator(
      database: database,
      registeredTables: [ArticleRecord.tableName],
      untrackedTables: [AuditRecord.tableName]
    )

    let barrierId = try coordinator.beginBarrier("With Untracked")
    try database.write { db in
      try ArticleRecord.insert { ArticleRecord(id: 1, name: "Article") }.execute(db)
      try AuditRecord.insert { AuditRecord(id: 1, data: "Audit log entry") }.execute(db)
    }

    let barrier = try coordinator.endBarrier(barrierId)
    #expect(barrier != nil)
  }
}

@Table
private struct ArticleRecord: UndoTracked {
  @Column(primaryKey: true) var id: Int
  var name: String = ""
}

@Table
private struct AuditRecord: UndoTracked {
  @Column(primaryKey: true) var id: Int
  var data: String = ""
}

private func makeDatabase() throws -> any DatabaseWriter {
  let database = try DatabaseQueue(configuration: Configuration())
  try database.write { db in
    try db.execute(
      sql: """
        CREATE TABLE "articleRecords" (
          "id" INTEGER PRIMARY KEY,
          "name" TEXT NOT NULL DEFAULT ''
        )
        """
    )
    try db.execute(
      sql: """
        CREATE TABLE "auditRecords" (
          "id" INTEGER PRIMARY KEY,
          "data" TEXT NOT NULL DEFAULT ''
        )
        """
    )
  }
  return database
}
