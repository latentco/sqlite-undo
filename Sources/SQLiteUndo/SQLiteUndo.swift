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

//// MARK: - Preview Demo
//
//#if DEBUG
//  import GRDB
//  import StructuredQueries
//
//  @Table
//  private struct DemoItem: Identifiable, UndoTracked {
//    @Column(primaryKey: true) var id: Int
//    var name: String = ""
//    var count: Int = 0
//  }
//
//  @Reducer
//  private struct DemoFeature {
//    @ObservableState
//    struct State {
//      var items: [DemoItem] = []
//    }
//
//    enum Action: UndoManagingAction {
//      case setUndoManager(UndoManager?)
//      case load
//      case addItem
//      case incrementCount(Int)
//      case deleteItem(Int)
//    }
//
//    @Dependency(\.undoClient) var undoClient
//    @Dependency(\.defaultDatabase) var database
//
//    var body: some Reducer<State, Action> {
//      UndoManagingReducer()
//      Reduce { state, action in
//        switch action {
//        case .setUndoManager:
//          return .none
//
//        case .load:
//          state.items =
//            (try? database.read { db in
//              try DemoItem.all.order { $0.id }.fetchAll(db)
//            }) ?? []
//          return .none
//
//        case .addItem:
//          withErrorReporting {
//            let barrierId = try undoClient.beginBarrier("Add Item")
//            try database.write { db in
//              let nextID = (try DemoItem.all.fetchAll(db).map(\.id).max() ?? 0) + 1
//              try DemoItem.insert { DemoItem(id: nextID, name: "Item \(nextID)") }.execute(db)
//            }
//            try undoClient.endBarrier(barrierId)
//          }
//          return .send(.load)
//
//        case .incrementCount(let id):
//          withErrorReporting {
//            let barrierId = try undoClient.beginBarrier("Increment Count")
//            try database.write { db in
//              try DemoItem.find(id).update { $0.count += 1 }.execute(db)
//            }
//            try undoClient.endBarrier(barrierId)
//          }
//          return .send(.load)
//
//        case .deleteItem(let id):
//          withErrorReporting {
//            let barrierId = try undoClient.beginBarrier("Delete Item")
//            try database.write { db in
//              try DemoItem.find(id).delete().execute(db)
//            }
//            try undoClient.endBarrier(barrierId)
//          }
//          return .send(.load)
//        }
//      }
//    }
//  }
//
//  private struct DemoView: View {
//    @Bindable var store: StoreOf<DemoFeature>
//    @Environment(\.undoManager) var undoManager
//
//    var body: some View {
//      VStack(spacing: 16) {
//        Text("SQLite Undo Demo")
//          .font(.headline)
//
//        Text("Use Edit > Undo (⌘Z) and Redo (⇧⌘Z)")
//          .font(.caption)
//          .foregroundStyle(.secondary)
//
//        HStack {
//          Button("Undo") { undoManager?.undo() }
//          Button("Redo") { undoManager?.redo() }
//        }
//
//        List {
//          ForEach(store.items) { item in
//            HStack {
//              Text(item.name)
//              Spacer()
//              Text("Count: \(item.count)")
//                .foregroundStyle(.secondary)
//              Button("+") {
//                store.send(.incrementCount(item.id))
//              }
//              .buttonStyle(.bordered)
//              Button("Delete") {
//                store.send(.deleteItem(item.id))
//              }
//              .buttonStyle(.bordered)
//              .tint(.red)
//            }
//          }
//        }
//        .frame(minHeight: 200)
//
//        Button("Add Item") {
//          store.send(.addItem)
//        }
//        .buttonStyle(.borderedProminent)
//      }
//      .padding()
//      .frame(width: 400)
//      .onAppear {
//        store.send(.load)
//      }
//      .installUndoManager(store: store)
//    }
//  }
//
//  private func makeDemoDatabase() throws -> any DatabaseWriter {
//    let database = try DatabaseQueue()
//
//    try database.write { db in
//      try db.execute(
//        sql: """
//          CREATE TABLE "demoItems" (
//            "id" INTEGER PRIMARY KEY,
//            "name" TEXT NOT NULL DEFAULT '',
//            "count" INTEGER NOT NULL DEFAULT 0
//          )
//          """
//      )
//    }
//
//    try database.installUndoSystem()
//
//    try database.write { db in
//      try DemoItem.installUndoTriggers(db)
//    }
//
//    return database
//  }
//
//  #Preview("SQLite Undo Demo") {
//    let _ = prepareDependencies {
//      let database = try! makeDemoDatabase()
//      $0.defaultDatabase = database
//      $0.undoClient = .make(database: database)
//    }
//    let store = Store(initialState: DemoFeature.State()) {
//      DemoFeature()
//    }
//    DemoView(store: store)
//  }
//#endif
