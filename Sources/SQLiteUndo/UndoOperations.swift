import Foundation
import OSLog
import SQLiteData

private let logger = Logger(subsystem: "SQLiteUndo", category: "UndoHistory")

extension Database {
  /// Execute reverse SQL for a barrier (undo or redo operation).
  ///
  /// Following the sqlite.org/undoredo pattern:
  /// 1. Fetch the current entries for this seq range
  /// 2. Delete those entries
  /// 3. Execute the SQL in reverse order WITH triggers enabled
  /// 4. The triggers capture new reverse SQL (which becomes the redo/undo SQL)
  ///
  /// - Returns: The new seq range for the captured entries, or nil if no entries were executed.
  func performUndoRedo(startSeq: Int, endSeq: Int) throws -> UndoEngine.SeqRange? {
    logger.debug("Performing undo/redo: seq \(startSeq)...\(endSeq)")

    // Fetch entries to execute (in reverse order)
    let entries = try UndoLogEntry
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
      let newRange = UndoEngine.SeqRange(startSeq: seqBefore + 1, endSeq: seqAfter)
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
