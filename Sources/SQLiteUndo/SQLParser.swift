import Parsing

// MARK: - Data Types

/// A double-quoted SQL identifier like `"tableName"` or `"columnName"`.
struct QuotedIdentifier: Equatable, Sendable {
  var name: Substring
}

/// An opaque value from SQLite `quote()` — boundaries found, content untouched.
struct QuotedValue: Equatable, Sendable {
  var raw: Substring
}

/// A column=value pair in an UPDATE SET clause.
struct ColumnAssignment: Equatable, Sendable {
  var column: QuotedIdentifier
  var value: QuotedValue
}

/// Parsed representation of trigger-generated undo SQL.
enum UndoSQL: Equatable, Sendable {
  case delete(table: QuotedIdentifier, rowid: Substring)
  case insert(
    table: QuotedIdentifier, columns: [QuotedIdentifier], rowid: Substring, values: [QuotedValue])
  case update(table: QuotedIdentifier, assignments: [ColumnAssignment], rowid: Substring)
}

// MARK: - Component ParserPrinters

struct QuotedIdentifierParser: ParserPrinter {
  func parse(_ input: inout Substring) throws -> QuotedIdentifier {
    guard input.first == "\"" else {
      struct ExpectedQuote: Error {}
      throw ExpectedQuote()
    }
    input.removeFirst()
    guard let end = input.firstIndex(of: "\"") else {
      struct UnterminatedIdentifier: Error {}
      throw UnterminatedIdentifier()
    }
    let name = input[..<end]
    input = input[input.index(after: end)...]
    return QuotedIdentifier(name: name)
  }

  func print(_ output: QuotedIdentifier, into input: inout Substring) throws {
    var s = "\"" as String
    s += output.name
    s += "\""
    s.append(contentsOf: input)
    input = Substring(s)
  }
}

struct QuotedValueParser: ParserPrinter {
  func parse(_ input: inout Substring) throws -> QuotedValue {
    let start = input.startIndex

    switch input.first {
    case "'":
      // String: 'text with ''escapes'''
      input.removeFirst()
      while !input.isEmpty {
        if input.first == "'" {
          input.removeFirst()
          if input.first == "'" {
            input.removeFirst()
          } else {
            return QuotedValue(raw: input.base[start..<input.startIndex])
          }
        } else {
          input.removeFirst()
        }
      }
      return QuotedValue(raw: input.base[start..<input.startIndex])

    case "X" where input.dropFirst().first == "'":
      // Blob: X'hex'
      input.removeFirst(2)
      if let end = input.firstIndex(of: "'") {
        input = input[input.index(after: end)...]
      } else {
        input = input[input.endIndex...]
      }
      return QuotedValue(raw: input.base[start..<input.startIndex])

    case "N" where input.hasPrefix("NULL"):
      input.removeFirst(4)
      return QuotedValue(raw: input.base[start..<input.startIndex])

    default:
      // Number: scan to delimiter (comma, close paren, space, or end)
      while !input.isEmpty {
        switch input.first! {
        case ",", ")", " ":
          guard input.startIndex > start else {
            struct ExpectedValue: Error {}
            throw ExpectedValue()
          }
          return QuotedValue(raw: input.base[start..<input.startIndex])
        default:
          input.removeFirst()
        }
      }
      guard input.startIndex > start else {
        struct ExpectedValue: Error {}
        throw ExpectedValue()
      }
      return QuotedValue(raw: input.base[start..<input.startIndex])
    }
  }

  func print(_ output: QuotedValue, into input: inout Substring) throws {
    var s = String(output.raw)
    s.append(contentsOf: input)
    input = Substring(s)
  }
}

// MARK: - Statement ParserPrinters

struct DeleteSQLParser: ParserPrinter {
  func parse(_ input: inout Substring) throws -> UndoSQL {
    guard input.hasPrefix("DELETE FROM ") else {
      struct NotDelete: Error {}
      throw NotDelete()
    }
    input.removeFirst(12)
    let table = try QuotedIdentifierParser().parse(&input)
    guard input.hasPrefix(" WHERE rowid=") else {
      struct ExpectedWhere: Error {}
      throw ExpectedWhere()
    }
    input.removeFirst(13)
    let rowid = input
    input = input[input.endIndex...]
    return .delete(table: table, rowid: rowid)
  }

  func print(_ output: UndoSQL, into input: inout Substring) throws {
    guard case let .delete(table, rowid) = output else {
      struct NotDelete: Error {}
      throw NotDelete()
    }
    var s = "DELETE FROM \"\(table.name)\" WHERE rowid=" as String
    s.append(contentsOf: rowid)
    s.append(contentsOf: input)
    input = Substring(s)
  }
}

