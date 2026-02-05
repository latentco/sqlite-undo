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
///     tables: ProjectItem.self, ProjectEdit.self
///   )
/// }
/// ```
///
/// ## Usage
///
/// ```swift
/// @Dependency(\.defaultUndoEngine) var undoEngine
///
/// // Simple operation
/// let barrierId = try undoEngine.beginBarrier("Set Rating")
/// try database.write { /* make changes */ }
/// try undoEngine.endBarrier(barrierId)
///
/// // With error handling
/// do {
///   let barrierId = try undoEngine.beginBarrier("Set Rating")
///   try database.write { /* make changes */ }
///   try undoEngine.endBarrier(barrierId)
/// } catch {
///   try undoEngine.cancelBarrier(barrierId)
///   throw error
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

  /// Temporarily disable undo tracking for an operation.
  ///
  /// Use for migrations, bulk imports, or other operations that shouldn't
  /// be individually undoable.
  ///
  /// - Parameter operation: The operation to perform without tracking
  public var withUndoDisabled: @Sendable (_ operation: () throws -> Void) throws -> Void = {
    try $0()
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
  ///   - tables: The table types to track for undo (must conform to `UndoTracked`)
  public init(for database: any DatabaseWriter, tables: (any UndoTracked.Type)...) throws {
    try Self.install(for: database, tables: tables)
    self = .make(database: database)
  }

  /// Create an UndoEngine for a database with the specified tracked tables.
  ///
  /// This installs the undo system (tables and triggers) and returns a fully
  /// configured engine ready for use.
  ///
  /// - Parameters:
  ///   - database: The database to track
  ///   - tables: Array of table types to track for undo (must conform to `UndoTracked`)
  public init(for database: any DatabaseWriter, tables: [any UndoTracked.Type]) throws {
    try Self.install(for: database, tables: tables)
    self = .make(database: database)
  }

  private static func install(for database: any DatabaseWriter, tables: [any UndoTracked.Type])
    throws
  {
    try database.installUndoSystem()
    try database.write { db in
      for table in tables {
        for sql in table.generateUndoTriggers() {
          try db.execute(sql: sql)
        }
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

  private static func make(database: any DatabaseWriter) -> UndoEngine {
    let coordinator = UndoCoordinator(database: database)
    return UndoEngine(
      beginBarrier: { name in
        try coordinator.beginBarrier(name)
      },
      endBarrier: { id in
        @Dependency(\.defaultUndoStack) var undoStack
        guard let barrier = try coordinator.endBarrier(id) else {
          return
        }
        MainActor.assumeIsolated {
          undoStack.registerBarrier(
            barrier,
            { try coordinator.performUndo(barrier: barrier) },
            { try coordinator.performRedo(barrier: barrier) }
          )
        }
      },
      cancelBarrier: { id in
        try coordinator.cancelBarrier(id)
      },
      withUndoDisabled: { operation in
        try coordinator.withUndoDisabled(operation)
      }
    )
  }
}
