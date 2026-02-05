import Dependencies
import DependenciesMacros
import Foundation
import OSLog

private let logger = Logger(subsystem: "SQLiteUndo", category: "UndoManagerClient")

/// Dependency for NSUndoManager integration.
///
/// This client handles registration of undo/redo actions with NSUndoManager
/// and tracks the undo/redo stack state for testing.
///
/// ## Setup
///
/// In production, wrap the window's UndoManager:
/// ```swift
/// prepareDependencies {
///   $0.defaultUndoManager = .live(windowUndoManager)
/// }
/// ```
///
/// In tests, use the automatic test implementation which tracks stack state
/// without requiring a real UndoManager.
@DependencyClient
public struct UndoManagerClient: Sendable {
  /// Register a barrier for undo/redo with the UndoManager.
  ///
  /// Called by UndoEngine when a barrier completes with changes.
  public var registerBarrier: @MainActor @Sendable (
    _ barrier: UndoBarrier,
    _ onUndo: @escaping @Sendable () throws -> Void,
    _ onRedo: @escaping @Sendable () throws -> Void
  ) -> Void = { _, _, _ in }

  /// Returns the current undo/redo stack state.
  ///
  /// Use this in tests to verify that undoable actions were registered correctly.
  ///
  /// ```swift
  /// await store.send(.setFave(true))
  /// #expect(undoManager.undoStackState() == ["Add Fave"])
  /// ```
  public var undoStackState: @Sendable () -> UndoStackState = { UndoStackState(undo: []) }

  /// Set or update the UndoManager.
  ///
  /// Use this when the UndoManager is provided dynamically (e.g., from SwiftUI view).
  /// For the `.live()` client, this updates which UndoManager receives registrations.
  /// For the test client, this is a no-op.
  public var setUndoManager: @Sendable (_ undoManager: UndoManager?) -> Void = { _ in }
}

extension DependencyValues {
  public var defaultUndoManager: UndoManagerClient {
    get { self[UndoManagerClient.self] }
    set { self[UndoManagerClient.self] = newValue }
  }
}

extension UndoManagerClient: DependencyKey {
  public static var liveValue: UndoManagerClient {
    .live()
  }

  public static var previewValue: UndoManagerClient {
    testValue
  }

  public static var testValue: UndoManagerClient {
    let state = LockIsolated(UndoStackState(undo: []))

    return UndoManagerClient(
      registerBarrier: { barrier, onUndo, onRedo in
        state.withValue {
          $0.undo.append(barrier.name)
          $0.redo = []
        }
      },
      undoStackState: { state.value },
      setUndoManager: { _ in }
    )
  }

  /// Create a client for production use.
  ///
  /// The UndoManager can be set later via `setUndoManager` when it becomes available
  /// from the view layer.
  ///
  /// - Parameter undoManager: Optional initial UndoManager
  public static func live(_ undoManager: UndoManager? = nil) -> UndoManagerClient {
    let state = LockIsolated(UndoStackState(undo: []))

    // Target object for NSUndoManager registration - holds mutable UndoManager reference
    final class UndoTarget: @unchecked Sendable {
      let state: LockIsolated<UndoStackState>
      var undoManager: UndoManager?

      init(state: LockIsolated<UndoStackState>, undoManager: UndoManager?) {
        self.state = state
        self.undoManager = undoManager
      }

      @MainActor
      func registerUndo(
        barrier: UndoBarrier,
        onUndo: @escaping @Sendable () throws -> Void,
        onRedo: @escaping @Sendable () throws -> Void
      ) {
        guard let undoManager else {
          reportIssue("No UndoManager set. Call setUndoManager() or configure defaultUndoManager = .live(undoManager)")
          return
        }
        logger.debug("Registering undo: \(barrier.name)")
        undoManager.beginUndoGrouping()
        undoManager.setActionName(barrier.name)
        undoManager.registerUndo(withTarget: self) { [weak self] target in
          MainActor.assumeIsolated {
            logger.debug("Performing undo: \(barrier.name)")
            do {
              try onUndo()
              self?.state.withValue {
                if let index = $0.undo.lastIndex(of: barrier.name) {
                  $0.undo.remove(at: index)
                }
                $0.redo.append(barrier.name)
              }
              target.registerRedo(barrier: barrier, onUndo: onUndo, onRedo: onRedo)
            } catch {
              logger.error("Undo failed: \(error)")
            }
          }
        }
        undoManager.endUndoGrouping()
      }

      @MainActor
      func registerRedo(
        barrier: UndoBarrier,
        onUndo: @escaping @Sendable () throws -> Void,
        onRedo: @escaping @Sendable () throws -> Void
      ) {
        guard let undoManager else {
          reportIssue("No UndoManager set. Call setUndoManager() or configure defaultUndoManager = .live(undoManager)")
          return
        }
        logger.debug("Registering redo: \(barrier.name)")
        undoManager.registerUndo(withTarget: self) { [weak self] target in
          MainActor.assumeIsolated {
            logger.debug("Performing redo: \(barrier.name)")
            do {
              try onRedo()
              self?.state.withValue {
                if let index = $0.redo.lastIndex(of: barrier.name) {
                  $0.redo.remove(at: index)
                }
                $0.undo.append(barrier.name)
              }
              target.registerUndo(barrier: barrier, onUndo: onUndo, onRedo: onRedo)
            } catch {
              logger.error("Redo failed: \(error)")
            }
          }
        }
      }
    }

    let target = UndoTarget(state: state, undoManager: undoManager)

    return UndoManagerClient(
      registerBarrier: { barrier, onUndo, onRedo in
        state.withValue {
          $0.undo.append(barrier.name)
          $0.redo = []
        }
        target.registerUndo(barrier: barrier, onUndo: onUndo, onRedo: onRedo)
      },
      undoStackState: { state.value },
      setUndoManager: { target.undoManager = $0 }
    )
  }
}
