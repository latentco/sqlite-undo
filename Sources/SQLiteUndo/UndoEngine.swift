import Dependencies
import Foundation
import SQLiteData
import OSLog

private let logger = Logger(subsystem: "SQLiteUndo", category: "UndoEngine")

/// Manages SQLite-based undo/redo for a database.
///
/// Uses database triggers to automatically capture reverse SQL for all changes
/// to tracked tables. Changes are grouped into "barriers" that represent
/// single user actions (e.g., "Set Rating", "Apply Look").
///
/// ## Usage
///
/// 1. Call `installUndoSystem()` on your database during setup
/// 2. Mark table types as `UndoTracked` to enable trigger generation
/// 3. Use `beginBarrier`/`endBarrier` to group changes
/// 4. Integrate with `NSUndoManager` via `UndoClient`
public final class UndoEngine: Sendable {
  private let database: any DatabaseWriter
  private let state = LockIsolated(State())

  private struct State {
    var openBarriers: [UUID: OpenBarrier] = [:]
  }

  private struct OpenBarrier {
    let name: String
    let startSeq: Int
  }

  public init(database: (any DatabaseWriter)? = nil) {
    @Dependency(\.defaultDatabase) var defaultDatabase
    self.database = database ?? defaultDatabase
  }

  /// Begin recording changes for a new undoable action.
  ///
  /// All database changes after this call will be captured in the undolog
  /// until `endBarrier` or `cancelBarrier` is called.
  ///
  /// - Parameter name: The action name (shown in Edit > Undo menu)
  /// - Returns: A unique ID for this barrier
  public func beginBarrier(_ name: String) throws -> UUID {
    let id = UUID()
    try database.read { db in
      let currentSeq = try db.undoLogMaxSeq() ?? 0
      let startSeq = currentSeq + 1
      state.withValue {
        $0.openBarriers[id] = OpenBarrier(name: name, startSeq: startSeq)
      }
    }
    logger.debug("Begin barrier: \(name) (id: \(id))")
    return id
  }

  /// End a barrier and capture all changes made since it began.
  ///
  /// If no changes were made within the barrier, returns nil.
  ///
  /// - Parameter id: The barrier ID returned from `beginBarrier`
  /// - Returns: The completed barrier, or nil if no changes were captured
  public func endBarrier(_ id: UUID) throws -> UndoBarrier? {
    guard let openBarrier = state.withValue({ $0.openBarriers.removeValue(forKey: id) }) else {
      logger.warning("Attempted to end unknown barrier: \(id)")
      return nil
    }

    return try database.write { db in
      guard let endSeq = try db.undoLogMaxSeq(), endSeq >= openBarrier.startSeq else {
        logger.debug("End barrier (empty): \(openBarrier.name)")
        return nil
      }

      let barrier = UndoBarrier(
        id: id,
        name: openBarrier.name,
        startSeq: openBarrier.startSeq,
        endSeq: endSeq
      )

      var undoState = try UndoState.current(db)
      undoState.undoStack.append(barrier)
      undoState.redoStack = []
      try UndoState.find(1).update { s in
        s.undoStack = undoState.undoStack
        s.redoStack = undoState.redoStack
      }.execute(db)

      logger.debug("End barrier: \(barrier.name) (\(barrier.count) entries)")
      return barrier
    }
  }

  /// Cancel a barrier without registering it for undo.
  ///
  /// Any changes made within the barrier remain in the database but won't
  /// be undoable as a group. Use this for aborted operations.
  ///
  /// - Parameter id: The barrier ID returned from `beginBarrier`
  public func cancelBarrier(_ id: UUID) throws {
    guard let openBarrier = state.withValue({ $0.openBarriers.removeValue(forKey: id) }) else {
      logger.warning("Attempted to cancel unknown barrier: \(id)")
      return
    }

    try database.write { db in
      if let endSeq = try db.undoLogMaxSeq(), endSeq >= openBarrier.startSeq {
        try db.deleteUndoLogEntries(from: openBarrier.startSeq, to: endSeq)
      }
    }

    logger.debug("Cancel barrier: \(openBarrier.name)")
  }

