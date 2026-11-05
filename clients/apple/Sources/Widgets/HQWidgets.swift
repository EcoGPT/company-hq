import SwiftUI
import WidgetKit

/// HQ for Mac's desktop widgets: one question each, drawn from one summary.
@main
struct HQWidgets: WidgetBundle {
    var body: some Widget {
        MyTasksWidget()
        BoardWidget()
    }
}

/// The configuration every HQ widget shares; only the view, the name and
/// the sizes differ.
struct HQWidgetConfiguration<Content: View>: WidgetConfiguration {
    let kind: String
    let name: LocalizedStringResource
    let description: LocalizedStringResource
    let families: [WidgetFamily]
    @ViewBuilder let content: (SummaryEntry, WidgetFamily) -> Content

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SummaryProvider()) { entry in
            FamilyReader { content(entry, $0) }.hqWidgetBackground()
        }
        .configurationDisplayName(name)
        .description(description)
        .supportedFamilies(families)
    }
}

/// Hands a view its size as a value, so the same view renders outside a
/// widget where the environment has no family.
struct FamilyReader<Content: View>: View {
    @Environment(\.widgetFamily) private var family
    @ViewBuilder var content: (WidgetFamily) -> Content

    var body: some View { content(family) }
}

/// The summary's view, or what to do when there is none.
struct SummaryContent<Content: View>: View {
    let entry: SummaryEntry
    @ViewBuilder var content: (WidgetSummary) -> Content

    var body: some View {
        if let summary = entry.summary {
            content(summary)
        } else if entry.isSignedIn {
            WidgetMessage(text: "Waiting for HQ.")
        } else {
            WidgetMessage(text: "Open HQ on this Mac and sign in.")
        }
    }
}

struct MyTasksWidget: Widget {
    var body: some WidgetConfiguration {
        HQWidgetConfiguration(
            kind: "\(WidgetIdentity.kindPrefix)my-tasks", name: "My Tasks",
            description: "Everything assigned to you, and what you are working on now.",
            families: [.systemSmall, .systemMedium, .systemLarge]
        ) { MyTasksView(entry: $0, family: $1) }
    }
}

struct BoardWidget: Widget {
    var body: some WidgetConfiguration {
        HQWidgetConfiguration(
            kind: "\(WidgetIdentity.kindPrefix)board", name: "My Tasks Board",
            description: "Your tasks as the app's board draws them: To do, In progress and Blocked.",
            families: [.systemExtraLarge]
        ) { entry, _ in BoardView(entry: entry) }
    }
}
