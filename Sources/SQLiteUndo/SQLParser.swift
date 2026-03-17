import Parsing

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

/// Parsed representation of trigger-generated undo SQL.
/// Parsers produce single-element arrays; batching merges consecutive same-key entries.
enum UndoSQL: Equatable, Sendable {
  case delete(
    table: QuotedIdentifier,
    rowids: [Substring]
  )
  case insert(
    table: QuotedIdentifier, columns: [QuotedIdentifier],
    rows: [(rowid: Substring, values: [QuotedValue])]
  )
  case update(
    table: QuotedIdentifier,
    assignments: [ColumnAssignment],
    rowids: [Substring]
  )

  static func == (lhs: UndoSQL, rhs: UndoSQL) -> Bool {
    switch (lhs, rhs) {
    case let (.delete(lt, lr), .delete(rt, rr)):
      return lt == rt && lr.map(String.init) == rr.map(String.init)
    case let (.insert(lt, lc, lrows), .insert(rt, rc, rrows)):
      guard lt == rt && lc == rc && lrows.count == rrows.count else { return false }
      for (l, r) in zip(lrows, rrows) {
        guard String(l.rowid) == String(r.rowid) && l.values == r.values else { return false }
      }
      return true
    case let (.update(lt, la, lr), .update(rt, ra, rr)):
      return lt == rt && la == ra && lr.map(String.init) == rr.map(String.init)
    default:
      return false
    }
  }
}

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
    return .delete(table: table, rowids: [rowid])
  }

  func print(_ output: UndoSQL, into input: inout Substring) throws {
    guard case let .delete(table, rowids) = output else {
      struct NotDelete: Error {}
      throw NotDelete()
    }
    var s = "DELETE FROM \"\(table.name)\"" as String
    if rowids.count == 1 {
      s += " WHERE rowid="
      s.append(contentsOf: rowids[0])
    } else {
      s += " WHERE rowid IN ("
      s += rowids.map(String.init).joined(separator: ",")
      s += ")"
    }
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

    return .insert(table: table, columns: columns, rows: [(rowid: rowid, values: values)])
  }

  func print(_ output: UndoSQL, into input: inout Substring) throws {
    guard case let .insert(table, columns, rows) = output else {
      struct NotInsert: Error {}
      throw NotInsert()
    }
    var s = "INSERT INTO \"\(table.name)\"(rowid" as String
    if !columns.isEmpty {
      s += ","
      s += columns.map { "\"\($0.name)\"" as String }.joined(separator: ",")
    }
    s += ") VALUES"
    for (i, row) in rows.enumerated() {
      if i > 0 { s += "," }
      s += "("
      s.append(contentsOf: row.rowid)
      for val in row.values {
        s += ","
        s.append(contentsOf: val.raw)
      }
      s += ")"
    }
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

    return .update(table: table, assignments: assignments, rowids: [rowid])
  }

  func print(_ output: UndoSQL, into input: inout Substring) throws {
    guard case let .update(table, assignments, rowids) = output else {
      struct NotUpdate: Error {}
      throw NotUpdate()
    }
    var s = "UPDATE \"\(table.name)\" SET " as String
    s += assignments.map { "\"\($0.column.name)\"=\($0.value.raw)" as String }.joined(separator: ",")
    if rowids.count == 1 {
      s += " WHERE rowid="
      s.append(contentsOf: rowids[0])
    } else {
      s += " WHERE rowid IN ("
      s += rowids.map(String.init).joined(separator: ",")
      s += ")"
    }
    s.append(contentsOf: input)
    input = Substring(s)
  }
}

// MARK: - SQL Batching

/// Maximum entries per batch to stay within SQLite limits.
private let maxBatchSize = 500

/// When true, disables batching so each entry executes individually.
/// Used for benchmarking to compare batched vs unbatched performance.
nonisolated(unsafe) var _undoBatchingDisabled = false

/// Groups consecutive same-key entries into batched SQL.
/// Key: table for DELETE/INSERT, table+assignments for UPDATE.
func batchedSQL(from entries: [UndoLogEntry]) -> [String] {
  if _undoBatchingDisabled {
    return entries.map(\.sql)
  }

  let parser = UndoSQLParser()
  let items: [(sql: String, parsed: UndoSQL?)] = entries.map { entry in
    var input = Substring(entry.sql)
    let parsed = (try? parser.parse(&input)).flatMap { input.isEmpty ? $0 : nil }
    return (entry.sql, parsed)
  }

  var remaining = items[...]
  var result: [String] = []

  while let first = remaining.popFirst() {
    guard var current = first.parsed else {
      result.append(first.sql)
      continue
    }

    // Merge consecutive same-key entries
    while remaining.first?.parsed != nil {
      guard let merged = merge(current, remaining.first!.parsed!) else { break }
      current = merged
      remaining.removeFirst()
    }

    // Print via the parser-printer
    var output = Substring()
    try! parser.print(current, into: &output)
    result.append(String(output))
  }

  return result
}

/// Merge two UndoSQL values if they share the same grouping key.
private func merge(_ lhs: UndoSQL, _ rhs: UndoSQL) -> UndoSQL? {
  switch (lhs, rhs) {
  case let (.delete(lt, lr), .delete(rt, rr)):
    guard lt == rt, lr.count + rr.count <= maxBatchSize else { return nil }
    return .delete(table: lt, rowids: lr + rr)

  case let (.insert(lt, lc, lrows), .insert(rt, _, rrows)):
    guard lt == rt, lrows.count + rrows.count <= maxBatchSize else { return nil }
    // INSERT batches by table (columns come from the first entry)
    return .insert(table: lt, columns: lc, rows: lrows + rrows)

  case let (.update(lt, la, lr), .update(rt, ra, rr)):
    // UPDATE batches by table + assignments (values must be identical)
    guard lt == rt, la == ra, lr.count + rr.count <= maxBatchSize else { return nil }
    return .update(table: lt, assignments: la, rowids: lr + rr)

  default:
    return nil
  }
}
