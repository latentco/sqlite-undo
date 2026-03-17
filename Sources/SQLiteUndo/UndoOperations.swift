import Foundation
import OSLog
import SQLiteData

private let logger = Logger(subsystem: "SQLiteUndo", category: "UndoHistory")

extension Database {
  /// Execute reverse SQL for a barrier (undo or redo operation).
  ///
  /// ## How Undo/Redo Works (sqlite.org/undoredo pattern)
  ///
  /// The key insight is that undo and redo are **symmetric operations**. Both:
  /// 1. Fetch SQL entries in the given seq range
  /// 2. Delete those entries
  /// 3. Execute the SQL in reverse order with triggers ENABLED
  /// 4. Triggers capture new reverse SQL at NEW sequence positions
  ///
  /// For example, if you INSERT a row:
  /// - Trigger captures: `DELETE FROM table WHERE rowid=X` at seq 1
  ///
  /// When you UNDO:
  /// - Execute the DELETE (row is removed)
  /// - Trigger captures: `INSERT INTO table(...) VALUES(...)` at seq 2
  /// - This INSERT is the REDO SQL
  ///
  /// When you REDO:
  /// - Execute the INSERT (row is restored)
  /// - Trigger captures: `DELETE FROM table WHERE rowid=X` at seq 3
  /// - This DELETE is the UNDO SQL again
  ///
  /// ## Sequence Numbers Grow, Not Reused
  ///
  /// The sqlite.org pattern does NOT try to reuse sequence numbers. After each
  /// undo/redo, entries move to new (higher) seq positions. This avoids conflicts
  /// when multiple barriers exist - each barrier's entries can move independently
  /// without colliding with other barriers' seq ranges.
  ///
  /// The caller (UndoEngine) tracks the current seq range for each barrier and
  /// updates it after this method returns.
  ///
  struct UndoRedoResult {
    var seqRange: UndoCoordinator.SeqRange
    var affectedItems: Set<AffectedItem>
  }

  /// - Returns: The new seq range and affected items, or nil if no entries were executed.
  func performUndoRedo(startSeq: Int, endSeq: Int) throws -> UndoRedoResult? {
    logger.debug("Performing undo/redo: seq \(startSeq)...\(endSeq)")

    // Fetch entries to execute (in reverse order)
    let entries =
      try UndoLogEntry
      .where { $0.seq >= startSeq && $0.seq <= endSeq }
      .order { $0.seq.desc() }
      .fetchAll(self)

    guard !entries.isEmpty else {
      logger.debug("No entries found for seq range \(startSeq)...\(endSeq)")
      return nil
    }

    // Collect affected items before deleting entries
    let affectedItems = Set(
      entries
        .filter { $0.trackedRowid != 0 }
        .map { AffectedItem(tableName: $0.tableName, rowid: $0.trackedRowid) }
    )

    // Delete the entries
    try deleteUndoLogEntries(from: startSeq, to: endSeq)

    // Get current max seq before executing (new entries will be added after this)
    let seqBefore = try undoLogMaxSeq() ?? 0

    // Execute with triggers ENABLED - this captures the reverse SQL.
    // Set isReplaying so app-level triggers suppress cascading writes.
    // The undo log already contains all effects (including cascades),
    // so replaying them individually is sufficient.
    // Batch consecutive same-table, same-type entries for efficiency.
    try $_undoIsReplaying.withValue(true) {
      for sql in batchedSQL(from: entries) {
        logger.trace("Executing SQL: \(sql)")
        try #sql("\(raw: sql)").execute(self)
      }
    }

    // Get new seq range for captured entries
    let seqAfter = try undoLogMaxSeq() ?? seqBefore
    if seqAfter > seqBefore {
      let newRange = UndoCoordinator.SeqRange(startSeq: seqBefore + 1, endSeq: seqAfter)
      // No reconciliation needed during replay: _undoIsReplaying suppresses
      // app-level cascade triggers, so each row produces exactly one reverse entry.
      logger.debug("New seq range: \(newRange.startSeq)...\(newRange.endSeq)")
      return UndoRedoResult(seqRange: newRange, affectedItems: affectedItems)
    }

    return nil
  }
}

