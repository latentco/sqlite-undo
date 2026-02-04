import ComposableArchitecture
import SQLiteUndo
import SwiftUI

@main
struct UndoForMacOSApp: App {
  static let store = Store(
    initialState: DemoFeature.State()
  ) {
    DemoFeature()
  }
  init() {
    prepareDependencies {
      let database = try! makeDemoDatabase()
      $0.defaultDatabase = database
      $0.undoClient = .make(database: database)
    }
  }
  var body: some Scene {
    WindowGroup {
      DemoView(store: Self.store)
    }
  }
}

@Table
struct DemoItem: Identifiable, UndoTracked {
  @Column(primaryKey: true) var id: Int
  var name: String = ""
  var count: Int = 0
}

@Reducer
struct DemoFeature {
  @ObservableState
  struct State {
    var items: [DemoItem] = []
  }

  enum Action: UndoManagingAction {
    case setUndoManager(UndoManager?)
    case load
    case addItem
    case incrementCount(Int)
    case deleteItem(Int)
  }

  @Dependency(\.undoClient) var undoClient
  @Dependency(\.defaultDatabase) var database

  var body: some Reducer<State, Action> {
    UndoManagingReducer()
    Reduce { state, action in
      switch action {
      case .setUndoManager:
        return .none

      case .load:
        state.items =
          (try? database.read { db in
            try DemoItem.all.order { $0.id }.fetchAll(db)
          }) ?? []
        return .none

      case .addItem:
        withErrorReporting {
          let barrierId = try undoClient.beginBarrier("Add Item")
          try database.write { db in
            let nextID = (try DemoItem.all.fetchAll(db).map(\.id).max() ?? 0) + 1
            try DemoItem.insert { DemoItem(id: nextID, name: "Item \(nextID)") }.execute(db)
          }
          try undoClient.endBarrier(barrierId)
        }
        return .send(.load)

      case .incrementCount(let id):
        withErrorReporting {
          let barrierId = try undoClient.beginBarrier("Increment Count")
          try database.write { db in
            try DemoItem.find(id).update { $0.count += 1 }.execute(db)
          }
          try undoClient.endBarrier(barrierId)
        }
        return .send(.load)

      case .deleteItem(let id):
        withErrorReporting {
          let barrierId = try undoClient.beginBarrier("Delete Item")
          try database.write { db in
            try DemoItem.find(id).delete().execute(db)
          }
          try undoClient.endBarrier(barrierId)
        }
        return .send(.load)
      }
    }
  }
}

struct DemoView: View {
  @Bindable var store: StoreOf<DemoFeature>
  @Environment(\.undoManager) var undoManager

  var body: some View {
    VStack(spacing: 16) {
      Text("SQLiteUndo Demo")
        .font(.headline)

      Text("Use Edit > Undo (⌘Z) and Redo (⇧⌘Z)")
        .font(.caption)
        .foregroundStyle(.secondary)

      HStack {
        Button("Undo") { undoManager?.undo() }.disabled(!(undoManager?.canUndo ?? false))
        Button("Redo") { undoManager?.redo() }.disabled(!(undoManager?.canRedo ?? false))
      }

      List {
        ForEach(store.items) { item in
          HStack {
            Text(item.name)
            Spacer()
            Text("Count: \(item.count)")
              .foregroundStyle(.secondary)
            Button("+") {
              store.send(.incrementCount(item.id))
            }
            .buttonStyle(.bordered)
            Button("Delete") {
              store.send(.deleteItem(item.id))
            }
            .buttonStyle(.bordered)
            .tint(.red)
          }
        }
      }
      .frame(minHeight: 200)

      Button("Add Item") {
        store.send(.addItem)
      }
      .buttonStyle(.borderedProminent)
    }
    .padding()
    .frame(width: 400)
    .onAppear {
      store.send(.load)
    }
    .installUndoManager(store: store)
  }
}

func makeDemoDatabase() throws -> any DatabaseWriter {
  let database = try DatabaseQueue()

  try database.write { db in
    try db.execute(
      sql: """
        CREATE TABLE "demoItems" (
          "id" INTEGER PRIMARY KEY,
          "name" TEXT NOT NULL DEFAULT '',
          "count" INTEGER NOT NULL DEFAULT 0
        )
        """
    )
  }

  try database.installUndoSystem()

  try database.write { db in
    try DemoItem.installUndoTriggers(db)
  }

  return database
}

#Preview("SQLite Undo Demo") {
  let _ = prepareDependencies {
    let database = try! makeDemoDatabase()
    $0.defaultDatabase = database
    $0.undoClient = .make(database: database)
  }
  let store = Store(initialState: DemoFeature.State()) {
    DemoFeature()
  }
  DemoView(store: store)
}
