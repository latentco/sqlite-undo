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
/// A stack is one undo scope: one undo/redo history, one Edit menu, one event
/// stream. The default stack is app-wide, which is all a single-window app needs.
/// For separate per-window histories, see ``Dependencies/DependencyValues/installDefaultUndoStack(_:)``.
///
/// ## Setup
///
/// The UndoManager usually arrives from the view's environment rather than being
/// known up front — `setUndoManager(_:)` connects it, which
/// `UndoManagingReducer` does for you in the TCA integration.
///
/// In tests, use the automatic test implementation which tracks stack state
/// without requiring a real UndoManager.
@DependencyClient
public struct UndoStack: Sendable {
  /// Register a barrier for undo/redo with the UndoManager.
  ///
  /// Called by UndoEngine when a barrier completes with changes.
  public var registerBarrier:
    @Sendable (
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

  /// Stream of events emitted after each undo/redo performed on this stack.
  ///
  /// Events are scoped to the stack, so a window observes only the undos performed
  /// against its own UndoManager. Windows sharing an UndoManager (as multiple
  /// windows on one document do) share a stack, and so see the same events.
  ///
  /// Each call returns an independent subscription delivering events from that point
  /// on; earlier events are not replayed. Cancelling one subscription leaves the
  /// others unaffected, so callers may freely resubscribe.
  public var events: @Sendable () -> AsyncStream<UndoEvent> = { .finished }

  /// Deliver an event to this stack's subscribers.
  ///
  /// Internal: called by `UndoEngine` from the undo/redo closures it registers, which
  /// is what binds an event to the scope that performed it.
  var emit: @Sendable (_ event: UndoEvent) -> Void = { _ in }
}

/// Fan-out of undo events to any number of independent subscribers.
private final class UndoEventBroadcaster: Sendable {
  private let subscribers = LockIsolated([UUID: AsyncStream<UndoEvent>.Continuation]())

  func events() -> AsyncStream<UndoEvent> {
    let id = UUID()
    let (stream, continuation) = AsyncStream<UndoEvent>.makeStream()
    subscribers.withValue { $0[id] = continuation }
    continuation.onTermination = { [subscribers] _ in
      subscribers.withValue { _ = $0.removeValue(forKey: id) }
    }
    return stream
  }

  func emit(_ event: UndoEvent) {
    // Copy out before yielding so `onTermination` can't re-enter the lock.
    for continuation in subscribers.withValue({ Array($0.values) }) {
      continuation.yield(event)
    }
  }
}

extension DependencyValues {
  public var defaultUndoStack: UndoStack {
    get { self[UndoStack.self] }
    set { self[UndoStack.self] = newValue }
  }

  /// Give the surrounding dependency scope its own undo stack.
  ///
  /// A stack is one undo scope: one undo/redo history, one Edit menu, one event
  /// stream. The default stack is already app-wide, so a single-window app needs
  /// none of this.
  ///
  /// Call this to create an *additional* scope — once per window, inside the
  /// `withDependencies` that builds that window's store:
  ///
  /// ```swift
  /// @State private var store = withDependencies {
  ///   $0.installDefaultUndoStack()
  /// } operation: {
  ///   Store(initialState: MyFeature.State()) { MyFeature() }
  /// }
  /// ```
  ///
  /// Windows meant to share one undo history should share one stack, so install it
  /// once and hand the same value to each.
  ///
  /// - Parameter undoManager: The UndoManager to register with. Omit it when the
  ///   manager arrives later from the view's environment, as it does in SwiftUI.
  public mutating func installDefaultUndoStack(_ undoManager: UndoManager? = nil) {
    defaultUndoStack = .live(undoManager)
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
    let broadcaster = UndoEventBroadcaster()

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
      setUndoManager: { _ in },
      events: { broadcaster.events() },
      emit: { broadcaster.emit($0) }
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
    let broadcaster = UndoEventBroadcaster()

    // Target object for NSUndoManager registration - holds mutable UndoManager reference.
    //
    // `undoManager` is weak because the window owns its UndoManager, not us. That
    // also keeps the registration closures below (which capture this target
    // strongly, since NSUndoManager does not retain its target) from cycling.
    final class UndoTarget: @unchecked Sendable {
      let state: LockIsolated<UndoStackState>
      weak var undoManager: UndoManager?

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
            "No UndoManager set. Call setUndoManager(), or install the stack with installDefaultUndoStack(undoManager)"
          )
          logger.warning(
            "\(self.currentState.logDescription(after: "\"\(barrier.name)\" — undoManager is nil, registration dropped"))"
          )
          return
        }
        logger.debug("Registering undo: \(barrier.name)")
        undoManager.beginUndoGrouping()
        undoManager.setActionName(barrier.name)
        undoManager.registerUndo(withTarget: self) { [self] _ in
          MainActor.assumeIsolated {
            logger.debug("Performing undo: \(barrier.name)")
            do {
              try onUndo()
              state.withValue {
                if let index = $0.undo.lastIndex(of: barrier.name) {
                  $0.undo.remove(at: index)
                }
                $0.redo.append(barrier.name)
              }
              logger.info(
                "\(self.currentState.logDescription(after: "undo \"\(barrier.name)\""))"
              )
              registerRedo(barrier: barrier, onUndo: onUndo, onRedo: onRedo)
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
            "No UndoManager set. Call setUndoManager(), or install the stack with installDefaultUndoStack(undoManager)"
          )
          logger.warning(
            "\(self.currentState.logDescription(after: "redo \"\(barrier.name)\" — undoManager is nil"))"
          )
          return
        }
        logger.debug("Registering redo: \(barrier.name)")
        undoManager.registerUndo(withTarget: self) { [self] _ in
          MainActor.assumeIsolated {
            logger.debug("Performing redo: \(barrier.name)")
            do {
              try onRedo()
              state.withValue {
                if let index = $0.redo.lastIndex(of: barrier.name) {
                  $0.redo.remove(at: index)
                }
                $0.undo.append(barrier.name)
              }
              logger.info(
                "\(self.currentState.logDescription(after: "redo \"\(barrier.name)\""))"
              )
              registerUndo(barrier: barrier, onUndo: onUndo, onRedo: onRedo)
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
        // NSUndoManager requires main thread
        if Thread.isMainThread {
          MainActor.assumeIsolated {
            target.registerUndo(barrier: barrier, onUndo: onUndo, onRedo: onRedo)
          }
        } else {
          DispatchQueue.main.sync {
            MainActor.assumeIsolated {
              target.registerUndo(barrier: barrier, onUndo: onUndo, onRedo: onRedo)
            }
          }
        }
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
      },
      events: { broadcaster.events() },
      emit: { broadcaster.emit($0) }
    )
  }
}
