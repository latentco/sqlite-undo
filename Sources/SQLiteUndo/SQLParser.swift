/// Parsed representation of trigger-generated undo entries.
/// Parsers produce single-element arrays; batching merges consecutive same-key entries.
enum UndoSQL: Equatable, Sendable {
  case delete(table: String, rowids: [String])
  case insert(table: String, columns: [String], rows: [(rowid: String, values: [String])])
  case update(table: String, assignments: [(column: String, value: String)], rowids: [String])

  static func == (lhs: UndoSQL, rhs: UndoSQL) -> Bool {
    switch (lhs, rhs) {
    case let (.delete(lt, lr), .delete(rt, rr)):
      return lt == rt && lr == rr
    case let (.insert(lt, lc, lrows), .insert(rt, rc, rrows)):
      guard lt == rt && lc == rc && lrows.count == rrows.count else { return false }
      for (l, r) in zip(lrows, rrows) {
        guard l.rowid == r.rowid && l.values == r.values else { return false }
      }
      return true
    case let (.update(lt, la, lr), .update(rt, ra, rr)):
      guard lt == rt && la.count == ra.count && lr == rr else { return false }
      for (l, r) in zip(la, ra) {
        guard l.column == r.column && l.value == r.value else { return false }
      }
      return true
    default:
      return false
    }
  }
}

// MARK: - Tab-delimited parsing

/// Parse a tab-delimited undo entry into an UndoSQL value.
///
/// Format: `TYPE\tTABLE\tROWID[\tCOL\tVAL]*`
/// - `D\t<table>\t<rowid>` → delete
/// - `I\t<table>\t<rowid>\t<col>\t<val>...` → insert
/// - `U\t<table>\t<rowid>\t<col>\t<val>...` → update
func parseUndoEntry(_ sql: String) -> UndoSQL? {
  let parts = sql.split(separator: "\t", omittingEmptySubsequences: false)
  guard parts.count >= 3 else { return nil }

  let table = String(parts[1])
  let rowid = String(parts[2])

  switch parts[0] {
  case "D":
    return .delete(table: table, rowids: [rowid])

  case "I":
    var columns: [String] = []
    var values: [String] = []
    var i = 3
    while i + 1 < parts.count {
      columns.append(String(parts[i]))
      values.append(String(parts[i + 1]))
      i += 2
    }
    return .insert(table: table, columns: columns, rows: [(rowid: rowid, values: values)])

  case "U":
    var assignments: [(column: String, value: String)] = []
    var i = 3
    while i + 1 < parts.count {
      assignments.append((column: String(parts[i]), value: String(parts[i + 1])))
      i += 2
    }
    return .update(table: table, assignments: assignments, rowids: [rowid])

  default:
    return nil
  }
}

/// Convert an UndoSQL value back to tab-delimited storage format.
func formatUndoEntry(_ entry: UndoSQL) -> String {
  switch entry {
  case let .delete(table, rowids):
    return "D\t" + table + "\t" + rowids[0]
  case let .insert(table, columns, rows):
    let row = rows[0]
    var sql = "I\t" + table + "\t" + row.rowid
    for (col, val) in zip(columns, row.values) {
      sql += "\t" + col + "\t" + val
    }
    return sql
  case let .update(table, assignments, rowids):
    var sql = "U\t" + table + "\t" + rowids[0]
    for a in assignments {
      sql += "\t" + a.column + "\t" + a.value
    }
    return sql
  }
}

// MARK: - SQL generation

/// Generate executable SQL from a parsed UndoSQL value.
func generateSQL(_ entry: UndoSQL) -> String {
  switch entry {
  case let .delete(table, rowids):
    if rowids.count == 1 {
      return "DELETE FROM \"\(table)\" WHERE rowid=\(rowids[0])"
    }
    return "DELETE FROM \"\(table)\" WHERE rowid IN (\(rowids.joined(separator: ",")))"

  case let .insert(table, columns, rows):
    var sql = "INSERT INTO \""
    sql += table
    sql += "\"("
    if columns.isEmpty {
      sql += "rowid"
    } else {
      sql += "rowid,"
      sql += columns.map { "\"" + $0 + "\"" }.joined(separator: ",")
    }
    sql += ") VALUES"
    for (i, row) in rows.enumerated() {
      if i > 0 { sql += "," }
      sql += "("
      sql += row.rowid
      for val in row.values {
        sql += ","
        sql += val
      }
      sql += ")"
    }
    return sql

  case let .update(table, assignments, rowids):
    let set = assignments.map { "\"\($0.column)\"=\($0.value)" }.joined(separator: ",")
    if rowids.count == 1 {
      return "UPDATE \"\(table)\" SET \(set) WHERE rowid=\(rowids[0])"
    }
    return "UPDATE \"\(table)\" SET \(set) WHERE rowid IN (\(rowids.joined(separator: ",")))"
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
    return entries.map { generateSQL(parseUndoEntry($0.sql)!) }
  }

  let items: [(sql: String, parsed: UndoSQL?)] = entries.map { entry in
    (entry.sql, parseUndoEntry(entry.sql))
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

    result.append(generateSQL(current))
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
    return .insert(table: lt, columns: lc, rows: lrows + rrows)

  case let (.update(lt, la, lr), .update(rt, ra, rr)):
    guard lt == rt, lr.count + rr.count <= maxBatchSize else { return nil }
    // UPDATE batches by table + identical assignments
    guard la.count == ra.count else { return nil }
    for (l, r) in zip(la, ra) {
      guard l.column == r.column && l.value == r.value else { return nil }
    }
    return .update(table: lt, assignments: la, rowids: lr + rr)

  default:
    return nil
  }
}
