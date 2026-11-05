import SwiftUI

// The two things a meeting can say beyond its title: how often it happens,
// and who it is for. Compiled into BOTH clients — hence its home here rather
// than under Views/, which the iOS target excludes — so the Mac sheet and the
// phone's form cannot drift apart in vocabulary or in what they send.

/// The cadences the pickers offer, in the order they read. `weekly` and
/// `biweekly` repeat on the first occurrence's own weekday — the hub derives
/// it from the anchor, so neither client has to send one.
enum MeetingRepeat: String, CaseIterable, Identifiable, Sendable {
    case never
    case daily
    case weekdays
    case weekly
    case biweekly
    case monthly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .never: return "Does not repeat"
        case .daily: return "Every day"
        case .weekdays: return "Every weekday"
        case .weekly: return "Every week"
        case .biweekly: return "Every 2 weeks"
        case .monthly: return "Every month"
        }
    }

    /// A short form for the compact pickers, where the row already says
    /// "Repeat".
    var shortLabel: String {
        self == .never ? "Never" : label.replacingOccurrences(of: "Every ", with: "Every ")
    }

    /// The wire rule, carrying the device's own timezone so the meeting keeps
    /// its wall clock when the clocks change. Nil for a one-off.
    var body: HQClient.RecurrenceBody? {
        guard self != .never else { return nil }
        return HQClient.RecurrenceBody(
            freq: rawValue,
            timezone: TimeZone.current.identifier,
            weekdays: []
        )
    }
}

/// A form row: a left-aligned label with its control on the right, so the
/// sheet's rows line up with each other instead of each control finding its
/// own edge.
struct LabeledControl<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack(spacing: Tokens.Space.x3) {
            Text(label)
                .font(Tokens.Typography.row)
                .foregroundStyle(Tokens.Palette.inkSecondary)
            Spacer(minLength: Tokens.Space.x2)
            content
        }
    }
}

/// Who is invited, as a scrollable roster of teammates. The creator is not
/// listed: they are always in it, and offering to remove them would be a lie.
struct MeetingInvitePicker: View {
    @Environment(AppStore.self) private var store
    @Binding var selected: Set<String>

    private var roster: [Person] {
        store.roster
            .filter { $0.id != store.me?.id }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(roster) { person in
                Button {
                    if selected.contains(person.id) {
                        selected.remove(person.id)
                    } else {
                        selected.insert(person.id)
                    }
                } label: {
                    HStack(spacing: Tokens.Space.x3) {
                        AvatarView(name: person.name, size: 28)
                        Text(person.name)
                            .font(Tokens.Typography.row)
                            .foregroundStyle(Tokens.Palette.ink)
                        Spacer(minLength: Tokens.Space.x2)
                        Image(
                            systemName: selected.contains(person.id)
                                ? "checkmark.circle.fill" : "circle"
                        )
                        .foregroundStyle(
                            selected.contains(person.id)
                                ? Tokens.Palette.accent : Tokens.Palette.inkTertiary
                        )
                    }
                    .contentShape(Rectangle())
                    .padding(.vertical, 5)
                }
                .buttonStyle(.plain)
            }
            if roster.isEmpty {
                EmptyStateText("No one else has enrolled yet.")
            }
        }
    }
}

/// The invited, as overlapping avatars — the row's answer to "is this mine?"
/// without spending a line of text on it.
struct InviteeFacepile: View {
    @Environment(AppStore.self) private var store
    let personIds: [String]
    var size: CGFloat = 20
    var limit = 4

    private var live: [Person] { Self.livePeople(personIds, people: store.people) }
    private var shown: [Person] { Array(live.prefix(limit)) }

    /// Invitees still on the roster, in order. Removed or unknown ids drop
    /// out before the cap, so the "+N" counts only people who are here.
    static func livePeople(_ ids: [String], people: [String: Person]) -> [Person] {
        ids.compactMap { people[$0] }.filter { !$0.isRemoved }
    }

    var body: some View {
        HStack(spacing: -size / 3.5) {
            ForEach(shown) { person in
                AvatarView(name: person.name, size: size)
                    .overlay(Circle().strokeBorder(Tokens.Palette.surface, lineWidth: 1.5))
            }
            if live.count > shown.count {
                Text("+\(live.count - shown.count)")
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.inkSecondary)
                    .padding(.leading, size / 3.5 + 4)
            }
        }
    }
}

/// Editing the invite list of a meeting that already exists. On a repeating
/// meeting this is the list for every occurrence — they share one thread.
struct EditInviteesSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let meeting: Meeting
    @State private var selected: Set<String> = []
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x4) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Who's invited")
                    .font(Tokens.Typography.sheetTitle)
                    .foregroundStyle(Tokens.Palette.ink)
                Text(
                    meeting.isRecurring
                        ? "\(meeting.title) — applies to every occurrence"
                        : meeting.title
                )
                .font(Tokens.Typography.meta)
                .foregroundStyle(Tokens.Palette.inkSecondary)
            }
            ScrollView {
                MeetingInvitePicker(selected: $selected)
            }
            .frame(maxHeight: 280)
            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(QuietCapsuleButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(isSaving ? "Saving…" : "Save") {
                    isSaving = true
                    Task {
                        await store.setMeetingInvitees(meeting.id, personIds: Array(selected))
                        dismiss()
                    }
                }
                .buttonStyle(ActionCapsuleButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving)
            }
        }
        .padding(Tokens.Space.x5)
        #if os(macOS)
        .frame(width: 400)
        #endif
        .onAppear {
            // The creator is implicit on the wire; showing them as a
            // selectable row would invite an edit the hub refuses.
            selected = Set(meeting.inviteePersonIds.filter { $0 != meeting.createdByPersonId })
        }
    }
}
