import SwiftUI

// The Meetings pin: Quick Call up top, then what's live, what's on the
// calendar, and what already happened — grouped cards in the shared design
// language. Joining goes through the green room, never straight into a
// live mic.
struct MeetingsView: View {
    @Environment(AppStore.self) private var store
    @State private var sheet: Sheet?

    enum Sheet: Identifiable {
        case create
        case greenRoom(GreenRoomTarget)
        case record(Call)
        case invitees(Meeting)

        var id: String {
            switch self {
            case .create: return "create"
            case .greenRoom(let target): return target.id
            case .record(let call): return "record-\(call.id)"
            case .invitees(let meeting): return "invitees-\(meeting.id)"
            }
        }
    }

    private var past: [Call] {
        store.calls.filter { !$0.isLive }
    }

    private var liveNamedMeetings: [Call] {
        store.liveMeetings.filter { $0.meetingId != nil }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Space.x5) {
                PageHeader(title: "Meetings") {
                    Button {
                        sheet = .create
                    } label: {
                        Label("New Meeting", systemImage: "plus")
                    }
                    .buttonStyle(TintedCapsuleButtonStyle(tint: Tokens.Palette.accent))
                    .disabled(store.activeCallId != nil)
                }
                if let error = store.callError {
                    ErrorBanner(text: error)
                }
                quickCallCard
                if !liveNamedMeetings.isEmpty {
                    happeningNow
                }
                upNext
                if !past.isEmpty {
                    previous
                }
            }
            .padding(.horizontal, Tokens.Space.x5)
            .padding(.vertical, Tokens.Space.x5)
            .frame(maxWidth: Tokens.Layout.pageContentWidth)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Meetings")
        // The 28pt page title carries the name; a toolbar twin above it
        // would say it twice.
        .toolbar(removing: .title)
        .background(Tokens.Palette.surface)
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .create:
                NewMeetingSheet { meeting in
                    self.sheet = .greenRoom(GreenRoomTarget(
                        conversationId: nil, kind: "meeting",
                        title: meeting.title, meetingId: meeting.id
                    ))
                }
            case .greenRoom(let target):
                GreenRoomView(
                    title: target.title, kind: target.kind,
                    conversationId: target.conversationId, meetingId: target.meetingId
                )
            case .record(let call):
                CallRecordView(call: call)
            case .invitees(let meeting):
                EditInviteesSheet(meeting: meeting)
            }
        }
    }

    private var quickCallCard: some View {
        HStack(spacing: Tokens.Space.x4) {
            IconTile(symbol: "video.fill", style: .tinted(Tokens.Palette.live), size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text("Quick Call")
                    .font(Tokens.Typography.cardTitle)
                    .foregroundStyle(Tokens.Palette.ink)
                Text("Start an instant meeting — it gets its own thread")
                    .font(Tokens.Typography.meta)
                    .foregroundStyle(Tokens.Palette.inkSecondary)
            }
            Spacer(minLength: Tokens.Space.x3)
            Button("Start") {
                sheet = .greenRoom(GreenRoomTarget(
                    conversationId: nil, kind: "meeting", title: "Quick Call"
                ))
            }
            .buttonStyle(TintedCapsuleButtonStyle(tint: Tokens.Palette.live))
            .disabled(store.activeCallId != nil)
        }
        .padding(Tokens.Space.x4)
        .hqCard()
    }

    private var happeningNow: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x2) {
            SectionLabel("Happening now")
            ForEach(liveNamedMeetings) { call in
                LiveMeetingCard(call: call) {
                    sheet = .greenRoom(GreenRoomTarget(
                        conversationId: nil, kind: "meeting",
                        title: call.title ?? "Meeting", meetingId: call.meetingId
                    ))
                }
            }
        }
    }

    private var upNext: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x2) {
            SectionLabel("Up next")
            VStack(spacing: 0) {
                if store.upcomingMeetings.isEmpty {
                    EmptyStateText("Nothing on the calendar yet.")
                } else {
                    // Everyone sees every meeting; yours come first.
                    let ordered = store.sortedUpcomingMeetings
                    ForEach(ordered) { meeting in
                        ScheduledMeetingRow(
                            meeting: meeting,
                            onJoin: {
                                sheet = .greenRoom(GreenRoomTarget(
                                    conversationId: nil, kind: "meeting",
                                    title: meeting.title, meetingId: meeting.id
                                ))
                            },
                            onEditInvitees: { sheet = .invitees(meeting) }
                        )
                        if meeting.id != ordered.last?.id {
                            RowDivider(inset: 66)
                        }
                    }
                }
            }
            .hqCard()
        }
    }

    private var previous: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x2) {
            SectionLabel("Previous")
            VStack(spacing: 0) {
                let shown = Array(past.prefix(20))
                ForEach(shown) { call in
                    PastMeetingRow(call: call) { sheet = .record(call) }
                    if call.id != shown.last?.id {
                        RowDivider(inset: 60)
                    }
                }
            }
            .hqCard()
        }
    }
}

