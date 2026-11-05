import XCTest

@testable import HQ

/// The pages RootView keeps stay for one signed-in person and go the moment
/// that person signs out or someone else signs in.
@MainActor
final class PageMemoryTests: XCTestCase {
    private func filled(for personID: String) -> PageMemory {
        let pages = PageMemory()
        pages.keep(for: personID)
        pages.files.trail = [Folder(id: "garden", name: "Garden", parentFolderId: nil, systemSlug: nil, createdAt: "")]
        pages.files.hasLoaded = true
        return pages
    }

    private func models(_ pages: PageMemory) -> [AnyObject] {
        [pages.files]
    }

    func testTheFirstPersonKeepsPagesAlreadyReading() {
        let pages = PageMemory()
        let held = models(pages)
        pages.files.isLoading = true
        pages.keep(for: "ada")
        XCTAssertTrue(zip(models(pages), held).allSatisfy { $0 === $1 })
        XCTAssertEqual(pages.personID, "ada")
    }

    func testTheSamePersonKeepsEveryPage() {
        let pages = filled(for: "ada")
        let held = models(pages)
        pages.keep(for: "ada")
        XCTAssertTrue(zip(models(pages), held).allSatisfy { $0 === $1 })
        XCTAssertEqual(pages.files.trail.map(\.id), ["garden"])
    }

    func testSignOutClearsEveryPage() {
        let pages = filled(for: "ada")
        let held = models(pages)
        pages.keep(for: nil)
        assertCleared(pages, from: held)
    }

    func testAnotherPersonClearsEveryPage() {
        let pages = filled(for: "ada")
        let held = models(pages)
        pages.keep(for: "bo")
        assertCleared(pages, from: held)
        XCTAssertEqual(pages.personID, "bo")
    }

    func testAFreshReadRenamesTheTrailAndStopsAboveAGoneFolder() {
        func folder(_ id: String, _ name: String, in parent: String? = nil) -> Folder {
            Folder(id: id, name: name, parentFolderId: parent, systemSlug: nil, createdAt: "")
        }
        let files = FilesPage()
        files.trail = [folder("garden", "Garden"), folder("beds", "Beds", in: "garden"), folder("v2", "V2", in: "beds")]
        files.folders = [folder("garden", "Plots"), folder("v2", "V2", in: "beds")]
        files.keepTrail()
        XCTAssertEqual(files.trail.map(\.name), ["Plots"])
    }

    private func assertCleared(_ pages: PageMemory, from held: [AnyObject], line: UInt = #line) {
        XCTAssertTrue(zip(models(pages), held).allSatisfy { $0 !== $1 }, line: line)
        XCTAssertTrue(pages.files.trail.isEmpty && !pages.files.hasLoaded, line: line)
    }
}
