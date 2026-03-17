import Testing

@testable import SQLiteUndo

@Suite
struct SQLParserTests {

  @Test(arguments: [
    #"DELETE FROM "testRecords" WHERE rowid=1"#,
    #"DELETE FROM "testRecords" WHERE rowid=999"#,
    #"DELETE FROM "my table" WHERE rowid=42"#,
  ])
  func deleteRoundTrip(_ sql: String) throws {
    try assertRoundTrip(sql)
  }

  @Test(arguments: [
    #"INSERT INTO "testRecords"(rowid,"id","name","value") VALUES(1,1,'hello',NULL)"#,
    #"INSERT INTO "testRecords"(rowid,"id","name") VALUES(1,1,'it''s')"#,
    #"INSERT INTO "testRecords"(rowid,"id","data") VALUES(1,1,X'ABCD')"#,
    #"INSERT INTO "testRecords"(rowid,"id","value") VALUES(1,1,-42)"#,
    #"INSERT INTO "testRecords"(rowid,"id","value") VALUES(1,1,3.14)"#,
    #"INSERT INTO "testRecords"(rowid,"id","value") VALUES(1,1,1.5e10)"#,
    #"INSERT INTO "t"(rowid) VALUES(1)"#,
  ])
  func insertRoundTrip(_ sql: String) throws {
    try assertRoundTrip(sql)
  }

  @Test(arguments: [
    #"UPDATE "testRecords" SET "name"='hello',"value"=42 WHERE rowid=1"#,
    #"UPDATE "testRecords" SET "name"=NULL WHERE rowid=1"#,
    #"UPDATE "testRecords" SET "data"=X'ABCD' WHERE rowid=1"#,
    #"UPDATE "testRecords" SET "value"=-3.14 WHERE rowid=1"#,
    #"UPDATE "testRecords" SET "name"='it''s a test' WHERE rowid=1"#,
    #"UPDATE "testRecords" SET "name"='hello world' WHERE rowid=1"#,
    #"UPDATE "testRecords" SET "name"='comma,inside' WHERE rowid=1"#,
  ])
  func updateRoundTrip(_ sql: String) throws {
    try assertRoundTrip(sql)
  }

  @Test
  func deleteParseValues() throws {
    let parsed = try parseSQL(#"DELETE FROM "t" WHERE rowid=42"#)
    guard case let .delete(table, rowids) = parsed else {
      Issue.record("Expected delete, got \(parsed)")
      return
    }
    #expect(table.name == "t")
    #expect(rowids.map(String.init) == ["42"])
  }

  @Test
  func insertParseValues() throws {
    let parsed = try parseSQL(
      #"INSERT INTO "t"(rowid,"a","b") VALUES(1,'hello',NULL)"#)
    guard case let .insert(table, columns, rows) = parsed else {
      Issue.record("Expected insert, got \(parsed)")
      return
    }
    #expect(table.name == "t")
    #expect(columns.map(\.name) == ["a", "b"])
    #expect(rows.count == 1)
    #expect(String(rows[0].rowid) == "1")
    #expect(rows[0].values.map(\.raw).map(String.init) == ["'hello'", "NULL"])
  }

  @Test
  func updateParseValues() throws {
    let parsed = try parseSQL(
      #"UPDATE "t" SET "a"='x',"b"=42 WHERE rowid=1"#)
    guard case let .update(table, assignments, rowids) = parsed else {
      Issue.record("Expected update, got \(parsed)")
      return
    }
    #expect(table.name == "t")
    #expect(assignments.count == 2)
    #expect(assignments[0].column.name == "a")
    #expect(assignments[0].value.raw == "'x'")
    #expect(assignments[1].column.name == "b")
    #expect(assignments[1].value.raw == "42")
    #expect(rowids.map(String.init) == ["1"])
  }

  @Test
  func batchedDeletePrint() throws {
    let batched = UndoSQL.delete(
      table: QuotedIdentifier(name: "t"),
      rowids: ["1", "2", "3"]
    )
    var output = Substring()
    try UndoSQLParser().print(batched, into: &output)
    #expect(String(output) == #"DELETE FROM "t" WHERE rowid IN (1,2,3)"#)
  }

  @Test
  func batchedInsertPrint() throws {
    let batched = UndoSQL.insert(
      table: QuotedIdentifier(name: "t"),
      columns: [QuotedIdentifier(name: "a")],
      rows: [
        (rowid: "1"[...], values: [QuotedValue(raw: "'x'")]),
        (rowid: "2"[...], values: [QuotedValue(raw: "'y'")]),
      ]
    )
    var output = Substring()
    try UndoSQLParser().print(batched, into: &output)
    #expect(String(output) == #"INSERT INTO "t"(rowid,"a") VALUES(1,'x'),(2,'y')"#)
  }

  @Test
  func batchedUpdatePrint() throws {
    let batched = UndoSQL.update(
      table: QuotedIdentifier(name: "t"),
      assignments: [
        ColumnAssignment(column: QuotedIdentifier(name: "a"), value: QuotedValue(raw: "'x'")),
      ],
      rowids: ["1", "2"]
    )
    var output = Substring()
    try UndoSQLParser().print(batched, into: &output)
    #expect(
      String(output) == #"UPDATE "t" SET "a"='x' WHERE rowid IN (1,2)"#
    )
  }

  @Test
  func updateDifferentAssignmentsNotBatched() {
    let entries: [UndoLogEntry] = [
      UndoLogEntry(seq: 0, tableName: "t", sql: #"UPDATE "t" SET "a"='x' WHERE rowid=1"#),
      UndoLogEntry(seq: 0, tableName: "t", sql: #"UPDATE "t" SET "a"='y' WHERE rowid=2"#),
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
      UndoLogEntry(seq: 0, tableName: "t", sql: #"UPDATE "t" SET "a"='x' WHERE rowid=1"#),
      UndoLogEntry(seq: 0, tableName: "t", sql: #"UPDATE "t" SET "a"='x' WHERE rowid=2"#),
    ]
    let result = batchedSQL(from: entries)
    #expect(result == [
      #"UPDATE "t" SET "a"='x' WHERE rowid IN (1,2)"#,
    ])
  }
}

private func parseSQL(_ sql: String) throws -> UndoSQL {
  var input = Substring(sql)
  let parsed = try UndoSQLParser().parse(&input)
  #expect(input.isEmpty)
  return parsed
}

private func assertRoundTrip(_ sql: String) throws {
  let parsed = try parseSQL(sql)
  var output = Substring()
  try UndoSQLParser().print(parsed, into: &output)
  #expect(String(output) == sql)
}