/// The call-error strip, in the danger tint rather than a bare label.
private struct ErrorBanner: View {
    let text: String

    var body: some View {
        HStack(spacing: Tokens.Space.x2) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(Tokens.Typography.meta)
            Text(text)
                .font(Tokens.Typography.meta)
        }
        .foregroundStyle(Tokens.Palette.danger)
        .padding(.horizontal, Tokens.Space.x3)
        .padding(.vertical, Tokens.Space.x2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Tokens.Palette.danger.opacity(0.10),
            in: RoundedRectangle(cornerRadius: Tokens.Radius.chip, style: .continuous)
        )
    }
}

struct GreenRoomTarget: Identifiable {
    let conversationId: String?
    let kind: String
    let title: String
    var meetingId: String?

    var id: String { "\(kind)-\(meetingId ?? conversationId ?? "company")" }
}

// A named meeting that's live right now: who's in it, and a Join.
private struct LiveMeetingCard: View {
    @Environment(AppStore.self) private var store
    let call: Call
    let onJoin: () -> Void

    private var subtitle: String {
        let count = call.presentParticipants.count
        return count == 1 ? "1 person is here" : "\(count) people are here"
    }

    var body: some View {
        HStack(spacing: Tokens.Space.x4) {
            IconTile(symbol: "video.fill", style: .tinted(Tokens.Palette.live), size: 40)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: Tokens.Space.x2) {
                    Text(call.title ?? "Meeting")
                        .font(Tokens.Typography.cardTitle)
                        .foregroundStyle(Tokens.Palette.ink)
                    LiveBadge()
                }
                Text(subtitle)
                    .font(Tokens.Typography.meta)
                    .foregroundStyle(Tokens.Palette.inkSecondary)
            }
            Spacer(minLength: Tokens.Space.x3)
            HStack(spacing: -6) {
                ForEach(call.presentParticipants.prefix(5)) { participant in
                    AvatarView(name: store.people[participant.personId]?.name ?? "?", size: 24)
                        .overlay(Circle().strokeBorder(Tokens.Palette.surfaceInput, lineWidth: 1.5))
                }
            }
            Button("Join", action: onJoin)
                .buttonStyle(TintedCapsuleButtonStyle(tint: Tokens.Palette.live))
                .disabled(store.activeCallId != nil)
        }
        .padding(Tokens.Space.x4)
        .hqCard()
    }
}

// An upcoming meeting: the calendar lozenge, when, whose, and a Join that
// opens the room early. Canceling belongs to the creator or an admin.
private struct ScheduledMeetingRow: View {
    @Environment(AppStore.self) private var store
    let meeting: Meeting
    let onJoin: () -> Void
    let onEditInvitees: () -> Void

