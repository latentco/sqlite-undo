# SQLiteUndo

[![CI](https://github.com/latentco/sqlite-undo/actions/workflows/ci.yml/badge.svg)](https://github.com/latentco/sqlite-undo/actions/workflows/ci.yml)

SQLite-based undo/redo for Swift apps using [SQLiteData](https://github.com/pointfreeco/sqlite-data) and [StructuredQueries](https://github.com/pointfreeco/swift-structured-queries). Uses database triggers to automatically capture reverse SQL for all changes to tracked tables, following the pattern described in [Automatic Undo/Redo Using SQLite](https://www.sqlite.org/undoredo.html).

Changes are grouped into barriers that represent single user actions (e.g., "Set Rating", "Delete Item"). Barriers integrate with `NSUndoManager` so undo/redo works with the standard Edit menu, keyboard shortcuts, and shake-to-undo.

Two libraries are provided:

- **SQLiteUndo** — core undo engine, barriers, and free functions (`undoable`, `withUndoDisabled`)
- **SQLiteUndoTCA** — [ComposableArchitecture](https://github.com/pointfreeco/swift-composable-architecture) integration for `UndoManager` wiring in SwiftUI

## Adding SQLiteUndo as a dependency

Add the following to your `Package.swift`:

```swift
.package(url: "https://github.com/latentco/sqlite-undo.git", from: "0.1.0"),
```

Then add the product to your target's dependencies:

```swift
.product(name: "SQLiteUndo", package: "sqlite-undo"),
```

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

### Disabling undo tracking

Use `withUndoDisabled` for operations that shouldn't be undoable (e.g., batch imports, programmatic state rebuilds):

```swift
try withUndoDisabled {
  try database.write { db in
    try Article.insert { Article(id: 1, name: "Imported") }.execute(db)
  }
}
```

### Application triggers

The undo system uses BEFORE triggers to capture original row values before any cascade can modify them, and reconciles duplicate entries automatically. Same-table cascading triggers (e.g., enforcing "only one row can be primary") generally work without special handling because the undo log captures all affected rows and reconciliation keeps the true originals.

However, if your app has triggers that produce **side effects on other undo-tracked tables** (e.g., incrementing a counter on table B when table A is updated), you must suppress them during replay with `UndoEngine.isReplaying()`. Otherwise the side effect fires again during undo/redo, corrupting the restored state.

```swift
Article.createTemporaryTrigger(
  after: .update { $0.status },
  forEachRow: { old, new in
    // Side effect on a different table — needs isReplaying guard
    AuditLog.insert { AuditLog(articleId: new.id, action: "updated") }
  },
  when: { old, new in
    !UndoEngine.isReplaying()
  }
)
```

Or in raw SQL:

```sql
CREATE TRIGGER audit_article_update
AFTER UPDATE OF "status" ON "articles"
WHEN NOT "sqliteundo_isReplaying"()
BEGIN
  INSERT INTO "auditLog" ("articleId", "action") VALUES (NEW."id", 'updated');
END
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