  /// Perform undo for a barrier.
  ///
  /// Executes all reverse SQL in the barrier in reverse order.
  /// The barrier is moved from the undo stack to the redo stack.
  public func performUndo(barrier: UndoBarrier) throws {
    try database.write { db in
      try db.performUndo(barrier: barrier)

      var state = try UndoState.current(db)
      if let index = state.undoStack.firstIndex(where: { $0.id == barrier.id }) {
        state.undoStack.remove(at: index)
      }
      state.redoStack.append(barrier)
      try UndoState.find(1).update { s in
        s.undoStack = state.undoStack
        s.redoStack = state.redoStack
      }.execute(db)
    }
  }

  /// Perform redo for a barrier.
  ///
  /// Re-applies the original changes that were undone.
  /// The barrier is moved from the redo stack back to the undo stack.
  public func performRedo(barrier: UndoBarrier) throws {
    try database.write { db in
      try db.performRedo(barrier: barrier)

      var state = try UndoState.current(db)
      if let index = state.redoStack.firstIndex(where: { $0.id == barrier.id }) {
        state.redoStack.remove(at: index)
      }
      state.undoStack.append(barrier)
      try UndoState.find(1).update { s in
        s.undoStack = state.undoStack
        s.redoStack = state.redoStack
      }.execute(db)
    }
  }

  /// Temporarily disable undo tracking.
  ///
  /// Use this for bulk operations, migrations, or imports where you don't
  /// want individual changes tracked.
  public func withUndoDisabled<T>(_ operation: () throws -> T) throws -> T {
    try database.write { db in
      try UndoState.find(1).update { $0.isActive = false }.execute(db)
    }
    defer {
      try? database.write { db in
        try UndoState.find(1).update { $0.isActive = true }.execute(db)
      }
    }
    return try operation()
  }

  public var canUndo: Bool {
    get throws {
      try database.read { db in
        let state = try UndoState.current(db)
        return !state.undoStack.isEmpty
      }
    }
  }

  public var canRedo: Bool {
    get throws {
      try database.read { db in
        let state = try UndoState.current(db)
        return !state.redoStack.isEmpty
      }
    }
  }

  public var nextUndoBarrier: UndoBarrier? {
    get throws {
      try database.read { db in
        let state = try UndoState.current(db)
        return state.undoStack.last
      }
    }
  }

  public var nextRedoBarrier: UndoBarrier? {
    get throws {
      try database.read { db in
        let state = try UndoState.current(db)
        return state.redoStack.last
      }
    }
  }
}

// MARK: - Database Installation

extension DatabaseWriter {
  /// Install the undo system tables and initialize state.
  ///
  /// Call this during database setup, after migrations.
  public func installUndoSystem() throws {
    try write { db in
      try db.execute(sql: "DROP TABLE IF EXISTS undolog")
      try db.execute(sql: "DROP TABLE IF EXISTS undoState")

      try db.execute(sql: """
        CREATE TABLE undolog (
          seq INTEGER PRIMARY KEY AUTOINCREMENT,
          tableName TEXT NOT NULL,
          sql TEXT NOT NULL
        )
        """)

      try db.execute(sql: """
        CREATE TABLE undoState (
          id INTEGER PRIMARY KEY CHECK (id = 1),
          undoStack TEXT NOT NULL DEFAULT '[]',
          redoStack TEXT NOT NULL DEFAULT '[]',
          isActive INTEGER NOT NULL DEFAULT 1
        )
        """)

      try db.execute(sql: """
        INSERT INTO undoState (id, undoStack, redoStack, isActive)
        VALUES (1, '[]', '[]', 1)
        """)
    }
  }
}
//
//extension Database {
//  /// Install undo triggers for all tracked tables.
//  ///
//  /// Called from `prepareDatabase` so triggers exist on every connection.
//  public func installUndoTriggers() {
//    for sql in ProjectItem.generateUndoTriggers() {
//      try? execute(sql: sql)
//    }
//    for sql in ProjectEdit.generateUndoTriggers() {
//      try? execute(sql: sql)
//    }
//    for sql in ProjectLook.generateUndoTriggers() {
//      try? execute(sql: sql)
//    }
//    for sql in ProjectGroup.generateUndoTriggers() {
//      try? execute(sql: sql)
//    }
//    for sql in ProjectGroupItem.generateUndoTriggers() {
//      try? execute(sql: sql)
//    }
//    for sql in ProjectExport.generateUndoTriggers() {
//      try? execute(sql: sql)
//    }
//    for sql in ProjectExportItem.generateUndoTriggers() {
//      try? execute(sql: sql)
//    }
//  }
//}