    private var whenLabel: String {
        guard let date = meeting.scheduledDate else { return "Open room" }
        if Calendar.current.isDateInToday(date) {
            return "Today at \(date.formatted(date: .omitted, time: .shortened))"
        }
        if Calendar.current.isDateInTomorrow(date) {
            return "Tomorrow at \(date.formatted(date: .omitted, time: .shortened))"
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private var canCancel: Bool {
        meeting.createdByPersonId == store.me?.id || store.me?.isAdmin == true
    }

    /// The second line: when it is, whether it repeats, and whose it is.
    /// The concrete date already carries the time, so the cadence drops its
    /// own " at HH:MM" rather than saying 10:45 twice in one line.
    private var subtitle: String {
        let who = store.people[meeting.createdByPersonId]?.name ?? "Someone"
        guard let cadence = meeting.recurrence else { return "\(whenLabel) · \(who)" }
        let trimmed = meeting.scheduledDate == nil
            ? cadence
            : cadence.replacingOccurrences(
                of: #" at \d{1,2}:\d{2}$"#, with: "", options: .regularExpression
            )
        return "\(whenLabel) · \(trimmed) · \(who)"
    }

    var body: some View {
        HStack(spacing: Tokens.Space.x3) {
            CalendarDateTile(date: meeting.scheduledDate)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Tokens.Space.x2) {
                    Text(meeting.title)
                        .font(Tokens.Typography.rowEmphasis)
                        .foregroundStyle(Tokens.Palette.ink)
                    if meeting.isRecurring {
                        Image(systemName: "repeat")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Tokens.Palette.inkTertiary)
                            .help(meeting.recurrence ?? "Repeats")
                    }
                }
                Text(subtitle)
                    .font(Tokens.Typography.meta)
                    .foregroundStyle(Tokens.Palette.inkSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Tokens.Space.x3)
            if !meeting.inviteePersonIds.isEmpty {
                InviteeFacepile(personIds: meeting.inviteePersonIds)
            }
            Button("Join", action: onJoin)
                .buttonStyle(QuietCapsuleButtonStyle(height: Tokens.Layout.controlHeightSmall))
                .disabled(store.activeCallId != nil)
        }
        .padding(.horizontal, Tokens.Space.x4)
        .padding(.vertical, Tokens.Space.x3)
        .opacity(store.isInvited(to: meeting) ? 1 : 0.62)
        .contextMenu {
            if canCancel {
                Button("Edit Invitees…") { onEditInvitees() }
                Divider()
                // On a repeating meeting these are two different acts, and
                // the wording has to make that unmistakable before the click.
                Button(
                    meeting.isRecurring ? "Skip This Occurrence" : "Cancel Meeting",
                    role: .destructive
                ) {
                    Task { await store.cancelMeeting(meeting.id) }
                }
                if let seriesId = meeting.seriesId {
                    Button("End Recurring Meeting", role: .destructive) {
                        Task { await store.cancelMeetingSeries(seriesId) }
                    }
                }
            }
        }
    }
}

// A finished call opens its record: summary, transcript, and the audio on
// file.
private struct PastMeetingRow: View {
    @Environment(AppStore.self) private var store
    let call: Call
    let onOpen: () -> Void
    @State private var isHovering = false

    private var names: String {
        let people = call.participants.compactMap { store.people[$0.personId]?.name }
        return people.isEmpty ? "No one joined" : people.joined(separator: ", ")
    }

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: Tokens.Space.x3) {
                IconTile(symbol: "video.fill", style: .neutral, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(call.title ?? "Meeting")
                        .font(Tokens.Typography.row)
                        .foregroundStyle(Tokens.Palette.ink)
                    Text(names)
                        .font(Tokens.Typography.meta)
                        .foregroundStyle(Tokens.Palette.inkTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: Tokens.Space.x3)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(call.startedDate.formatted(date: .abbreviated, time: .shortened))
                        .font(Tokens.Typography.meta)
                        .foregroundStyle(Tokens.Palette.inkTertiary)
                    Text(Duration.seconds(call.duration).formatted(.units(allowed: [.hours, .minutes], width: .narrow)))
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(Tokens.Palette.inkTertiary)
                }
                Image(systemName: "chevron.right")
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.inkTertiary)
            }
            .padding(.horizontal, Tokens.Space.x4)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
            .background(isHovering ? Tokens.Palette.surfaceHover : .clear)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

