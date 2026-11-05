import XCTest

#if !LISTING_HEADLESS
@testable import HQ
#endif

final class ProjectsHomeListingTests: XCTestCase {
    private func project(_ name: String, tags: [String]? = nil, kind: String? = nil,
                         state: String = "Now") -> Project {
        var project = Project(
            id: name.lowercased(), name: name, body: nil, ownerPersonId: "lead", ownerName: "Lead",
            status: "active", openTasks: 1, createdAt: "2026-09-22T12:00:00Z", closedAt: nil)
        project.tags = tags
        project.planningState = state
        project.kind = kind
        return project
    }

    func testFilteredListIsLocalizedSorted() throws {
        let all = [
            project("Zeta", tags: ["growth"]), project("alpha", tags: ["eng"]),
            project("Item 10", tags: ["ops"]), project("Item 2", tags: ["ops"]),
        ]
        let listing = ProjectsHomeListing(all: all, scope: "Active", tag: "All tags", search: "", category: "All")
        XCTAssertEqual(listing.matching.map(\.name), ["alpha", "Item 2", "Item 10", "Zeta"])
    }

    func testObjectivesNeverAppearInTheCatalogItsCountsOrItsTags() throws {
        let all = [
            project("Billing", tags: ["eng"]), project("Launch the campus program", tags: ["growth"], kind: "objective"),
            project("Brand refresh", tags: ["marketing", "brand"], kind: "objective"),
        ]
        let listing = ProjectsHomeListing(all: all, scope: "All", tag: "All tags", search: "", category: "All")
        XCTAssertEqual(listing.matching.map(\.name), ["Billing"])
        XCTAssertEqual(listing.projects.map(\.name), ["Billing"])
        XCTAssertEqual(listing.counts[.growth] ?? 0, 0)
        XCTAssertEqual(listing.tags, ["eng"])
        XCTAssertEqual(listing.sections.flatMap(\.projects).map(\.name), ["Billing"])
        XCTAssertTrue(all[1].isObjective)
    }

    func testChipCountsAndSectionsAgreeWithTheCategories() throws {
        let all = [
            project("A", tags: ["eng", "growth"]), project("B", tags: ["marketing"]),
            project("C", tags: ["customer support"]), project("D", tags: ["misc"]),
        ]
        let listing = ProjectsHomeListing(all: all, scope: "Active", tag: "All tags", search: "", category: "All")
        XCTAssertEqual(listing.counts[.eng], 1)
        XCTAssertEqual(listing.counts[.growth], 2, "marketing is the older name for growth")
        XCTAssertEqual(listing.counts[.support], 1)
        XCTAssertNil(listing.counts[.ops])
        // A project in several categories shows in each; unfiled ones land in Other, last.
        XCTAssertEqual(listing.sections.map { $0.category?.rawValue ?? "Other" }, ["Eng", "Growth", "Support", "Other"])
        XCTAssertEqual(listing.sections.first { $0.category == .growth }?.projects.map(\.name), ["A", "B"])
        XCTAssertEqual(listing.sections.last?.projects.map(\.name), ["D"])
    }

    func testChosenCategoryNarrowsTheListButNotTheChipCounts() throws {
        let all = [project("A", tags: ["eng"]), project("B", tags: ["ops"])]
        let listing = ProjectsHomeListing(all: all, scope: "Active", tag: "All tags", search: "", category: "Ops")
        XCTAssertEqual(listing.projects.map(\.name), ["B"])
        XCTAssertEqual(listing.matching.count, 2)
        XCTAssertEqual(listing.sections.map { $0.category }, [.ops])
    }

    func testSearchMatchesNameOrTagCaseInsensitively() throws {
        let all = [project("Billing", tags: ["eng"]), project("Hiring", tags: ["Ops"])]
        XCTAssertEqual(
            ProjectsHomeListing(all: all, scope: "Active", tag: "All tags", search: "BILL", category: "All")
                .matching.map(\.name), ["Billing"])
        XCTAssertEqual(
            ProjectsHomeListing(all: all, scope: "Active", tag: "All tags", search: "ops", category: "All")
                .matching.map(\.name), ["Hiring"])
    }

    func testActivityScopeAndTagFilter() throws {
        let all = [project("Now", tags: ["eng"]), project("Later", tags: ["eng"], state: "Backlog")]
        XCTAssertEqual(
            ProjectsHomeListing(all: all, scope: "Paused", tag: "All tags", search: "", category: "All")
                .matching.map(\.name), ["Later"])
        XCTAssertEqual(
            ProjectsHomeListing(all: all, scope: "All", tag: "eng", search: "", category: "All").matching.count, 2)
        XCTAssertEqual(
            ProjectsHomeListing(all: all, scope: "All", tag: "ops", search: "", category: "All").matching.count, 0)
        XCTAssertEqual(
            ProjectsHomeListing(all: all, scope: "All", tag: "All tags", search: "", category: "All").tags, ["eng"])
    }
}
