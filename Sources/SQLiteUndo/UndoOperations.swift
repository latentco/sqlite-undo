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
      // Reconcile duplicates from BEFORE triggers firing during replay
      try reconcileUndoLogEntries(from: newRange.startSeq, to: newRange.endSeq)
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

    case let .other(sql):
      result.append(sql)
      i += 1
    }
  }

  return result
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