// MARK: - SQL Batching

/// Classifies trigger-generated SQL for batching.
private enum UndoSQL {
  case delete(table: Substring, rowid: Substring)
  case insert(table: Substring, header: Substring, values: Substring)
  case update(table: Substring, setClause: Substring, rowid: Substring)
  case other(sql: String)
}

private func classifySQL(_ sql: String) -> UndoSQL {
  if sql.hasPrefix("DELETE FROM") {
    // Format: DELETE FROM "table" WHERE rowid=N
    let prefix = sql.index(sql.startIndex, offsetBy: 12) // past "DELETE FROM "
    if let whereRange = sql.range(of: " WHERE rowid=") {
      let table = sql[prefix..<whereRange.lowerBound]
      let rowid = sql[whereRange.upperBound...]
      return .delete(table: table, rowid: rowid)
    }
  } else if sql.hasPrefix("INSERT INTO") {
    // Format: INSERT INTO "table"(rowid,...) VALUES(...)
    if let valuesRange = sql.range(of: ") VALUES(") {
      // header includes the column list up to and including the closing paren
      let header = sql[sql.startIndex...valuesRange.lowerBound]
      let valuesStart = valuesRange.upperBound
      let valuesEnd = sql.index(before: sql.endIndex)
      let values = sql[valuesStart..<valuesEnd]
      return .insert(table: extractTableName(from: sql), header: header, values: values)
    }
  } else if sql.hasPrefix("UPDATE ") {
    // Format: UPDATE "table" SET "col1"=val1,"col2"=val2 WHERE rowid=N
    if let setRange = sql.range(of: " SET "),
      let whereRange = sql.range(of: " WHERE rowid=")
    {
      let table = extractTableName(from: sql)
      let setClause = sql[setRange.upperBound..<whereRange.lowerBound]
      let rowid = sql[whereRange.upperBound...]
      return .update(table: table, setClause: setClause, rowid: rowid)
    }
  }
  return .other(sql: sql)
}

/// Extracts the quoted table name from trigger-generated SQL.
/// e.g. from `INSERT INTO "myTable"(...)` extracts `"myTable"`.
private func extractTableName(from sql: String) -> Substring {
  // Find first quote after the command prefix
  guard let firstQuote = sql.firstIndex(of: "\"") else { return sql[...] }
  let afterFirst = sql.index(after: firstQuote)
  guard let secondQuote = sql[afterFirst...].firstIndex(of: "\"") else { return sql[...] }
  return sql[firstQuote...secondQuote]
}

/// Maximum entries per batch to stay within SQLite limits.
private let maxBatchSize = 500

/// When true, disables batching so each entry executes individually.
/// Used for benchmarking to compare batched vs unbatched performance.
nonisolated(unsafe) var _undoBatchingDisabled = false

