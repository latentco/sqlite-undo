import Testing

@testable import SQLiteUndo

@Suite
struct SQLParserTests {

  @Test(arguments: [
    ("D\ttestRecords\t42", #"DELETE FROM "testRecords" WHERE rowid=42"#),
    ("D\ttestRecords\t999", #"DELETE FROM "testRecords" WHERE rowid=999"#),
    ("D\tmy table\t42", #"DELETE FROM "my table" WHERE rowid=42"#),
  ])
  func deleteParseAndGenerate(_ input: String, _ expectedSQL: String) {
    let parsed = UndoSQL(tabDelimited: input)!
    #expect(parsed.executableSQL == expectedSQL)
  }

  @Test(arguments: [
    ("I\ttestRecords\t1\tid\t1\tname\t'hello'\tvalue\tNULL",
     #"INSERT INTO "testRecords"(rowid,"id","name","value") VALUES(1,1,'hello',NULL)"#),
    ("I\ttestRecords\t1\tid\t1\tname\t'it''s'",
     #"INSERT INTO "testRecords"(rowid,"id","name") VALUES(1,1,'it''s')"#),
    ("I\ttestRecords\t1\tid\t1\tdata\tX'ABCD'",
     #"INSERT INTO "testRecords"(rowid,"id","data") VALUES(1,1,X'ABCD')"#),
    ("I\ttestRecords\t1\tid\t1\tvalue\t-42",
     #"INSERT INTO "testRecords"(rowid,"id","value") VALUES(1,1,-42)"#),
    ("I\ttestRecords\t1\tid\t1\tvalue\t3.14",
     #"INSERT INTO "testRecords"(rowid,"id","value") VALUES(1,1,3.14)"#),
    ("I\ttestRecords\t1\tid\t1\tvalue\t1.5e10",
     #"INSERT INTO "testRecords"(rowid,"id","value") VALUES(1,1,1.5e10)"#),
    ("I\tt\t1",
     #"INSERT INTO "t"(rowid) VALUES(1)"#),
  ])
  func insertParseAndGenerate(_ input: String, _ expectedSQL: String) {
    let parsed = UndoSQL(tabDelimited: input)!
    #expect(parsed.executableSQL == expectedSQL)
  }

  @Test(arguments: [
    ("U\ttestRecords\t1\tname\t'hello'\tvalue\t42",
     #"UPDATE "testRecords" SET "name"='hello',"value"=42 WHERE rowid=1"#),
    ("U\ttestRecords\t1\tname\tNULL",
     #"UPDATE "testRecords" SET "name"=NULL WHERE rowid=1"#),
    ("U\ttestRecords\t1\tdata\tX'ABCD'",
     #"UPDATE "testRecords" SET "data"=X'ABCD' WHERE rowid=1"#),
    ("U\ttestRecords\t1\tvalue\t-3.14",
     #"UPDATE "testRecords" SET "value"=-3.14 WHERE rowid=1"#),
    ("U\ttestRecords\t1\tname\t'it''s a test'",
     #"UPDATE "testRecords" SET "name"='it''s a test' WHERE rowid=1"#),
    ("U\ttestRecords\t1\tname\t'hello world'",
     #"UPDATE "testRecords" SET "name"='hello world' WHERE rowid=1"#),
    ("U\ttestRecords\t1\tname\t'comma,inside'",
     #"UPDATE "testRecords" SET "name"='comma,inside' WHERE rowid=1"#),
  ])
  func updateParseAndGenerate(_ input: String, _ expectedSQL: String) {
    let parsed = UndoSQL(tabDelimited: input)!
    #expect(parsed.executableSQL == expectedSQL)
  }

  @Test
  func deleteParseValues() {
    let parsed = UndoSQL(tabDelimited: "D\tt\t42")!
    guard case let .delete(table, rowids) = parsed else {
      Issue.record("Expected delete, got \(parsed)")
      return
    }
    #expect(table == "t")
    #expect(rowids == ["42"])
  }

  @Test
  func insertParseValues() {
    let parsed = UndoSQL(tabDelimited: "I\tt\t1\ta\t'hello'\tb\tNULL")!
    guard case let .insert(table, columns, rows) = parsed else {
      Issue.record("Expected insert, got \(parsed)")
      return
    }
    #expect(table == "t")
    #expect(columns == ["a", "b"])
    #expect(rows.count == 1)
    #expect(rows[0].rowid == "1")
    #expect(rows[0].values == ["'hello'", "NULL"])
  }

  @Test
  func updateParseValues() {
    let parsed = UndoSQL(tabDelimited: "U\tt\t1\ta\t'x'\tb\t42")!
    guard case let .update(table, assignments, rowids) = parsed else {
      Issue.record("Expected update, got \(parsed)")
      return
    }
    #expect(table == "t")
    #expect(assignments.count == 2)
    #expect(assignments[0].column == "a")
    #expect(assignments[0].value == "'x'")
    #expect(assignments[1].column == "b")
    #expect(assignments[1].value == "42")
    #expect(rowids == ["1"])
  }

  @Test
  func batchedDeleteGenerate() {
    let batched = UndoSQL.delete(table: "t", rowids: ["1", "2", "3"])
    #expect(batched.executableSQL == #"DELETE FROM "t" WHERE rowid IN (1,2,3)"#)
  }

  @Test
  func batchedInsertGenerate() {
    let batched = UndoSQL.insert(
      table: "t",
      columns: ["a"],
      rows: [
        (rowid: "1", values: ["'x'"]),
        (rowid: "2", values: ["'y'"]),
      ]
    )
    #expect(batched.executableSQL == #"INSERT INTO "t"(rowid,"a") VALUES(1,'x'),(2,'y')"#)
  }

  @Test
  func batchedUpdateGenerate() {
    let batched = UndoSQL.update(
      table: "t",
      assignments: [(column: "a", value: "'x'")],
      rowids: ["1", "2"]
    )
    #expect(batched.executableSQL == #"UPDATE "t" SET "a"='x' WHERE rowid IN (1,2)"#)
  }

  @Test
  func updateDifferentAssignmentsNotBatched() {
    let entries: [UndoLogEntry] = [
      UndoLogEntry(
        seq: 0, tableName: "t",
        sql: .update(table: "t", assignments: [(column: "a", value: "'x'")], rowids: ["1"])),
      UndoLogEntry(
        seq: 0, tableName: "t",
        sql: .update(table: "t", assignments: [(column: "a", value: "'y'")], rowids: ["2"])),
    ]
    let result = batchedSQL(from: entries)
    #expect(result == [
      #"UPDATE "t" SET "a"='x' WHERE rowid=1"#,
      #"UPDATE "t" SET "a"='y' WHERE rowid=2"#,
    ])
  }

  @Test
  func updateSameAssignmentsBatched() {
    let entries: [UndoLogEntry] = [
      UndoLogEntry(
        seq: 0, tableName: "t",
        sql: .update(table: "t", assignments: [(column: "a", value: "'x'")], rowids: ["1"])),
      UndoLogEntry(
        seq: 0, tableName: "t",
        sql: .update(table: "t", assignments: [(column: "a", value: "'x'")], rowids: ["2"])),
    ]
    let result = batchedSQL(from: entries)
    #expect(result == [
      #"UPDATE "t" SET "a"='x' WHERE rowid IN (1,2)"#,
    ])
  }

  @Test
  func sparseUpdateOnlyChangedColumns() {
    let entries: [UndoLogEntry] = [
      UndoLogEntry(
        seq: 0, tableName: "t",
        sql: .update(table: "t", assignments: [(column: "value", value: "42")], rowids: ["1"])),
      UndoLogEntry(
        seq: 0, tableName: "t",
        sql: .update(table: "t", assignments: [(column: "value", value: "42")], rowids: ["2"])),
    ]
    let result = batchedSQL(from: entries)
    #expect(result == [
      #"UPDATE "t" SET "value"=42 WHERE rowid IN (1,2)"#,
    ])
  }
}
