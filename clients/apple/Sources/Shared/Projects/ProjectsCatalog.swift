import SwiftUI

/// The catalog of projects — search, the Activity and Tag filters, category
/// chips, the rows and their context menu. It is the Tasks home's Projects mode.
struct ProjectsCatalogContent: View {
    @Environment(AppStore.self) private var store
    let actions: ProjectsActions
    @State private var scope = "Active"
    @State private var search = ""
    @State private var tag = "All tags"
    @State private var category = "All"
    @State private var tagging: Project?

    private func makeListing() -> ProjectsHomeListing {
        ProjectsHomeListing(all: store.projects, scope: scope, tag: tag, search: search, category: category)
    }

    private func chips(_ listing: ProjectsHomeListing) -> [FilterChipRow.Option] {
        [.init(id: "All", title: "All · \(listing.matching.count)")]
            + ProjectCategory.allCases.map { category in
                .init(id: category.rawValue, title: "\(category.rawValue) · \(listing.counts[category] ?? 0)")
            }
    }

    var body: some View {
        let listing = makeListing()
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find a project", text: $search).textFieldStyle(.plain)
                Menu {
                    Picker("Activity", selection: $scope) {
                        ForEach(["Active", "Maintained", "Paused", "All"], id: \.self) { Text($0) }
                    }
                    Divider()
                    Picker("Tag", selection: $tag) {
                        Text("All tags").tag("All tags")
                        ForEach(listing.tags, id: \.self) { Text($0) }
                    }
                } label: { Text(tag == "All tags" ? scope : "\(scope) · \(tag)").font(.callout).projectsPhoneTarget() }
                    .fixedSize().accessibilityLabel("Filter projects")
            }.padding(.horizontal, Tokens.Projects.liveGutter).padding(.bottom, 8)
            FilterChipRow(options: chips(listing), selection: $category, inset: Tokens.Projects.liveGutter).padding(.bottom, 8)
            projectList(listing)
        }
        .sheet(item: $tagging) { ProjectTagsSheet(project: $0, actions: actions) }
    }

    private func projectList(_ listing: ProjectsHomeListing) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                ForEach(listing.sections, id: \.category) { section in
                    Section {
                        ForEach(section.projects) { row($0, in: section.category) }
                    } header: {
                        HStack(spacing: 8) {
                            CategorySquare(color: section.category?.color ?? Tokens.Projects.Category.none)
                            Text(section.category?.rawValue ?? "Other").font(.system(size: 13, weight: .semibold))
                            Text("\(section.projects.count)").font(.system(size: 13)).foregroundStyle(.secondary)
                        }
                        .padding(.top, 18).padding(.bottom, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Tokens.Palette.surface)
                        .accessibilityAddTraits(.isHeader)
                    }
                }
                if listing.projects.isEmpty {
                    ContentUnavailableView("No projects here", systemImage: "folder", description: Text("Try another category or activity, or clear your search."))
                }
            }.padding(.horizontal, Tokens.Projects.liveGutter)
        }
        .clipped()
    }

    private func row(_ project: Project, in section: ProjectCategory?) -> some View {
        let color = section?.color ?? Tokens.Projects.Category.none
        // The other categories it is also in, then its plain tags.
        let also = ProjectCategory.of(project).filter { $0 != section }.map { "Also \($0.rawValue)" }
        return VStack(spacing: 0) {
            Button { actions.open(.project(project.id)) } label: {
                HStack(spacing: 12) {
                    Image(systemName: "folder").font(.system(size: 18)).foregroundStyle(color).frame(width: 28)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(project.name).font(.system(size: 15, weight: .medium)).lineLimit(2)
                        Text((["\(project.openTasks) open tasks"] + also + project.effectiveTags.filter { !ProjectCategory.isCategoryTag($0) }).joined(separator: " · "))
                            .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 16).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .contextMenu { categoryMenu(project) }
            Divider().padding(.leading, 40)
        }
    }

    /// Files a project under categories: each one toggles, so a project can
    /// sit in several.
    @ViewBuilder
    private func categoryMenu(_ project: Project) -> some View {
        let current = Set(ProjectCategory.of(project))
        Menu("Categories") {
            ForEach(ProjectCategory.allCases) { category in
                Toggle(category.rawValue, isOn: Binding(
                    get: { current.contains(category) },
                    set: { on in setCategories(project) { ProjectCategory.tags($0, turning: category, on: on) } }))
            }
            Divider()
            Button("Clear") { setCategories(project) { ProjectCategory.tags($0, setting: []) } }.disabled(current.isEmpty)
        }
        Button("Edit Tags…") { tagging = project }
    }

    /// The tags are built when the write runs, from the board as the store
    /// holds it then, so a second toggle before the hub answers keeps the first.
    private func setCategories(_ project: Project, _ change: @escaping (Project) -> [String]) {
        actions.run { client in
            try await ProjectsProjectWrite.tags(
                of: project, change, latest: actions.latestProject,
                send: { try await client.setProjectTags(id: project.id, tags: $0) },
                apply: actions.applyProject)
        }
    }
}
