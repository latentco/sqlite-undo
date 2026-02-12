import Foundation
import SQLiteData

/// Identifies a row that was modified during an undo/redo operation.
public struct AffectedItem: Sendable, Hashable {
  public let tableName: String
  public let rowid: Int

  init(tableName: String, rowid: Int) {
    self.tableName = tableName
    self.rowid = rowid
  }

  public init<T: Table>(table: T.Type, rowid: Int) {
    self.tableName = T.tableName
    self.rowid = rowid
  }

  /// Extract a typed ID if this item belongs to the given table.
  public func id<T: Table & Identifiable>(
    as type: T.Type
  ) -> T.ID? where T.ID: BinaryInteger {
    tableName == T.tableName ? T.ID(rowid) : nil
  }
}

/// Emitted after each undo/redo operation with information about what changed.
public struct UndoEvent: Sendable, Equatable {
  public enum Kind: Sendable, Equatable { case undo, redo }
  public let kind: Kind
  public let name: String
  public let affectedItems: Set<AffectedItem>

  public init(kind: Kind, name: String, affectedItems: Set<AffectedItem>) {
    self.kind = kind
    self.name = name
    self.affectedItems = affectedItems
  }
}