struct InsertSQLParser: ParserPrinter {
  func parse(_ input: inout Substring) throws -> UndoSQL {
    guard input.hasPrefix("INSERT INTO ") else {
      struct NotInsert: Error {}
      throw NotInsert()
    }
    input.removeFirst(12)
    let table = try QuotedIdentifierParser().parse(&input)

    guard input.hasPrefix("(rowid") else {
      struct ExpectedRowid: Error {}
      throw ExpectedRowid()
    }
    input.removeFirst(6)

    // Parse optional column list after rowid
    var columns: [QuotedIdentifier] = []
    if input.first == "," {
      input.removeFirst()
      while true {
        let col = try QuotedIdentifierParser().parse(&input)
        columns.append(col)
        if input.first == "," {
          input.removeFirst()
        } else {
          break
        }
      }
    }

    guard input.hasPrefix(") VALUES(") else {
      struct ExpectedValues: Error {}
      throw ExpectedValues()
    }
    input.removeFirst(9)

    // Parse rowid value
    let rowidStart = input.startIndex
    while !input.isEmpty && input.first != "," && input.first != ")" {
      input.removeFirst()
    }
    let rowid = input.base[rowidStart..<input.startIndex]

    // Parse column values if any
    var values: [QuotedValue] = []
    if input.first == "," {
      input.removeFirst()
      while true {
        let val = try QuotedValueParser().parse(&input)
        values.append(val)
        if input.first == "," {
          input.removeFirst()
        } else {
          break
        }
      }
    }

    guard input.first == ")" else {
      struct ExpectedCloseParen: Error {}
      throw ExpectedCloseParen()
    }
    input.removeFirst()

    return .insert(table: table, columns: columns, rowid: rowid, values: values)
  }

  func print(_ output: UndoSQL, into input: inout Substring) throws {
    guard case let .insert(table, columns, rowid, values) = output else {
      struct NotInsert: Error {}
      throw NotInsert()
    }
    var s = "INSERT INTO \"\(table.name)\"(rowid" as String
    if !columns.isEmpty {
      s += ","
      s += columns.map { "\"\($0.name)\"" as String }.joined(separator: ",")
    }
    s += ") VALUES("
    s.append(contentsOf: rowid)
    for val in values {
      s += ","
      s.append(contentsOf: val.raw)
    }
    s += ")"
    s.append(contentsOf: input)
    input = Substring(s)
  }
}

struct UpdateSQLParser: ParserPrinter {
  func parse(_ input: inout Substring) throws -> UndoSQL {
    guard input.hasPrefix("UPDATE ") else {
      struct NotUpdate: Error {}
      throw NotUpdate()
    }
    input.removeFirst(7)
    let table = try QuotedIdentifierParser().parse(&input)

    guard input.hasPrefix(" SET ") else {
      struct ExpectedSet: Error {}
      throw ExpectedSet()
    }
    input.removeFirst(5)

    // Parse assignments: "col"=val,"col2"=val2
    var assignments: [ColumnAssignment] = []
    while true {
      let col = try QuotedIdentifierParser().parse(&input)
      guard input.first == "=" else {
        struct ExpectedEquals: Error {}
        throw ExpectedEquals()
      }
      input.removeFirst()
      let val = try QuotedValueParser().parse(&input)
      assignments.append(ColumnAssignment(column: col, value: val))
      if input.first == "," {
        input.removeFirst()
      } else {
        break
      }
    }

    guard input.hasPrefix(" WHERE rowid=") else {
      struct ExpectedWhere: Error {}
      throw ExpectedWhere()
    }
    input.removeFirst(13)
    let rowid = input
    input = input[input.endIndex...]

    return .update(table: table, assignments: assignments, rowid: rowid)
  }

  func print(_ output: UndoSQL, into input: inout Substring) throws {
    guard case let .update(table, assignments, rowid) = output else {
      struct NotUpdate: Error {}
      throw NotUpdate()
    }
    var s = "UPDATE \"\(table.name)\" SET " as String
    s += assignments.map { "\"\($0.column.name)\"=\($0.value.raw)" as String }.joined(separator: ",")
    s += " WHERE rowid="
    s.append(contentsOf: rowid)
    s.append(contentsOf: input)
    input = Substring(s)
  }
}

/// Top-level parser for trigger-generated undo SQL.
struct UndoSQLParser: ParserPrinter {
  func parse(_ input: inout Substring) throws -> UndoSQL {
    let saved = input
    do { return try DeleteSQLParser().parse(&input) }
    catch { input = saved }
    do { return try InsertSQLParser().parse(&input) }
    catch { input = saved }
    return try UpdateSQLParser().parse(&input)
  }

