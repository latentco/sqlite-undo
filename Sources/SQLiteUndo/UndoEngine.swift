import Dependencies
import DependenciesMacros
import Foundation
import OSLog
import SQLiteData

private let logger = Logger(subsystem: "SQLiteUndo", category: "UndoEngine")

/// Dependency for SQLite-based undo/redo operations.
///
/// `UndoEngine` provides the interface for grouping database changes into
/// undoable barriers and executing undo/redo operations.
///
/// ## Setup
///
/// ```swift
/// prepareDependencies {
///   $0.defaultDatabase = try! appDatabase()
///   $0.defaultUndoStack = .live(windowUndoManager)
///   $0.defaultUndoEngine = try! UndoEngine(
///     for: $0.defaultDatabase,
///     tables: Item.self, Edit.self
///   )
/// }
/// ```
///
/// ## Usage
///
/// Wrap database changes in ``undoable(_:operation:)-3cgh0`` to make them undoable:
///
/// ```swift
/// try undoable("Set Rating") {
///   try database.write { db in
///     try Item.find(id).update { $0.rating = rating }.execute(db)
///   }
/// }
/// ```
///
/// Use ``withUndoDisabled(_:)`` for operations that shouldn't be tracked:
///
/// ```swift
/// try withUndoDisabled {
///   try database.write { db in
///     try Item.insert { Item(id: 1, name: "Imported") }.execute(db)
///   }
/// }
/// ```
@DependencyClient
public struct UndoEngine: Sendable {
  /// Begin recording changes for a new undoable action.
  ///
  /// - Parameter name: The action name (shown in Edit > Undo menu)
  /// - Returns: A unique ID for this barrier
  public var beginBarrier: @Sendable (_ name: String) throws -> UUID = { _ in UUID() }

  /// End a barrier and register with UndoManager.
  ///
  /// If no changes were made within the barrier, nothing is registered.
  ///
  /// - Parameter id: The barrier ID from `beginBarrier`
  public var endBarrier: @Sendable (_ id: UUID) throws -> Void

  /// Cancel a barrier without registering it.
  ///
  /// Use this for aborted operations or error handling.
  ///
  /// - Parameter id: The barrier ID from `beginBarrier`
  public var cancelBarrier: @Sendable (_ id: UUID) throws -> Void

  /// Stream of events emitted after each undo/redo operation.
  public var events: @Sendable () -> AsyncStream<UndoEvent> = { .finished }
}

/// Whether undo tracking is active. Default true; set false inside `withUndoDisabled`.
@TaskLocal var _undoIsActive = true

/// Whether the undo system is replaying entries (undo/redo in progress).
@TaskLocal var _undoIsReplaying = false

@DatabaseFunction("sqliteundo_isActive")
func undoIsActiveFunction() -> Bool {
  _undoIsActive
}

@DatabaseFunction("sqliteundo_isReplaying")
func undoIsReplayingFunction() -> Bool {
  _undoIsReplaying
}

extension UndoEngine {
  /// A SQL expression that evaluates to true when the undo system is replaying entries.
  ///
  /// Use `!UndoEngine.isReplaying()` in application trigger WHEN clauses to suppress
  /// cascading writes during undo/redo replay:
  ///
  /// ```swift
  /// Table.createTemporaryTrigger(
  ///   after: .update { $0.isSelected }
  ///   forEachRow: { old, new in ... }
  ///   when: { old, new in
  ///     someCondition.and(!UndoEngine.isReplaying())
  ///   }
  /// )
  /// ```
  public static func isReplaying() -> some QueryExpression<Bool> {
    $undoIsReplayingFunction()
  }
}

extension DependencyValues {
  public var defaultUndoEngine: UndoEngine {
    get { self[UndoEngine.self] }
    set { self[UndoEngine.self] = newValue }
  }
}

extension UndoEngine {
  /// Create an UndoEngine for a database with the specified tracked tables.
  ///
  /// This installs the undo system (tables and triggers) and returns a fully
  /// configured engine ready for use.
  ///
  /// - Parameters:
  ///   - database: The database to track
  ///   - tables: The table types to track for undo (must conform to `Table`)
  ///   - untracked: Tables that may be modified inside barriers but shouldn't be undone
  ///     (e.g., audit logs). Suppresses warnings for these tables.
  public init(
    for database: any DatabaseWriter,
    tables: (any Table.Type)...,
    untracked: [any Table.Type] = []
  ) throws {
    try Self.install(for: database, tables: tables)
    let registeredNames = Set(tables.map { $0.tableName })
    let untrackedNames = Set(untracked.map { $0.tableName })
    self = .make(
      database: database,
      registeredTables: registeredNames,
      untrackedTables: untrackedNames
    )
  }

  /// Create an UndoEngine for a database with the specified tracked tables.
  ///
  /// This installs the undo system (tables and triggers) and returns a fully
  /// configured engine ready for use.
  ///
  /// - Parameters:
  ///   - database: The database to track
  ///   - tables: Array of table types to track for undo (must conform to `Table`)
  ///   - untracked: Tables that may be modified inside barriers but shouldn't be undone
  ///     (e.g., audit logs). Suppresses warnings for these tables.
  public init(
    for database: any DatabaseWriter,
    tables: [any Table.Type],
    untracked: [any Table.Type] = []
  ) throws {
    try Self.install(for: database, tables: tables)
    let registeredNames = Set(tables.map { $0.tableName })
    let untrackedNames = Set(untracked.map { $0.tableName })
    self = .make(
      database: database,
      registeredTables: registeredNames,
      untrackedTables: untrackedNames
    )
  }

  private static func install(for database: any DatabaseWriter, tables: [any Table.Type])
    throws
  {
    try database.installUndoSystem()
    try database.write { db in
      for table in tables {
        try table.installUndoTriggers(db)
      }
    }
  }
}

extension UndoEngine: DependencyKey {
  public static var liveValue: UndoEngine {
    reportIssue(
      """
      UndoEngine requires explicit setup. Configure it in prepareDependencies:

        prepareDependencies {
          $0.defaultDatabase = try! appDatabase()
          $0.defaultUndoStack = .live(windowUndoManager)
          $0.defaultUndoEngine = try! UndoEngine(
            for: $0.defaultDatabase,
            tables: MyTable1.self, MyTable2.self
          )
        }
      """
    )
    return UndoEngine()
  }

  public static var testValue: UndoEngine {
    UndoEngine()
  }

  private static func make(
    database: any DatabaseWriter,
    registeredTables: Set<String> = [],
    untrackedTables: Set<String> = []
  ) -> UndoEngine {
    let coordinator = UndoCoordinator(
      database: database,
      registeredTables: registeredTables,
      untrackedTables: untrackedTables
    )
    return UndoEngine(
      beginBarrier: { name in
        try coordinator.beginBarrier(name)
      },
      endBarrier: { id in
        @Dependency(\.defaultUndoStack) var undoStack
        guard let barrier = try coordinator.endBarrier(id) else {
          return
        }
        undoStack.registerBarrier(
          barrier,
          { try coordinator.performUndo(barrier: barrier) },
          { try coordinator.performRedo(barrier: barrier) }
        )
      },
      cancelBarrier: { id in
        try coordinator.cancelBarrier(id)
      },
      events: {
        coordinator.events
      }
    )
  }
}
