import Dependencies
import DependenciesMacros
import Foundation
import OSLog

private let logger = Logger(subsystem: "SQLiteUndo", category: "UndoStack")

/// Dependency for NSUndoManager integration.
///
/// This type handles registration of undo/redo actions with NSUndoManager
/// and tracks the undo/redo stack state for testing.
///
/// ## Setup
///
/// In production, wrap the window's UndoManager:
/// ```swift
/// prepareDependencies {
///   $0.defaultUndoStack = .live(windowUndoManager)
/// }
/// ```
///
/// In tests, use the automatic test implementation which tracks stack state
/// without requiring a real UndoManager.
@DependencyClient
public struct UndoStack: Sendable {
  /// Register a barrier for undo/redo with the UndoManager.
  ///
  /// Called by UndoEngine when a barrier completes with changes.
  public var registerBarrier:
    @MainActor @Sendable (
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
  /// #expect(undoStack.currentState() == ["Add Fave"])
  /// ```
  public var currentState: @Sendable () -> UndoStackState = { UndoStackState(undo: []) }

  /// Set or update the UndoManager.
  ///
  /// Use this when the UndoManager is provided dynamically (e.g., from SwiftUI view).
  /// For the `.live()` stack, this updates which UndoManager receives registrations.
  /// For the test stack, this is a no-op.
  public var setUndoManager: @Sendable (_ undoManager: UndoManager?) -> Void = { _ in }
}

extension DependencyValues {
  public var defaultUndoStack: UndoStack {
    get { self[UndoStack.self] }
    set { self[UndoStack.self] = newValue }
  }
}

extension UndoStack: DependencyKey {
  public static var liveValue: UndoStack {
    .live()
  }

  public static var previewValue: UndoStack {
    testValue
  }

  public static var testValue: UndoStack {
    let state = LockIsolated(UndoStackState(undo: []))

    return UndoStack(
      registerBarrier: { barrier, onUndo, onRedo in
        state.withValue {
          $0.undo.append(barrier.name)
          $0.redo = []
        }
      },
      currentState: {
        UndoStackState(
          undo: state.value.undo.reversed(),
          redo: state.value.redo.reversed()
        )
      },
      setUndoManager: { _ in }
    )
  }

  /// Create a stack for production use.
  ///
  /// The UndoManager can be set later via `setUndoManager` when it becomes available
  /// from the view layer.
  ///
  /// - Parameter undoManager: Optional initial UndoManager
  public static func live(_ undoManager: UndoManager? = nil) -> UndoStack {
    let state = LockIsolated(UndoStackState(undo: []))

    // Target object for NSUndoManager registration - holds mutable UndoManager reference
    final class UndoTarget: @unchecked Sendable {
      let state: LockIsolated<UndoStackState>
      var undoManager: UndoManager?

      init(state: LockIsolated<UndoStackState>, undoManager: UndoManager?) {
        self.state = state
        self.undoManager = undoManager
      }

      var currentState: UndoStackState {
        UndoStackState(
          undo: state.value.undo.reversed(),
          redo: state.value.redo.reversed()
        )
      }

      @MainActor
      func registerUndo(
        barrier: UndoBarrier,
        onUndo: @escaping @Sendable () throws -> Void,
        onRedo: @escaping @Sendable () throws -> Void
      ) {
        guard let undoManager else {
          reportIssue(
            "No UndoManager set. Call setUndoManager() or configure defaultUndoStack = .live(undoManager)"
          )
          logger.warning(
            "\(self.currentState.logDescription(after: "\"\(barrier.name)\" — undoManager is nil, registration dropped"))"
          )
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
              if let self {
                logger.info("\(self.currentState.logDescription(after: "undo \"\(barrier.name)\""))")
              }
              target.registerRedo(barrier: barrier, onUndo: onUndo, onRedo: onRedo)
            } catch {
              logger.error("Undo failed for \"\(barrier.name)\": \(error)")
            }
          }
        }
        undoManager.endUndoGrouping()
        logger.info("\(self.currentState.logDescription(after: "register \"\(barrier.name)\""))")
      }

      @MainActor
      func registerRedo(
        barrier: UndoBarrier,
        onUndo: @escaping @Sendable () throws -> Void,
        onRedo: @escaping @Sendable () throws -> Void
      ) {
        guard let undoManager else {
          reportIssue(
            "No UndoManager set. Call setUndoManager() or configure defaultUndoStack = .live(undoManager)"
          )
          logger.warning(
            "\(self.currentState.logDescription(after: "redo \"\(barrier.name)\" — undoManager is nil"))"
          )
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
              if let self {
                logger.info("\(self.currentState.logDescription(after: "redo \"\(barrier.name)\""))")
              }
              target.registerUndo(barrier: barrier, onUndo: onUndo, onRedo: onRedo)
            } catch {
              logger.error("Redo failed for \"\(barrier.name)\": \(error)")
            }
          }
        }
      }
    }

    let target = UndoTarget(state: state, undoManager: undoManager)

    return UndoStack(
      registerBarrier: { barrier, onUndo, onRedo in
        state.withValue {
          $0.undo.append(barrier.name)
          $0.redo = []
        }
        target.registerUndo(barrier: barrier, onUndo: onUndo, onRedo: onRedo)
      },
      currentState: {
        UndoStackState(
          undo: state.value.undo.reversed(),
          redo: state.value.redo.reversed()
        )
      },
      setUndoManager: {
        target.undoManager = $0
        if $0 != nil {
          logger.info("setUndoManager: set")
        } else {
          logger.warning("setUndoManager: nil")
        }
      }
    )
  }
}