  func print(_ output: UndoSQL, into input: inout Substring) throws {
    switch output {
    case .delete: try DeleteSQLParser().print(output, into: &input)
    case .insert: try InsertSQLParser().print(output, into: &input)
    case .update: try UpdateSQLParser().print(output, into: &input)
    }
  }
}

// MARK: - SQL Batching

/// Maximum entries per batch to stay within SQLite limits.
private let maxBatchSize = 500

/// When true, disables batching so each entry executes individually.
/// Used for benchmarking to compare batched vs unbatched performance.
nonisolated(unsafe) var _undoBatchingDisabled = false

/// Groups consecutive same-table, same-type entries into batched SQL.
func batchedSQL(from entries: [UndoLogEntry]) -> [String] {
  if _undoBatchingDisabled {
    return entries.map(\.sql)
  }

  let items: [(sql: String, parsed: UndoSQL?)] = entries.map { entry in
    var input = Substring(entry.sql)
    let parsed = (try? UndoSQLParser().parse(&input)).flatMap { input.isEmpty ? $0 : nil }
    return (entry.sql, parsed)
  }

  var remaining = items[...]
  var result: [String] = []

  while let first = remaining.popFirst() {
    guard let current = first.parsed else {
      result.append(first.sql)
      continue
    }

    switch current {
    case let .delete(table, rowid):
      var rowids = [rowid]
      while rowids.count < maxBatchSize {
        guard case let .delete(t, r)? = remaining.first?.parsed, t == table else { break }
        rowids.append(r)
        remaining.removeFirst()
      }
      result.append(batchedDeleteSQL(table: table, rowids: rowids))

    case let .insert(table, columns, rowid, values):
      var rows: [(rowid: Substring, values: [QuotedValue])] = [(rowid, values)]
      while rows.count < maxBatchSize {
        guard case let .insert(t, _, r, v)? = remaining.first?.parsed, t == table else { break }
        rows.append((r, v))
        remaining.removeFirst()
      }
      result.append(batchedInsertSQL(table: table, columns: columns, rows: rows))

    case let .update(table, assignments, rowid):
      let columns = assignments.map(\.column)
      var rows: [(rowid: Substring, values: [QuotedValue])] = [(rowid, assignments.map(\.value))]
      while rows.count < maxBatchSize {
        guard case let .update(t, a, r)? = remaining.first?.parsed, t == table else { break }
        rows.append((r, a.map(\.value)))
        remaining.removeFirst()
      }
      if rows.count == 1 {
        result.append(first.sql)
      } else {
        result.append(batchedUpdateSQL(table: table, columns: columns, rows: rows))
      }
    }
  }

  return result
}

func batchedDeleteSQL(table: QuotedIdentifier, rowids: [Substring]) -> String {
  let rowidList = rowids.joined(separator: ",") as String
  return "DELETE FROM \"\(table.name)\" WHERE rowid IN (\(rowidList))" as String
}

func batchedInsertSQL(
  table: QuotedIdentifier, columns: [QuotedIdentifier],
  rows: [(rowid: Substring, values: [QuotedValue])]
) -> String {
  var colList = "rowid" as String
  if !columns.isEmpty {
    colList += ","
    colList += columns.map { "\"\($0.name)\"" as String }.joined(separator: ",")
  }
  let valuesList =
    rows.map { row -> String in
      let vals = ([row.rowid] + row.values.map(\.raw)).joined(separator: ",") as String
      return "(\(vals))" as String
    }.joined(separator: ",")
  return "INSERT INTO \"\(table.name)\"(\(colList)) VALUES\(valuesList)" as String
}

func batchedUpdateSQL(
  table: QuotedIdentifier, columns: [QuotedIdentifier],
  rows: [(rowid: Substring, values: [QuotedValue])]
) -> String {
  let setExprs =
    columns.map { "\"\($0.name)\"=_v.\"\($0.name)\"" as String }.joined(separator: ",") as String
  let valueRows =
    rows.map { row -> String in
      let vals = ([row.rowid] + row.values.map(\.raw)).joined(separator: ",") as String
      return "(\(vals))" as String
    }.joined(separator: ",") as String
  let aliases =
    (["_r"] + columns.map { "\"\($0.name)\"" as String }).joined(separator: ",") as String
  return
    "WITH _v(\(aliases)) AS (VALUES \(valueRows)) UPDATE \"\(table.name)\" SET \(setExprs) FROM _v WHERE \"\(table.name)\".rowid=_v._r"
    as String
}
