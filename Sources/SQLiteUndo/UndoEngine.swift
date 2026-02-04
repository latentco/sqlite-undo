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

  /// End a barrier and register with NSUndoManager.
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

  /// Execute undo for a barrier.
  ///
  /// Called by NSUndoManager when the user triggers undo.
  ///
  /// - Parameter barrier: The barrier to undo
  public var performUndo: @Sendable (_ barrier: UndoBarrier) throws -> Void

  /// Execute redo for a barrier.
  ///
  /// Called by NSUndoManager when the user triggers redo.
  ///
  /// - Parameter barrier: The barrier to redo
  public var performRedo: @Sendable (_ barrier: UndoBarrier) throws -> Void

  /// Temporarily disable undo tracking for an operation.
  ///
  /// Use for migrations, bulk imports, or other operations that shouldn't
  /// be individually undoable.
  ///
  /// - Parameter operation: The operation to perform without tracking
  public var withUndoDisabled: @Sendable (_ operation: () throws -> Void) throws -> Void = { try $0() }

  /// Set the UndoManager for this engine.
  ///
  /// Call this from a view's onAppear to connect the window's UndoManager
  /// to the undo system. For multi-window apps, each window should call this
  /// with its own UndoManager.
  ///
  /// - Parameter undoManager: The UndoManager to use, or nil to clear
  public var setUndoManager: @Sendable (_ undoManager: UndoManager?) -> Void = { _ in }
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

  private static func install(for database: any DatabaseWriter, tables: [any UndoTracked.Type]) throws {
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

private final class SendableUndoManager: @unchecked Sendable {
  public var wrappedValue: UndoManager?

  init(_ undoManager: @autoclosure () -> UndoManager?) {
    self.wrappedValue = undoManager()
  }

  func replace(_ undoManager: UndoManager?) {
    self.wrappedValue = undoManager
  }

  @MainActor
  func withUndoManager(_ operation: @MainActor (UndoManager) -> Void) {
    guard let undoManager = wrappedValue else {
      reportIssue(
        """
        Trying to use the UndoManager, but none is available.

        An UndoManager must be provided by the view or by setting the defaultUndoManager.
        """
      )
      return
    }
    operation(undoManager)
  }
}

extension UndoEngine: DependencyKey {
  public static var liveValue: UndoEngine {
    reportIssue(
      """
      UndoEngine requires explicit setup. Configure it in prepareDependencies:

        prepareDependencies {
          $0.defaultDatabase = try! appDatabase()
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
    let undoManager = SendableUndoManager(nil)
    return UndoEngine(
      beginBarrier: { name in
        try coordinator.beginBarrier(name)
      },
      endBarrier: { id in
        guard let barrier = try coordinator.endBarrier(id) else {
          return
        }
        MainActor.assumeIsolated {
          registerUndo(barrier: barrier, coordinator: coordinator, undoManager: undoManager)
        }
      },
      cancelBarrier: { id in
        try coordinator.cancelBarrier(id)
      },
      performUndo: { barrier in
        try coordinator.performUndo(barrier: barrier)
      },
      performRedo: { barrier in
        try coordinator.performRedo(barrier: barrier)
      },
      withUndoDisabled: { operation in
        try coordinator.withUndoDisabled(operation)
      },
      setUndoManager: { manager in
        undoManager.replace(manager)
      }
    )
  }
}

@MainActor
private func registerUndo(
  barrier: UndoBarrier,
  coordinator: UndoCoordinator,
  undoManager: SendableUndoManager
) {
  undoManager.withUndoManager { manager in
    logger.debug("Registering undo: \(barrier.name)")
    // Each barrier gets its own undo group to prevent coalescing
    manager.beginUndoGrouping()
    manager.setActionName(barrier.name)
    manager.registerUndo(withTarget: coordinator) { coordinator in
      MainActor.assumeIsolated {
        logger.debug("Performing undo: \(barrier.name)")
        do {
          try coordinator.performUndo(barrier: barrier)
          registerRedo(barrier: barrier, coordinator: coordinator, undoManager: undoManager)
        } catch {
          logger.error("Undo failed: \(error)")
        }
      }
    }
    manager.endUndoGrouping()
  }
}

@MainActor
private func registerRedo(
  barrier: UndoBarrier,
  coordinator: UndoCoordinator,
  undoManager: SendableUndoManager
) {
  undoManager.withUndoManager { manager in
    logger.debug("Registering redo: \(barrier.name)")
    manager.registerUndo(withTarget: coordinator) { coordinator in
      MainActor.assumeIsolated {
        logger.debug("Performing redo: \(barrier.name)")
        do {
          try coordinator.performRedo(barrier: barrier)
          registerUndo(barrier: barrier, coordinator: coordinator, undoManager: undoManager)
        } catch {
          logger.error("Redo failed: \(error)")
        }
      }
    }
  }
}
