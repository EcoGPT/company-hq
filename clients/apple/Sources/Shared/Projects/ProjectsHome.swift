import SwiftUI

/// The Tasks tab's home: a Projects | Agents switch in the bar. Projects is the
/// catalog of every project (`ProjectsCatalogContent`); Agents is everyone's agents
/// grouped by person, under a search field. The last choice is remembered.
struct ProjectsHome: View {
    /// What the home shows. The raw value is what is stored.
    private enum Mode: String {
        case projects, agents
    }

    @Environment(AppStore.self) private var store
    let actions: ProjectsActions
    let live: LiveThreadsStore
    @AppStorage("hq.tasks.mode") private var mode = Mode.projects.rawValue
    @State private var search = ""

    private static let modes: [TextSegmentedControl.Option] = [
        .init(id: Mode.projects.rawValue, title: "Projects"),
        .init(id: Mode.agents.rawValue, title: "Agents"),
    ]

    /// The overflow menu's items: My tasks, New project.
    @ViewBuilder
    private var workspaceActions: some View {
        Button(
            "My tasks · \(ProjectsModel.myOpenCount(tasks: store.tasks, projects: store.projects, owner: store.me?.id ?? ""))"
        ) { actions.open(.mine) }
        Divider()
        Button("New project", systemImage: "plus") { actions.newProject(nil) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                #if os(iOS)
                    BarCircleButton(symbol: "chevron.left", label: "Back", action: actions.back)
                #endif
                Text("Tasks").font(Tokens.Projects.boardName).lineLimit(1).accessibilityAddTraits(.isHeader)
                TextSegmentedControl(options: Self.modes, selection: $mode)
                    .frame(maxWidth: 200)
                    .accessibilityLabel("Tasks view")
                Spacer(minLength: 0)
                #if os(iOS)
                    // The phone draws the "…" as the boards' glass circle, at
                    // the 44pt touch size, so every bar's menu reads the same.
                    BarMenu(label: "Workspace actions") { workspaceActions }
                #else
                    Menu { workspaceActions } label: { Image(systemName: "ellipsis").frame(width: 28, height: 28) }
                        .fixedSize().accessibilityLabel("Workspace actions")
                #endif
            }.padding(.horizontal, Tokens.Projects.liveGutter).frame(height: Tokens.Projects.boardBarHeight)
            if mode == Mode.agents.rawValue {
                agentsHome
            } else {
                ProjectsCatalogContent(actions: actions)
            }
        }
    }

    /// The Agents list under its search field.
    @ViewBuilder private var agentsHome: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Find an agent", text: $search).textFieldStyle(.plain)
        }.padding(.horizontal, Tokens.Projects.liveGutter).padding(.bottom, 8)
        LiveThreadsView(live: live, actions: actions, search: search, systemProjectIds: systemProjectIds)
    }

    /// The projects the server keeps for itself are never drawn as a place work is aimed at.
    private var systemProjectIds: Set<String> {
        Set(store.projects.filter(\.isSystem).map(\.id))
    }
}