/// Groups consecutive same-table, same-type entries into batched SQL.
private func batchedSQL(from entries: [UndoLogEntry]) -> [String] {
  if _undoBatchingDisabled {
    return entries.map(\.sql)
  }
  var result: [String] = []
  var i = 0

  while i < entries.count {
    let classified = classifySQL(entries[i].sql)

    switch classified {
    case let .delete(table, rowid):
      // Collect consecutive deletes for the same table
      var rowids = [rowid]
      var j = i + 1
      while j < entries.count, rowids.count < maxBatchSize {
        if case let .delete(nextTable, nextRowid) = classifySQL(entries[j].sql), nextTable == table {
          rowids.append(nextRowid)
          j += 1
        } else {
          break
        }
      }
      let rowidList = rowids.joined(separator: ",")
      result.append("DELETE FROM \(table) WHERE rowid IN (\(rowidList))")
      i = j

    case let .insert(table, header, values):
      // Collect consecutive inserts for the same table
      var tuples = [values]
      var j = i + 1
      while j < entries.count, tuples.count < maxBatchSize {
        if case let .insert(nextTable, _, nextValues) = classifySQL(entries[j].sql), nextTable == table
        {
          tuples.append(nextValues)
          j += 1
        } else {
          break
        }
      }
      let valuesList = tuples.map { "(\($0))" }.joined(separator: ",")
      result.append("\(header) VALUES\(valuesList)")
      i = j

    case let .update(table, setClause, rowid):
      // Collect consecutive updates for the same table
      var updates = [(setClause: Substring, rowid: Substring)]()
      updates.append((setClause, rowid))
      var j = i + 1
      while j < entries.count, updates.count < maxBatchSize {
        if case let .update(nextTable, nextSet, nextRowid) = classifySQL(entries[j].sql),
          nextTable == table
        {
          updates.append((nextSet, nextRowid))
          j += 1
        } else {
          break
        }
      }

      if updates.count == 1 {
        result.append(entries[i].sql)
      } else {
        // Parse column names from the first entry
        let firstParsed = parseUpdateSetClause(updates[0].setClause)
        let columns = firstParsed.map(\.column)

        // SET "col1"=_v."col1","col2"=_v."col2"
        let setExprs: String = columns.map { ("\"\($0)\"=_v.\"\($0)\"" as String) }.joined(separator: ",")

        // VALUES (rowid1,v1,v2),(rowid2,v3,v4)
        let valueRows: String = updates.map { (entry) -> String in
          let values: [String] = parseUpdateSetClause(entry.setClause).map { String($0.value) }
          return "(\(entry.rowid),\(values.joined(separator: ",")))"
        }.joined(separator: ",")

        // AS _v(_r,"col1","col2")
        let aliases: String = (["_r"] + columns.map { "\"\($0)\"" as String }).joined(separator: ",")

        result.append(
          "WITH _v(\(aliases)) AS (VALUES \(valueRows)) UPDATE \(table) SET \(setExprs) FROM _v WHERE \(table).rowid=_v._r"
        )
      }
      i = j

    case let .other(sql):
      result.append(sql)
      i += 1
    }
  }

  return result
}

// MARK: - UPDATE SET Clause Parsing

private struct ColumnValue {
  var column: Substring
  var value: Substring
}

/// Parse a trigger-generated SET clause into column-value pairs.
/// Input format: `"col1"=val1,"col2"=val2,...` where values are `quote()` output.
private func parseUpdateSetClause(_ setClause: Substring) -> [ColumnValue] {
  var result: [ColumnValue] = []
  var i = setClause.startIndex

  while i < setClause.endIndex {
    // Skip comma between assignments
    if setClause[i] == "," {
      i = setClause.index(after: i)
    }

    // Parse "column"
    guard i < setClause.endIndex, setClause[i] == "\"" else { break }
    let colStart = setClause.index(after: i)
    guard let colEnd = setClause[colStart...].firstIndex(of: "\"") else { break }
    let column = setClause[colStart..<colEnd]

    // Skip past "=
    i = setClause.index(colEnd, offsetBy: 2)

    // Parse value (quote() output)
    let valueStart = i
    i = endOfQuotedValue(in: setClause, from: i)
    result.append(ColumnValue(column: column, value: setClause[valueStart..<i]))
  }

  return result
}

/// Advance past a `quote()`-produced SQL literal.
/// Handles: 'text' (with '' escapes), X'blob', NULL, and numbers.
private func endOfQuotedValue(in s: Substring, from start: String.Index) -> String.Index {
  var i = start
  guard i < s.endIndex else { return i }

  switch s[i] {
  case "'":
    // String: 'text with ''escapes'''
    i = s.index(after: i)
    while i < s.endIndex {
      if s[i] == "'" {
        let next = s.index(after: i)
        if next < s.endIndex, s[next] == "'" {
          i = s.index(after: next)
        } else {
          return next
        }
      } else {
        i = s.index(after: i)
      }
    }
    return i

  case "X" where s.index(after: i) < s.endIndex && s[s.index(after: i)] == "'":
    // Blob: X'hex'
    i = s.index(i, offsetBy: 2)
    if let end = s[i...].firstIndex(of: "'") {
      return s.index(after: end)
    }
    return s.endIndex

  case "N" where s[i...].hasPrefix("NULL"):
    return s.index(i, offsetBy: 4)

  default:
    // Number: scan to comma or end
    while i < s.endIndex, s[i] != "," {
      i = s.index(after: i)
    }
    return i
  }
}

