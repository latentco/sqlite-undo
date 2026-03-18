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
      try #sql("PRAGMA defer_foreign_keys = ON").execute(self)
      for sql in batchedSQL(from: entries) {
        logger.trace("Executing SQL: \(sql)")
        try #sql("\(raw: sql)").execute(self)
      }
#if DEBUG
      // Check for FK violations that will cause the commit to fail.
      let violations = try #sql(
        """
        SELECT "table" || ' rowid=' || rowid || ' parent=' || "parent" || ' fkid=' || fkid
        FROM pragma_foreign_key_check
        """,
        as: String.self
      ).fetchAll(self)
      if !violations.isEmpty {
        logger.error(
          """
          Undo replay will fail due to foreign key violations

          Ensure all tables involved in foreign key relationships are undo-tracked, 
          and that undo-tracked tables do not have foreign keys to non-tracked tables.
          """
        )
        for v in violations {
          logger.error("  FK violation after undo replay: \(v)")
        }
      }
#endif
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
    var seqsToUpdate: [(seq: Int, sql: UndoSQL)] = []

    for (_, group) in groups {
      guard group.count > 1 else { continue }

      let first = group[0]
      let last = group[group.count - 1]

      if case .delete = first.sql, case .insert = last.sql {
        // INSERT then DELETE in same barrier → no-op, remove all
        for entry in group {
          seqsToDelete.append(entry.seq)
        }
      } else if case .delete = first.sql {
        // INSERT then UPDATEs → keep DELETE-reverse (undo = delete), remove rest
        for entry in group.dropFirst() {
          seqsToDelete.append(entry.seq)
        }
      } else {
        // First is UPDATE-reverse or INSERT-reverse (pre-existing row).
        // Keep INSERT-reverses (from DELETE) since replay needs them for row re-creation.
        // Merge subsequent UPDATE-reverses into the first UPDATE-reverse,
        // adding any columns not already present (first entry's values win).
        var mergedAssignments: [UndoSQL.UpdateSQL.Assignment]?
        var existingColumns: Set<String>?
        if case let .update(upd) = first.sql {
          mergedAssignments = upd.assignments
          existingColumns = Set(upd.assignments.map(\.column))
        }

        for entry in group.dropFirst() {
          if case let .update(upd) = entry.sql {
            if var assignments = mergedAssignments, var columns = existingColumns {
              let additions = upd.assignments.filter { !columns.contains($0.column) }
              if !additions.isEmpty {
                for a in additions { columns.insert(a.column) }
                assignments += additions
                mergedAssignments = assignments
                existingColumns = columns
              }
            }
            seqsToDelete.append(entry.seq)
          }
        }

        if case let .update(upd) = first.sql,
          let assignments = mergedAssignments, assignments.count > upd.assignments.count
        {
          seqsToUpdate.append(
            (
              seq: first.seq,
              sql: .update(
                UndoSQL.UpdateSQL(
                  table: upd.table, assignments: assignments, rowids: upd.rowids))
            ))
        }
      }
    }

    for entry in seqsToUpdate {
      let text = entry.sql.tabDelimited
      try self.execute(
        sql: "UPDATE undolog SET sql = ? WHERE seq = ?", arguments: [text, entry.seq])
    }

    if !seqsToDelete.isEmpty {
      let placeholders = seqsToDelete.map { "\($0)" }.joined(separator: ",")
      try #sql("DELETE FROM undolog WHERE seq IN (\(raw: placeholders))").execute(self)
      logger.debug("Reconciled: removed \(seqsToDelete.count) duplicate undolog entries")
    }
  }
}
