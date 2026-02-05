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
  /// - Returns: The new seq range for the captured entries, or nil if no entries were executed.
  func performUndoRedo(startSeq: Int, endSeq: Int) throws -> UndoCoordinator.SeqRange? {
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

    // Delete the entries
    try deleteUndoLogEntries(from: startSeq, to: endSeq)

    // Get current max seq before executing (new entries will be added after this)
    let seqBefore = try undoLogMaxSeq() ?? 0

    // Execute with triggers ENABLED - this captures the reverse SQL
    for entry in entries {
      logger.trace("Executing SQL: \(entry.sql)")
      try execute(sql: entry.sql)
    }

    // Get new seq range for captured entries
    let seqAfter = try undoLogMaxSeq() ?? seqBefore
    if seqAfter > seqBefore {
      let newRange = UndoCoordinator.SeqRange(startSeq: seqBefore + 1, endSeq: seqAfter)
      logger.debug("New seq range: \(newRange.startSeq)...\(newRange.endSeq)")
      return newRange
    }

    return nil
  }
}

extension Database {
  /// Get the current maximum sequence number in the undolog.
  func undoLogMaxSeq() throws -> Int? {
    try Int.fetchOne(self, sql: "SELECT MAX(seq) FROM undolog")
  }

  /// Delete undolog entries in a sequence range.
  func deleteUndoLogEntries(from startSeq: Int, to endSeq: Int) throws {
    try UndoLogEntry
      .where { $0.seq >= startSeq && $0.seq <= endSeq }
      .delete()
      .execute(self)
  }
}
