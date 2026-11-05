import SwiftUI

/// The team a project belongs to on the Projects home: Eng, Growth, Ops or
/// Support. It rides in the project's tags — no hub change — and the three
/// older planning categories still read as one of the four, so a project
/// nobody has re-filed lands where it did before (Product → Eng,
/// Marketing → Growth, Operations → Ops).
enum ProjectCategory: String, CaseIterable, Identifiable, Hashable {
    case eng = "Eng"
    case growth = "Growth"
    case ops = "Ops"
    case support = "Support"

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .eng: Tokens.Projects.Category.product
        case .growth: Tokens.Projects.Category.marketing
        case .ops: Tokens.Projects.Category.operations
        case .support: Tokens.Projects.Category.support
        }
    }

    /// The tags that file a project here, lowercased: the category's own
    /// name first, then the older names it absorbs.
    private var aliases: [String] {
        switch self {
        case .eng: ["eng", "engineering", "product"]
        case .growth: ["growth", "marketing"]
        case .ops: ["ops", "operations"]
        case .support: ["support", "customer support"]
        }
    }

    /// Every category a project is filed under, in the chips' order — a
    /// project can sit in several. Empty when nothing claims it.
    static func of(_ project: Project) -> [ProjectCategory] {
        let tags = project.effectiveTags.map { $0.lowercased() }
        return allCases.filter { category in tags.contains { category.aliases.contains($0) } }
    }

    /// Whether a tag is a category name, so a row does not repeat the
    /// section it sits under.
    static func isCategoryTag(_ tag: String) -> Bool {
        allCases.contains { $0.aliases.contains(tag.lowercased()) }
    }

    /// A project's tags filed under exactly these categories: every
    /// category tag, old names included, comes out and the new set goes in
    /// first under its own names, so "Product" becomes "Eng" on the way.
    static func tags(_ project: Project, setting categories: Set<ProjectCategory>) -> [String] {
        let rest = project.effectiveTags.filter { !isCategoryTag($0) }
        return allCases.filter(categories.contains).map(\.rawValue) + rest
    }

    /// A project's tags with one category turned on or off, from the
    /// project as it stands.
    static func tags(_ project: Project, turning category: Self, on: Bool) -> [String] {
        let current = Set(of(project))
        return tags(project, setting: on ? current.union([category]) : current.subtracting([category]))
    }
}

/// A project's tags as one comma-separated field: the board's "…" and the
/// home list's right-click both open it. Categories are tags too, so they
/// show here and can be typed.
struct ProjectTagsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let project: Project
    let actions: ProjectsActions
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Tags for \(project.name)").font(.headline)
            Text("Categories are tags too: \(ProjectCategory.allCases.map(\.rawValue).joined(separator: ", ")). Add any others to group related work.")
                .foregroundStyle(.secondary)
            TextField("Tags, separated by commas", text: $text).textFieldStyle(.roundedBorder).onSubmit(save)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save", action: save).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(idealWidth: 420)
        .onAppear { text = project.effectiveTags.joined(separator: ", ") }
    }

    private func save() {
        let tags = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let id = project.id
        ProjectsProjectWrite.save(
            tags, close: { dismiss() }, run: actions.run,
            send: { try await $0.setProjectTags(id: id, tags: $1) }, apply: actions.applyProject)
    }
}
