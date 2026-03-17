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
  /// The rowid of the tracked row, for deduplication during reconciliation.
  var trackedRowid: Int = 0
  /// The parsed undo entry to reverse the change.
  var sql: UndoSQL
}

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

extension UndoSQL: _OptionalPromotable {}

extension UndoSQL: QueryDecodable {
  init(decoder: inout some QueryDecoder) throws {
    guard let text = try decoder.decode(String.self),
      let parsed = UndoSQL(tabDelimited: text)
    else { throw QueryDecodingError.missingRequiredColumn }
    self = parsed
  }
}

extension UndoSQL: QueryRepresentable {}

extension UndoSQL: QueryExpression {
  typealias QueryValue = Self
}

extension UndoSQL: QueryBindable {
  var queryBinding: QueryBinding { .text(self.tabDelimited) }
}

extension DatabaseWriter {
  func installUndoSystem() throws {
    try write { db in
      try #sql("DROP TABLE IF EXISTS undolog").execute(db)
      try #sql("DROP TABLE IF EXISTS undoState").execute(db)

      try #sql(
        """
        CREATE TABLE undolog (
          seq INTEGER PRIMARY KEY AUTOINCREMENT,
          tableName TEXT NOT NULL,
          trackedRowid INTEGER NOT NULL DEFAULT 0,
          sql TEXT NOT NULL
        )
        """
      ).execute(db)

      db.add(function: $undoIsActiveFunction)
      db.add(function: $undoIsReplayingFunction)
    }
  }
}
