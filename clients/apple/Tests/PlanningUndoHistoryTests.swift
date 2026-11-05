import XCTest

@testable import HQ

@MainActor
final class PlanningUndoHistoryTests: XCTestCase {
  func testDeletionUndoAndRedoPreserveOrderDuringRapidCommands() async {
    let history = PlanningUndoHistory()
    let manager = UndoManager()
    manager.groupsByEvent = false
    var applied: [Bool] = []
    manager.beginUndoGrouping()
    history.recordDeletion(manager: manager) { restore in applied.append(restore) }
    manager.endUndoGrouping()
    XCTAssertTrue(manager.canUndo)
    manager.undo()
    XCTAssertTrue(manager.canRedo)
    manager.redo()
    manager.undo()
    await history.waitForPending()
    XCTAssertEqual(applied, [true, false, true])
  }
}
