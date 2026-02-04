import Foundation
import SQLiteData

/// An entry in the undo log recording SQL to reverse a single change.
///
/// Each INSERT/UPDATE/DELETE trigger records a corresponding reverse operation
/// into this table. The `seq` column provides ordering for proper undo/redo.
@Table("undolog")
struct UndoLogEntry: Sendable {
  /// Auto-incrementing sequence number for ordering.
  var seq: Int
  /// The name of the table that was modified.
  var tableName: String
  /// The SQL statement to reverse the change.
  var sql: String
}

/// Singleton row tracking whether undo tracking is active.
///
/// This table always contains exactly one row (id=1).
/// Stack management is handled by NSUndoManager, not stored in the database.
@Table("undoState")
struct UndoState: Sendable {
  /// Always 1 (singleton constraint)
  var id: Int = 1
  /// Whether undo tracking triggers are active.
  var isActive: Bool = true
}
