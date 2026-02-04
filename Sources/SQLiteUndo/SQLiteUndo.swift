import CasePaths
import ComposableArchitecture
import Foundation
import SwiftUI

// MARK: - TCA Integration

/// Protocol for actions that can receive the UndoManager from the view layer.
///
/// Conform your feature's Action to this protocol to enable automatic UndoManager setup:
///
/// ```swift
/// @Reducer struct MyFeature {
///   enum Action: UndoManagingAction {
///     case setUndoManager(UndoManager?)
///     // ... other actions
///   }
///
///   var body: some Reducer<State, Action> {
///     Reduce { state, action in
///       switch action {
///       case .setUndoManager(let manager):
///         undoClient.setUndoManager(manager)
///         return .none
///       // ...
///       }
///     }
///   }
/// }
/// ```
public protocol UndoManagingAction {
  static func setUndoManager(_ manager: UndoManager?) -> Self
}

// MARK: - View Modifier

/// Sends the view's UndoManager to the store on appear.
///
/// Use this on your root view to connect the window's UndoManager to the undo system:
///
/// ```swift
/// MyView(store: store)
///   .installUndoManager(store: store)
/// ```
public struct InstallUndoManagerModifier<State, Action: UndoManagingAction>: ViewModifier {
  @Environment(\.undoManager) var undoManager
  let store: Store<State, Action>

  public func body(content: Content) -> some View {
    content
      .onAppear {
        store.send(.setUndoManager(undoManager))
      }
      .onChange(of: undoManager) { newValue in
        store.send(.setUndoManager(newValue))
      }
  }
}

extension View {
  /// Installs the view's UndoManager into the store's undo system.
  ///
  /// Call this on your root view to connect the window's UndoManager:
  ///
  /// ```swift
  /// ContentView(store: store)
  ///   .installUndoManager(store: store)
  /// ```
  public func installUndoManager<State, Action: UndoManagingAction>(
    store: Store<State, Action>
  ) -> some View {
    modifier(InstallUndoManagerModifier(store: store))
  }
}

// MARK: - Reducer Helper

/// A reducer that handles `UndoManagingAction` by setting the UndoManager on the UndoClient.
///
/// Compose this into your feature to automatically handle the setUndoManager action:
///
/// ```swift
/// var body: some Reducer<State, Action> {
///   UndoManagingReducer()
///   // ... your other reducers
/// }
/// ```
public struct UndoManagingReducer<State, Action: UndoManagingAction>: Reducer {
  @Dependency(\.undoClient) var undoClient

  public init() {}

  public var body: some Reducer<State, Action> {
    Reduce { state, action in
      guard let manager = AnyCasePath(unsafe: Action.setUndoManager).extract(from: action) else {
        return .none
      }
      undoClient.setUndoManager(manager)
      return .none
    }
  }
}
