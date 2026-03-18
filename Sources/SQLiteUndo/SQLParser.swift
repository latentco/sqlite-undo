// MARK: - Tab-delimited parsing

extension UndoSQL {
  /// Parse a tab-delimited undo entry.
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
      self = .delete(DeleteSQL(table: table, rowids: [rowid]))

    case "I":
      var columns: [String] = []
      var values: [String] = []
      var i = 3
      while i + 1 < parts.count {
        columns.append(String(parts[i]))
        values.append(String(parts[i + 1]))
        i += 2
      }
      self = .insert(
        InsertSQL(
          table: table, columns: columns,
          rows: [InsertSQL.Row(rowid: rowid, values: values)]))

    case "U":
      var assignments: [UpdateSQL.Assignment] = []
      var i = 3
      while i + 1 < parts.count {
        assignments.append(
          UpdateSQL.Assignment(
            column: String(parts[i]), value: String(parts[i + 1])))
        i += 2
      }
      self = .update(UpdateSQL(table: table, assignments: assignments, rowids: [rowid]))

    default:
      return nil
    }
  }

  /// Convert to tab-delimited storage format.
  var tabDelimited: String {
    switch self {
    case let .delete(d):
      return "D\t" + d.table + "\t" + d.rowids[0]
    case let .insert(ins):
      let row = ins.rows[0]
      var sql = "I\t" + ins.table + "\t" + row.rowid
      for (col, val) in zip(ins.columns, row.values) {
        sql += "\t" + col + "\t" + val
      }
      return sql
    case let .update(upd):
      var sql = "U\t" + upd.table + "\t" + upd.rowids[0]
      for a in upd.assignments {
        sql += "\t" + a.column + "\t" + a.value
      }
      return sql
    }
  }

  /// Generate executable SQL.
  var executableSQL: String {
    switch self {
    case let .delete(d):
      if d.rowids.count == 1 {
        return "DELETE FROM \"\(d.table)\" WHERE rowid=\(d.rowids[0])"
      }
      return "DELETE FROM \"\(d.table)\" WHERE rowid IN (\(d.rowids.joined(separator: ",")))"

    case let .insert(ins):
      var sql = "INSERT INTO \""
      sql += ins.table
      sql += "\"("
      if ins.columns.isEmpty {
        sql += "rowid"
      } else {
        sql += "rowid,"
        sql += ins.columns.map { "\"" + $0 + "\"" }.joined(separator: ",")
      }
      sql += ") VALUES"
      for (i, row) in ins.rows.enumerated() {
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

    case let .update(upd):
      let set = upd.assignments.map { "\"\($0.column)\"=\($0.value)" }.joined(separator: ",")
      if upd.rowids.count == 1 {
        return "UPDATE \"\(upd.table)\" SET \(set) WHERE rowid=\(upd.rowids[0])"
      }
      return
        "UPDATE \"\(upd.table)\" SET \(set) WHERE rowid IN (\(upd.rowids.joined(separator: ",")))"
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
    case let (.delete(l), .delete(r)):
      guard l.table == r.table, l.rowids.count + r.rowids.count <= maxBatchSize else { return nil }
      return .delete(DeleteSQL(table: l.table, rowids: l.rowids + r.rowids))

    case let (.insert(l), .insert(r)):
      guard l.table == r.table, l.rows.count + r.rows.count <= maxBatchSize else { return nil }
      return .insert(InsertSQL(table: l.table, columns: l.columns, rows: l.rows + r.rows))

    case let (.update(l), .update(r)):
      guard l.table == r.table, l.rowids.count + r.rowids.count <= maxBatchSize else { return nil }
      guard l.assignments == r.assignments else { return nil }
      return .update(
        UpdateSQL(
          table: l.table, assignments: l.assignments, rowids: l.rowids + r.rowids))

    default:
      return nil
    }
  }
}
