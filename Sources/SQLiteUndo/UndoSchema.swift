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

/// Singleton row tracking the current undo/redo state.
///
/// This table always contains exactly one row (id=1) that stores:
/// - The undo and redo stacks as JSON arrays of barrier ranges
/// - Whether undo tracking is currently active
@Table("undoState")
struct UndoState: Sendable {
  /// Always 1 (singleton constraint)
  var id: Int = 1
  /// JSON array of completed barriers available for undo
  @Column(as: [UndoBarrier].JSONRepresentation.self)
  var undoStack: [UndoBarrier] = []
  /// JSON array of undone barriers available for redo
  @Column(as: [UndoBarrier].JSONRepresentation.self)
  var redoStack: [UndoBarrier] = []
  /// Whether undo tracking triggers are active. Set to false during undo/redo execution.
  var isActive: Bool = true
}

extension UndoState {
  /// Fetch the singleton state row.
  static func current(_ db: Database) throws -> UndoState {
    try UndoState.find(1).fetchOne(db)!
  }
}