extension Database {
  /// Get the current maximum sequence number in the undolog.
  func undoLogMaxSeq() throws -> Int? {
    try #sql("SELECT MAX(seq) FROM undolog", as: Int?.self).fetchOne(self) ?? nil
  }

  /// Delete undolog entries in a sequence range.
  func deleteUndoLogEntries(from startSeq: Int, to endSeq: Int) throws {
    try UndoLogEntry
      .where { $0.seq >= startSeq && $0.seq <= endSeq }
      .delete()
      .execute(self)
  }

  /// Get the set of table names modified in a sequence range.
  func tablesModifiedInRange(from startSeq: Int, to endSeq: Int) throws -> Set<String> {
    let tableNames =
      try UndoLogEntry
      .where { $0.seq >= startSeq && $0.seq <= endSeq }
      .select { $0.tableName }
      .fetchAll(self)
    return Set(tableNames)
  }

  /// Reconcile undolog entries in a seq range to remove duplicates.
  ///
  /// BEFORE triggers and replay can produce multiple entries for the same row within
  /// a single barrier. This keeps only the first entry (lowest seq = true original)
  /// per (tableName, trackedRowid) group, with special handling:
  /// - INSERT (DELETE-reverse) + DELETE (INSERT-reverse) of same row → remove both (no-op)
  /// - INSERT (DELETE-reverse) + UPDATE → keep just the DELETE-reverse (undo = delete)
  /// - Multiple UPDATEs → keep first (true original values)
  func reconcileUndoLogEntries(from startSeq: Int, to endSeq: Int) throws {
    // Fast path: check if any duplicates exist before fetching all entries
    let hasDuplicates = try #sql(
      """
      SELECT 1 FROM undolog
      WHERE seq >= \(startSeq) AND seq <= \(endSeq) AND trackedRowid != 0
      GROUP BY tableName, trackedRowid
      HAVING COUNT(*) > 1
      LIMIT 1
      """,
      as: Int.self
    ).fetchOne(self)

    guard hasDuplicates != nil else { return }

    let entries =
      try UndoLogEntry
      .where { $0.seq >= startSeq && $0.seq <= endSeq }
      .order { $0.seq.asc() }
      .fetchAll(self)

    var groups: [String: [UndoLogEntry]] = [:]
    for entry in entries {
      guard entry.trackedRowid != 0 else { continue }
      let key = "\(entry.tableName):\(entry.trackedRowid)"
      groups[key, default: []].append(entry)
    }

    var seqsToDelete: [Int] = []

    for (_, group) in groups {
      guard group.count > 1 else { continue }

      let first = group[0]
      let last = group[group.count - 1]

      let firstIsDeleteReverse = first.sql.hasPrefix("DELETE FROM")
      let lastIsInsertReverse = last.sql.hasPrefix("INSERT INTO")

      if firstIsDeleteReverse && lastIsInsertReverse {
        // INSERT then DELETE in same barrier → no-op, remove all
        for entry in group {
          seqsToDelete.append(entry.seq)
        }
      } else if firstIsDeleteReverse {
        // INSERT then UPDATEs → keep DELETE-reverse (undo = delete), remove rest
        for entry in group.dropFirst() {
          seqsToDelete.append(entry.seq)
        }
      } else {
        // First is UPDATE-reverse or INSERT-reverse (pre-existing row).
        // Remove only subsequent UPDATE-reverses (cascade duplicates).
        // Keep INSERT-reverses (from DELETE) since replay needs them for row re-creation.
        for entry in group.dropFirst() {
          if entry.sql.hasPrefix("UPDATE") {
            seqsToDelete.append(entry.seq)
          }
        }
      }
    }

    if !seqsToDelete.isEmpty {
      let placeholders = seqsToDelete.map { "\($0)" }.joined(separator: ",")
      try #sql("DELETE FROM undolog WHERE seq IN (\(raw: placeholders))").execute(self)
      logger.debug("Reconciled: removed \(seqsToDelete.count) duplicate undolog entries")
    }
  }
}
