import Foundation

/// The project catalog as the Projects home shows it, worked out once.
///
/// The home's body used to recompute the filtered, localized-sorted list from
/// scratch about eleven times per pass (once for each chip's count and again
/// for every section), and it runs on every search keystroke and every
/// tasks/projects frame. Build one of these at the top of the body and hand
/// it to the chips and the list.
struct ProjectsHomeListing {
    typealias Section = (category: ProjectCategory?, projects: [Project])

    /// Everything the search, activity and tag filters let through, before
    /// the category chips narrow it, by name.
    let matching: [Project]
    /// `matching`, narrowed to the chosen category chip.
    let projects: [Project]
    /// The list's sections, in the chips' order, "Other" last; a project in
    /// several categories shows in each, and an empty section is left out.
    let sections: [Section]
    /// How many `matching` projects each category chip holds.
    let counts: [ProjectCategory: Int]
    /// Every tag on any project, for the tag filter.
    let tags: [String]

    init(all: [Project], scope: String, tag: String, search: String, category: String) {
        // Objectives are never in the project catalog.
        tags = Array(Set(all.filter { !$0.isObjective }.flatMap(\.effectiveTags))).sorted()
        // Each project's categories are read once, not once per chip and section.
        let filed: [(project: Project, categories: [ProjectCategory])] = all
            .filter { project in
                !project.isObjective && project.archivedAt == nil
                    && (scope == "All" || (project.isActive && project.activityTitle == scope))
                    && (tag == "All tags" || project.effectiveTags.contains(tag))
                    && (search.isEmpty
                        || ([project.name] + project.effectiveTags).contains { $0.localizedCaseInsensitiveContains(search) })
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { ($0, ProjectCategory.of($0)) }
        matching = filed.map(\.project)

        var counts: [ProjectCategory: Int] = [:]
        for entry in filed { for category in entry.categories { counts[category, default: 0] += 1 } }
        self.counts = counts

        let narrowed = category == "All"
            ? filed
            : filed.filter { entry in entry.categories.contains { $0.rawValue == category } }
        projects = narrowed.map(\.project)

        let chosen = ProjectCategory.allCases.filter { category == "All" || $0.rawValue == category }
        var built: [Section] = chosen.map { key in
            (key, narrowed.filter { $0.categories.contains(key) }.map(\.project))
        }
        if category == "All" {
            built.append((nil, narrowed.filter { $0.categories.isEmpty }.map(\.project)))
        }
        sections = built.filter { !$0.projects.isEmpty }
    }
}