// Name it, then either walk straight into the green room or put it on the
// calendar for everyone.
private struct NewMeetingSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let onStartNow: (Meeting) -> Void
    @State private var title = ""
    @State private var isScheduled = false
    @State private var scheduledDate = Calendar.current.nextDate(
        after: Date(), matching: DateComponents(minute: 0), matchingPolicy: .nextTime
    ) ?? Date().addingTimeInterval(3600)
    @State private var isCreating = false
    @State private var repeats = MeetingRepeat.never
    @State private var invited: Set<String> = []

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A cadence needs a first occurrence to count from, so choosing one
    /// implies scheduling. The hub refuses the combination anyway; the sheet
    /// should never let someone reach that refusal.
    private var isSchedulingRequired: Bool { repeats != .never }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x4) {
            Text("New Meeting")
                .font(Tokens.Typography.sheetTitle)
                .foregroundStyle(Tokens.Palette.ink)
            TextField("What's it about?", text: $title)
                .textFieldStyle(.plain)
                .font(Tokens.Typography.row)
                .padding(.horizontal, Tokens.Space.x3)
                .padding(.vertical, 9)
                .hqComposerGlass(in: RoundedRectangle(cornerRadius: 16), interactive: true)
            Picker("When", selection: $isScheduled) {
                Text("Now").tag(false)
                Text("Later").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(isSchedulingRequired)
            if isScheduled || isSchedulingRequired {
                LabeledControl("Starts") {
                    // fixedSize is the whole fix for the clipped date: SwiftUI
                    // was handing this control less than its intrinsic width,
                    // so "6:00 PM" ran under the stepper and out of its own
                    // bezel. It takes its natural size now and the sheet is
                    // wide enough to hold it.
                    //
                    // The control already IS a text field — the stepper-field
                    // style takes typed digits per component — so it needs no
                    // added chrome; wrapping it in one only drew a second box
                    // around its native bezel.
                    //
                    // Unbounded on purpose, which is a separate matter from
                    // typing (measured: a lower bound changes nothing about
                    // what the field accepts). It exists so a cadence can be
                    // anchored to a date already past — "every day at 10:00"
                    // set from last Monday — which the hub handles by starting
                    // the series at its next future occurrence.
                    DatePicker(
                        "",
                        selection: $scheduledDate,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .labelsHidden()
                    .datePickerStyle(.stepperField)
                    // No font override: AppKit sizes this control in its own
                    // font, so overriding the font without re-measuring is
                    // what pushed the text under its bezel.
                    .fixedSize()
                }
            }
            LabeledControl("Repeat") {
                Picker("", selection: $repeats) {
                    ForEach(MeetingRepeat.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .labelsHidden()
                .font(Tokens.Typography.row)
                .fixedSize()
            }
            .onChange(of: repeats) { _, value in
                // Repeating from "Now" has no anchor to count from.
                if value != .never { isScheduled = true }
            }
            VStack(alignment: .leading, spacing: Tokens.Space.x2) {
                SectionLabel("Invite")
                ScrollView {
                    MeetingInvitePicker(selected: $invited)
                }
                .frame(maxHeight: 180)
            }
            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(QuietCapsuleButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(createLabel) { create() }
                    .buttonStyle(ActionCapsuleButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedTitle.isEmpty || isCreating)
            }
        }
        .padding(Tokens.Space.x5)
        .frame(width: 470)
    }

    private var createLabel: String {
        if isCreating { return "Creating…" }
        return isScheduled || isSchedulingRequired ? "Schedule" : "Start"
    }

    private func create() {
        isCreating = true
        let willSchedule = isScheduled || isSchedulingRequired
        Task {
            let meeting = await store.createMeeting(
                title: trimmedTitle,
                scheduledAt: willSchedule ? scheduledDate : nil,
                inviteePersonIds: Array(invited),
                recurrence: repeats.body
            )
            isCreating = false
            guard let meeting else {
                dismiss()
                return
            }
            if willSchedule {
                dismiss()
            } else {
                // Swap this sheet for the green room rather than stacking.
                onStartNow(meeting)
            }
        }
    }
}
