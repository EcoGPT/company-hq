import SwiftUI

struct PlanningDraft: Identifiable {
  let id = UUID()
  var parent: Project?
  var category: String
  var state: String
  var isStandalone = false
  var ownerId: String?
  var isProject: Bool { parent == nil && !isStandalone }
  static func personal(owner: String) -> Self {
    .init(category: "", state: "Next", isStandalone: true, ownerId: owner)
  }
  static func project(category: String, state: String) -> Self {
    .init(category: category, state: state)
  }
}

struct PlanningCreateSheet: View {
  @Environment(AppStore.self) private var store
  @Environment(\.dismiss) private var dismiss
  let draft: PlanningDraft
  @State private var title = ""
  @State private var description = ""
  @State private var owner = ""
  @State private var category = "Product"
  @State private var tagText = ""
  @State private var teams: Set<ProjectCategory> = []
  @State private var state = "Next"
  @State private var isSaving = false
  @State private var didCreate = false
  @State private var failure: String?

  var body: some View {
    VStack(alignment: .leading, spacing: Tokens.Space.x4) {
      // Projects hold tasks: a draft with a parent is a task in it,
      // one without is a project (an idea in the backlog).
      Text(
        draft.parent != nil
          ? "New task in \(draft.parent?.name ?? "project")"
          : draft.isStandalone ? "New task" : draft.state == "Backlog" ? "New idea" : "New project")
        .font(Tokens.Typography.sheetTitle)
      TextField("Title", text: $title).textFieldStyle(.roundedBorder).onSubmit { create() }
      TextField("Description", text: $description, axis: .vertical).textFieldStyle(.roundedBorder)
      if !draft.isProject || state != "Backlog" {
        Picker("Owner", selection: $owner) { ForEach(store.roster) { Text($0.name).tag($0.id) } }
      }
      if draft.isProject {
        HStack {
          Text("Categories")
          ForEach(ProjectCategory.allCases) { team in
            Toggle(team.rawValue, isOn: Binding(
              get: { teams.contains(team) },
              set: { if $0 { teams.insert(team) } else { teams.remove(team) } }))
              .toggleStyle(.button)
          }
        }
        TextField("Tags, separated by commas", text: $tagText).textFieldStyle(.roundedBorder)
        Picker("Activity", selection: $state) {
          Text("Active").tag("Now")
          Text("Maintained").tag("Next")
          Text("Paused").tag("Backlog")
        }
        if !similarProjects.isEmpty {
          Text("Existing projects: " + similarProjects.map(\.name).joined(separator: ", "))
            .font(.caption).foregroundStyle(.secondary)
        }
      }
      if let failure {
        Text(failure).font(Tokens.Typography.caption).foregroundStyle(Tokens.Palette.danger)
      }
      HStack {
        Button("Cancel") { dismiss() }.buttonStyle(PlanningButtonStyle()).keyboardShortcut(
          .cancelAction)
        Spacer()
        if isSaving { ProgressView().controlSize(.small) }
        Button("Create", action: create).buttonStyle(PlanningButtonStyle()).keyboardShortcut(
          .defaultAction
        ).disabled(!isValid)
      }
    }
    .padding(Tokens.Space.x5)
    #if os(macOS)
      .frame(width: 420)
    #else
      .presentationDetents([.medium, .large])
    #endif
    .disabled(isSaving)
    .interactiveDismissDisabled(isSaving)
    .onAppear {
      owner = draft.ownerId ?? store.defaultOwner(lead: draft.parent?.ownerPersonId) ?? ""
      category = draft.category
      state = draft.state
    }
  }
  private var similarProjects: [Project] {
    let query = title.trimmingCharacters(in: .whitespacesAndNewlines)
    return query.count < 3 ? [] : store.projects.filter { $0.isActive && !$0.isObjective && $0.name.localizedCaseInsensitiveContains(query) }
  }
  private var isValid: Bool {
    !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && title.count <= (draft.isProject ? 60 : 200)
      && description.count <= (draft.isProject ? 2000 : 8000) && !owner.isEmpty && !isSaving
  }
  private func create() {
    guard isValid, let client = store.client else { return }
    isSaving = true
    failure = nil
    Task { @MainActor in
      defer { isSaving = false }
      do {
        if !didCreate {
          if draft.isProject {
            _ = try await client.createPlanningProject(
              name: title, body: description.isEmpty ? nil : description, owner: owner,
              category: category, state: state,
              tags: ProjectCategory.allCases.filter(teams.contains).map(\.rawValue)
                + tagText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && !ProjectCategory.isCategoryTag($0) })
          } else {
            _ = try await client.createTask(
              title: title, body: description.isEmpty ? nil : description, ownerPersonId: owner,
              projectId: draft.parent?.id)
          }
          didCreate = true
        }
        try await store.refreshPlanning()
        dismiss()
      } catch {
        failure =
          (error as? PlanningError)?.errorDescription ?? "Couldn’t create. Please try again."
      }
    }
  }
}
