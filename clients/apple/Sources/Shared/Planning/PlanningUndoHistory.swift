import Foundation

@MainActor
final class PlanningUndoHistory {
  private var pending: Task<Void, Never>?

  func recordDeletion(manager: UndoManager?, apply: @escaping @MainActor (Bool) async -> Void) {
    register(restore: true, manager: manager, apply: apply)
  }

  private func register(
    restore: Bool, manager: UndoManager?, apply: @escaping @MainActor (Bool) async -> Void
  ) {
    manager?.registerUndo(withTarget: self) { [weak manager] history in
      // Register synchronously so UndoManager places the inverse on its redo stack.
      history.register(restore: !restore, manager: manager, apply: apply)
      let previous = history.pending
      history.pending = Task { @MainActor in
        await previous?.value
        await apply(restore)
      }
    }
    manager?.setActionName("Delete Card")
  }

  func waitForPending() async { await pending?.value }
}
