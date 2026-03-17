
// MARK: - Tab-delimited parsing

extension UndoSQL {
  /// Parse a tab-delimited undo entry into an UndoSQL value.
  ///
  /// Format: `TYPE\tTABLE\tROWID[\tCOL\tVAL]*`
  /// - `D\t<table>\t<rowid>` → delete
  /// - `I\t<table>\t<rowid>\t<col>\t<val>...` → insert
  /// - `U\t<table>\t<rowid>\t<col>\t<val>...` → update
  init?(tabDelimited sql: String) {
    let parts = sql.split(separator: "\t", omittingEmptySubsequences: false)
    guard parts.count >= 3 else { return nil }

    let table = String(parts[1])
    let rowid = String(parts[2])

    switch parts[0] {
    case "D":
      self = .delete(table: table, rowids: [rowid])

    case "I":
      var columns: [String] = []
      var values: [String] = []
      var i = 3
      while i + 1 < parts.count {
        columns.append(String(parts[i]))
        values.append(String(parts[i + 1]))
        i += 2
      }
      self = .insert(table: table, columns: columns, rows: [(rowid: rowid, values: values)])

    case "U":
      var assignments: [(column: String, value: String)] = []
      var i = 3
      while i + 1 < parts.count {
        assignments.append((column: String(parts[i]), value: String(parts[i + 1])))
        i += 2
      }
      self = .update(table: table, assignments: assignments, rowids: [rowid])

    default:
      return nil
    }
  }

  /// Convert to tab-delimited storage format.
  var tabDelimited: String {
    switch self {
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

  /// Generate executable SQL.
  var executableSQL: String {
    switch self {
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
    return entries.map(\.sql.executableSQL)
  }

  var remaining = entries[...]
  var result: [String] = []

  while let first = remaining.popFirst() {
    var current = first.sql

    // Merge consecutive same-key entries
    while !remaining.isEmpty {
      guard let merged = current.merging(remaining.first!.sql) else { break }
      current = merged
      remaining.removeFirst()
    }

    result.append(current.executableSQL)
  }

  return result
}

extension UndoSQL {
  /// Merge with another UndoSQL if they share the same grouping key.
  func merging(_ other: UndoSQL) -> UndoSQL? {
    switch (self, other) {
    case let (.delete(lt, lr), .delete(rt, rr)):
      guard lt == rt, lr.count + rr.count <= maxBatchSize else { return nil }
      return .delete(table: lt, rowids: lr + rr)

    case let (.insert(lt, lc, lrows), .insert(rt, _, rrows)):
      guard lt == rt, lrows.count + rrows.count <= maxBatchSize else { return nil }
      return .insert(table: lt, columns: lc, rows: lrows + rrows)

    case let (.update(lt, la, lr), .update(rt, ra, rr)):
      guard lt == rt, lr.count + rr.count <= maxBatchSize else { return nil }
      guard la.count == ra.count else { return nil }
      for (l, r) in zip(la, ra) {
        guard l.column == r.column && l.value == r.value else { return nil }
      }
      return .update(table: lt, assignments: la, rowids: lr + rr)

    default:
      return nil
    }
  }
}
