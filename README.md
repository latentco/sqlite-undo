# SQLiteUndo

[![CI](https://github.com/latentco/sqlite-undo/actions/workflows/ci.yml/badge.svg)](https://github.com/latentco/sqlite-undo/actions/workflows/ci.yml)

SQLite-based undo/redo for Swift apps using [SQLiteData](https://github.com/pointfreeco/sqlite-data). Uses database triggers to capture changes automatically using the pattern described in [Automatic Undo/Redo Using SQLite](https://www.sqlite.org/undoredo.html)

## Setup

```swift
prepareDependencies {
  $0.defaultDatabase = try! appDatabase()
  $0.defaultUndoEngine = try! UndoEngine(
    for: $0.defaultDatabase,
    tables: Article.self, Author.self
  )
}
```

Pass any `@Table` types to track:

```swift
@Table
struct Article {
  let id: Int
  var name: String
}
```

## Usage

```swift
import SQLiteUndo

try await undoable("Set Rating") {
  try await database.write { db in
    try Article.find(id).update { $0.rating = 5 }.execute(db)
  }
}
```

### With explicit barrier management

```swift
@Dependency(\.defaultUndoEngine) var undoEngine

let barrierId = try undoEngine.beginBarrier("Set Rating")
try database.write { db in
  try Article.find(id).update { $0.rating = 5 }.execute(db)
}
try undoEngine.endBarrier(barrierId)
```

## ComposableArchitecture/SwiftUI Integration

```swift
import SQLiteUndoTCA

@Reducer
struct MyFeature {
  @ObservableState
  struct State { }

  enum Action: UndoManageableAction { // ✅ integrate the store for UndoManager registration
    case undoManager(UndoManagingAction)
    case setRating(Int)
  }

  @Dependency(\.defaultDatabase) var database

  var body: some ReducerOf<Self> {
    UndoManagingReducer()
    Reduce { state, action in
      switch action {
      case .undoManager:
        return .none
      case .setRating(let rating):
        try undoable("Set Rating") { // ✅ wrap db operations in undoable
          try database.write { db in
            try Article.find(id).update { $0.rating = rating }.execute(db)
          }
        }
        return .none
      }
    }
  }
}

struct MyView: View {
  let store: StoreOf<MyFeature>
  var body: some View {
    VStack {
      // ... 
    }
    .setUndoManager(store: store) // ✅ pass the view's UndoManager to the system
  }
}
```
