import Dependencies
import DependenciesMacros
import Foundation
import OSLog
import SQLiteData

private let logger = Logger(subsystem: "SQLiteUndo", category: "UndoClient")

/// Dependency client for SQLite-based undo/redo operations.
///
/// `UndoClient` provides the interface for grouping database changes into
/// undoable barriers and executing undo/redo operations.
///
/// ## Usage
///
/// ```swift
/// @Dependency(\.undoClient) var undoClient
///
/// // Simple operation
/// let barrierId = try undoClient.beginBarrier("Set Rating")
/// try database.write { /* make changes */ }
/// try undoClient.endBarrier(barrierId)
///
/// // With error handling
/// do {
///   let barrierId = try undoClient.beginBarrier("Set Rating")
///   try database.write { /* make changes */ }
///   try undoClient.endBarrier(barrierId)
/// } catch {
///   try undoClient.cancelBarrier(barrierId)
///   throw error
/// }
/// ```
@DependencyClient
public struct UndoClient: Sendable {
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

  /// Set the UndoManager for this client.
  ///
  /// Call this from a view's onAppear to connect the window's UndoManager
  /// to the undo system. For multi-window apps, each window should call this
  /// with its own UndoManager.
  ///
  /// - Parameter undoManager: The UndoManager to use, or nil to clear
  public var setUndoManager: @Sendable (_ undoManager: UndoManager?) -> Void = { _ in }
}

// MARK: - SendableUndoManager

/// Thread-safe wrapper around UndoManager for use in Sendable contexts.
public final class SendableUndoManager: @unchecked Sendable {
  public var wrappedValue: UndoManager?

  public init(_ undoManager: @autoclosure () -> UndoManager?) {
    self.wrappedValue = undoManager()
  }

  public func replace(_ undoManager: UndoManager?) {
    self.wrappedValue = undoManager
  }

  @MainActor
  public func withUndoManager(_ operation: @MainActor (UndoManager) -> Void) {
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

// MARK: - Dependency Registration

extension DependencyValues {
  public var undoClient: UndoClient {
    get { self[UndoClient.self] }
    set { self[UndoClient.self] = newValue }
  }
}

extension UndoClient: DependencyKey {
  public static var liveValue: UndoClient {
    @Dependency(\.defaultDatabase) var database
    return .make(database: database)
  }

  public static var testValue: UndoClient {
    UndoClient()
  }

  /// Create an UndoClient for a specific database.
  ///
  /// Use this for multi-window apps where each window has its own database.
  /// After creating, call `setUndoManager` from the view layer to connect
  /// the window's UndoManager.
  ///
  /// For single-window apps, `liveValue` uses `defaultDatabase` dependency.
  public static func make(database: any DatabaseWriter) -> UndoClient {
    let engine = UndoEngine(database: database)
    let undoManager = SendableUndoManager(nil)
    return UndoClient(
      beginBarrier: { name in
        try engine.beginBarrier(name)
      },
      endBarrier: { id in
        guard let barrier = try engine.endBarrier(id) else {
          return
        }
        MainActor.assumeIsolated {
          registerUndo(barrier: barrier, engine: engine, undoManager: undoManager)
        }
      },
      cancelBarrier: { id in
        try engine.cancelBarrier(id)
      },
      performUndo: { barrier in
        try engine.performUndo(barrier: barrier)
      },
      performRedo: { barrier in
        try engine.performRedo(barrier: barrier)
      },
      withUndoDisabled: { operation in
        try engine.withUndoDisabled(operation)
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
  engine: UndoEngine,
  undoManager: SendableUndoManager
) {
  undoManager.withUndoManager { manager in
    logger.debug("Registering undo: \(barrier.name)")
    // Each barrier gets its own undo group to prevent coalescing
    manager.beginUndoGrouping()
    manager.setActionName(barrier.name)
    manager.registerUndo(withTarget: engine) { engine in
      MainActor.assumeIsolated {
        logger.debug("Performing undo: \(barrier.name)")
        do {
          try engine.performUndo(barrier: barrier)
          registerRedo(barrier: barrier, engine: engine, undoManager: undoManager)
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
  engine: UndoEngine,
  undoManager: SendableUndoManager
) {
  undoManager.withUndoManager { manager in
    logger.debug("Registering redo: \(barrier.name)")
    manager.registerUndo(withTarget: engine) { engine in
      MainActor.assumeIsolated {
        logger.debug("Performing redo: \(barrier.name)")
        do {
          try engine.performRedo(barrier: barrier)
          registerUndo(barrier: barrier, engine: engine, undoManager: undoManager)
        } catch {
          logger.error("Redo failed: \(error)")
        }
      }
    }
  }
}
