import SwiftUI

/// The meetings surface, in the Mac's own order: a Quick Call hero, what is
/// happening now, what is coming up, then what already happened.
struct MeetingsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.returnToActiveCall) private var returnToActiveCall
    @State private var greenRoom: GreenRoomRequest?
    @State private var isScheduling = false
    @State private var recordTarget: Call?
    @State private var invitees: Meeting?
    @State private var cancelRequest: MeetingCancelRequest?

    /// Every finished call the store is holding, the way the Mac lists them.
    /// The phone used to stop at twenty, which quietly hid a call the Mac
    /// could still open — the store's own window is the only cap either
    /// client should have.
    private var previousCalls: [Call] {
        store.calls.filter { !$0.isLive }
    }

    private var bannerText: String? { store.callError }

    var body: some View {
        List {
            Group {
                if let bannerText {
                    Section {
                        CallErrorBanner(text: bannerText)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }
                }
                Section {
                    Button {
                        greenRoom = GreenRoomRequest(meetingId: nil, title: "Quick Call")
                    } label: {
                        HStack(spacing: Tokens.Space.x3) {
                            IconTile(symbol: "video.fill", style: .tinted(Tokens.Palette.live), size: 44)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Quick Call")
                                    .font(Tokens.Typography.rowEmphasis)
                                    .foregroundStyle(Tokens.Palette.ink)
                                Text("Open a room and share the link")
                                    .font(Tokens.Typography.caption)
                                    .foregroundStyle(Tokens.Palette.inkTertiary)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(store.activeCallId != nil)
                }

                if !store.liveMeetings.isEmpty {
                    Section("Happening now") {
                        ForEach(store.liveMeetings) { call in
                            Button {
                                if call.id == store.activeCallId {
                                    returnToActiveCall()
                                    return
                                }
                                greenRoom = GreenRoomRequest(
                                    meetingId: call.meetingId, title: call.title ?? "Meeting"
                                )
                            } label: {
                                let layout = dynamicTypeSize.isAccessibilitySize
                                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                                    : AnyLayout(HStackLayout(spacing: Tokens.Space.x3))
                                layout {
                                    LiveBadge()
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(call.title ?? "Meeting")
                                            .font(Tokens.Typography.rowEmphasis)
                                            .foregroundStyle(Tokens.Palette.ink)
                                        Text(headcount(call))
                                            .font(Tokens.Typography.caption)
                                            .foregroundStyle(Tokens.Palette.inkTertiary)
                                    }
                                    Spacer(minLength: 0)
                                    Text(call.id == store.activeCallId ? "Return" : "Join")
                                        .font(Tokens.Typography.buttonSmall)
                                        .foregroundStyle(Tokens.Palette.accent)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Section("Up next") {
                    if store.upcomingMeetings.isEmpty {
                        EmptyStateText("Nothing scheduled.")
                    } else {
                        // Everyone sees every meeting; yours come first.
                        ForEach(store.sortedUpcomingMeetings) { meeting in
                            Button {
                                greenRoom = GreenRoomRequest(
                                    meetingId: meeting.id, title: meeting.title
                                )
                            } label: {
                                HStack(spacing: Tokens.Space.x3) {
                                    if let date = meeting.scheduledDate {
                                        CalendarDateTile(date: date)
                                    } else {
                                        IconTile(symbol: "person.2.fill", style: .neutral, size: 44)
                                    }
                                    VStack(alignment: .leading, spacing: 1) {
                                        HStack(spacing: Tokens.Space.x1) {
                                            Text(meeting.title)
                                                .font(Tokens.Typography.rowEmphasis)
                                                .foregroundStyle(Tokens.Palette.ink)
                                            if meeting.isRecurring {
                                                Image(systemName: "repeat")
                                                    .font(.system(size: 10, weight: .semibold))
                                                    .foregroundStyle(Tokens.Palette.inkTertiary)
                                            }
                                        }
                                        Text(scheduleLine(meeting))
                                            .font(Tokens.Typography.caption)
                                            .foregroundStyle(Tokens.Palette.inkTertiary)
                                    }
                                    Spacer(minLength: 0)
                                    if !meeting.inviteePersonIds.isEmpty {
                                        InviteeFacepile(personIds: meeting.inviteePersonIds, size: 18, limit: 3)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .opacity(store.isInvited(to: meeting) ? 1 : 0.62)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                // Only the creator or an admin may cancel or invite,
                                // as on the Mac. Each cancel asks first; the swipe
                                // never runs it.
                                if meeting.canBeCanceled(by: store.me) {
                                    // Two different acts on a repeating meeting, so
                                    // they get two different words.
                                    Button(role: .destructive) {
                                        cancelRequest = MeetingCancelRequest(
                                            meeting: meeting,
                                            scope: meeting.isRecurring ? .occurrence : .meeting
                                        )
                                    } label: {
                                        Label(
                                            meeting.isRecurring ? "Skip" : "Cancel",
                                            systemImage: meeting.isRecurring ? "forward.end" : "trash"
                                        )
                                    }
                                    if meeting.seriesId != nil {
                                        Button(role: .destructive) {
                                            cancelRequest = MeetingCancelRequest(meeting: meeting, scope: .series)
                                        } label: {
                                            Label("End series", systemImage: "trash")
                                        }
                                    }
                                    // The hub 403s anyone else, as the Mac's Edit Invitees does.
                                    Button {
                                        invitees = meeting
                                    } label: {
                                        Label("Invite", systemImage: "person.badge.plus")
                                    }
                                    .tint(Tokens.Palette.accent)
                                }
                            }
                        }
                    }
                }

                Section("Previous") {
                    if previousCalls.isEmpty {
                        EmptyStateText("No calls yet.")
                    } else {
                        ForEach(previousCalls) { call in
                            Button { recordTarget = call } label: {
                                HStack(spacing: Tokens.Space.x3) {
                                    IconTile(symbol: "waveform", style: .neutral, size: 38)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(call.title ?? "Call")
                                            .font(Tokens.Typography.row)
                                            .foregroundStyle(Tokens.Palette.ink)
                                        Text(RelativeStamp.list(call.startedDate))
                                            .font(Tokens.Typography.caption)
                                            .foregroundStyle(Tokens.Palette.inkTertiary)
                                    }
                                    Spacer(minLength: 0)
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(Tokens.Palette.inkTertiary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .listRowBackground(Tokens.Palette.surface)
        }
        .hqCanvas()
        .navigationTitle("Meetings")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { isScheduling = true } label: { Image(systemName: "calendar.badge.plus") }
                    .accessibilityLabel("Schedule a meeting")
            }
        }
        .sheet(item: $greenRoom) { request in
            GreenRoomView(meetingId: request.meetingId, title: request.title)
                .environment(store)
        }
        .sheet(isPresented: $isScheduling) {
            ScheduleMeetingView().environment(store)
        }
        .sheet(item: $recordTarget) { call in
            CallRecordSheet(call: call).environment(store)
        }
        .confirmationDialog(
            cancelRequest?.title ?? "",
            isPresented: Binding(
                get: { cancelRequest != nil },
                set: { if !$0 { cancelRequest = nil } }
            ),
            titleVisibility: .visible,
            presenting: cancelRequest
        ) { request in
            Button(request.confirmLabel, role: .destructive) {
                Task {
                    switch request.scope {
                    case .meeting, .occurrence:
                        await store.cancelMeeting(request.meeting.id)
                    case .series:
                        if let seriesId = request.meeting.seriesId {
                            await store.cancelMeetingSeries(seriesId)
                        }
                    }
                }
            }
        } message: { request in
            Text(request.message)
        }
        // A meeting that has gone (canceled elsewhere, or gone live) takes its pending ask with it.
        .onChange(of: store.upcomingMeetings.map(\.id)) { _, ids in
            if let pending = cancelRequest, !ids.contains(pending.meeting.id) { cancelRequest = nil }
        }
        .sheet(item: $invitees) { meeting in
            EditInviteesSheet(meeting: meeting).environment(store)
        }
        .refreshable { await store.refresh() }
    }

    private func headcount(_ call: Call) -> String {
        let count = call.presentParticipants.count
        return count == 1 ? "1 person" : "\(count) people"
    }

    private func scheduleLine(_ meeting: Meeting) -> String {
        if let cadence = meeting.recurrence { return cadence }
        guard let date = meeting.scheduledDate else { return "Open room" }
        return "\(RelativeStamp.day(date)) \(date.formatted(date: .omitted, time: .shortened))"
    }
}

/// A swipe's ask to cancel, held until the dialog confirms it. Naming the
/// meeting and what the act reaches (this one, or every future one) is the
/// point: neither can be undone from the phone.
private struct MeetingCancelRequest {
    enum Scope { case meeting, occurrence, series }

    let meeting: Meeting
    let scope: Scope

    var title: String {
        switch scope {
        case .meeting: "Cancel \u{201C}\(meeting.title)\u{201D}?"
        case .occurrence: "Skip this \u{201C}\(meeting.title)\u{201D}?"
        case .series: "End \u{201C}\(meeting.title)\u{201D}?"
        }
    }

    var message: String {
        switch scope {
        case .meeting: "The meeting is canceled for everyone invited."
        case .occurrence: "Only this one is canceled. The meetings after it stay."
        case .series: "Every future meeting in this series ends for everyone invited."
        }
    }

    var confirmLabel: String {
        switch scope {
        case .meeting: "Cancel Meeting"
        case .occurrence: "Skip This Occurrence"
        case .series: "End Series"
        }
    }
}

struct GreenRoomRequest: Identifiable {
    let meetingId: String?
    let title: String

    var id: String { meetingId ?? "quick-call" }
}

private struct ScheduleMeetingView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var when = Date().addingTimeInterval(3600)
    @State private var isScheduled = true
    @State private var repeats = MeetingRepeat.never
    @State private var invited: Set<String> = []

    /// A cadence needs a first occurrence to count from.
    private var isSchedulingRequired: Bool { repeats != .never }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Title", text: $title)
                    .font(Tokens.Typography.row)
                Toggle("Schedule for later", isOn: $isScheduled)
                    .font(Tokens.Typography.row)
                    .disabled(isSchedulingRequired)
                if isScheduled || isSchedulingRequired {
                    DatePicker("When", selection: $when)
                        .font(Tokens.Typography.row)
                }
                Picker("Repeat", selection: $repeats) {
                    ForEach(MeetingRepeat.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .font(Tokens.Typography.row)
                .onChange(of: repeats) { _, value in
                    if value != .never { isScheduled = true }
                }
                Section("Invite") {
                    MeetingInvitePicker(selected: $invited)
                }
            }
            .navigationTitle("New Meeting")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Create") {
                        let name = title.trimmingCharacters(in: .whitespaces)
                        let willSchedule = isScheduled || isSchedulingRequired
                        let people = Array(invited)
                        let rule = repeats.body
                        dismiss()
                        Task {
                            _ = await store.createMeeting(
                                title: name.isEmpty ? "Meeting" : name,
                                scheduledAt: willSchedule ? when : nil,
                                inviteePersonIds: people,
                                recurrence: rule
                            )
                        }
                    }
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

/// What a finished call left behind: when it was and how long it ran,
/// the assistant's summary, what the flight recorder noticed, the whole
/// speaker-attributed transcript with each line's offset into the call, and
/// the microphones on file — with the retry for a call whose transcript never
/// happened. The Mac's `CallRecordView`, at phone width.
private struct CallRecordSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let call: Call
    @State private var record: CallRecord?
    @State private var isLoading = true
    @State private var isRetranscribing = false
    @State private var error: String?

    private var whenLabel: String {
        let started = call.startedDate.formatted(date: .abbreviated, time: .shortened)
        let length = Duration.seconds(call.duration)
            .formatted(.units(allowed: [.hours, .minutes], width: .wide))
        return "\(started) · \(length)"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.Space.x5) {
                    header
                    if isLoading {
                        ProgressView().frame(maxWidth: .infinity).padding(Tokens.Space.x6)
                    } else {
                        summarySection
                        healthSection
                        transcriptSection
                        audioSection
                    }
                    if let error {
                        Text(error)
                            .font(Tokens.Typography.meta)
                            .foregroundStyle(Tokens.Palette.danger)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Tokens.Space.x4)
            }
            .background(Tokens.Palette.surface)
            .scrollContentBackground(.hidden)
            .navigationTitle(call.title ?? "Call")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
        .task { await load() }
    }

    private var header: some View {
        HStack(spacing: Tokens.Space.x3) {
            IconTile(symbol: "video.fill", style: .neutral, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(call.title ?? "Call")
                    .font(Tokens.Typography.cardTitle)
                    .foregroundStyle(Tokens.Palette.ink)
                Text(whenLabel)
                    .font(Tokens.Typography.meta)
                    .foregroundStyle(Tokens.Palette.inkSecondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x2) {
            SectionLabel("Summary")
            if let summary = record?.summary, !summary.isEmpty {
                MarkdownFileView(text: summary)
            } else {
                EmptyStateText(
                    record?.hasAudio == true
                        ? "No summary — nothing was transcribed. The audio is still on file."
                        : "No summary for this call."
                )
            }
        }
    }

    // The flight recorder, summed. A clean call shows nothing at all — this
    // section exists for the call someone opens to ask "what happened".
    @ViewBuilder private var healthSection: some View {
        if let health = record?.health, !health.isClean {
            VStack(alignment: .leading, spacing: Tokens.Space.x2) {
                SectionLabel("Reliability")
                // A phone runs out of width before a bad call runs out of
                // troubles, so the chips wrap instead of clipping.
                FlowRow(spacing: Tokens.Space.x2) {
                    ForEach(health.troubles, id: \.label) { trouble in
                        Text("\(trouble.count) \(trouble.label)\(trouble.count == 1 ? "" : "s")")
                            .font(Tokens.Typography.caption)
                            .foregroundStyle(Tokens.Palette.danger)
                            .padding(.horizontal, Tokens.Space.x2)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Tokens.Palette.danger.opacity(0.12)))
                    }
                }
            }
        }
    }

    private var transcriptSection: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x2) {
            SectionLabel("Transcript")
            if let lines = record?.transcript, !lines.isEmpty {
                VStack(alignment: .leading, spacing: Tokens.Space.x2) {
                    ForEach(lines) { line in
                        TranscriptOffsetRow(line: line, startedAt: call.startedDate)
                    }
                }
                .textSelection(.enabled)
            } else {
                EmptyStateText(
                    record?.wasProcessed == true
                        ? "Nothing was said on this call."
                        : "This call hasn't been transcribed."
                )
            }
        }
    }

    // The recovery affordance: audio is kept for every call, so a transcript
    // that never happened is something you can go and get.
    private var audioSection: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x2) {
            SectionLabel("Recording")
            if let recordings = record?.recordings, !recordings.isEmpty {
                VStack(spacing: 0) {
                    ForEach(recordings) { recording in
                        RecordingRow(callId: call.id, recording: recording)
                        if recording.id != recordings.last?.id {
                            RowDivider(inset: 44)
                        }
                    }
                }
                .hqCard()
                Button(isRetranscribing ? "Transcribing…" : "Transcribe from the recording") {
                    Task { await retranscribe() }
                }
                .buttonStyle(QuietCapsuleButtonStyle(height: Tokens.Layout.controlHeightSmall))
                .disabled(isRetranscribing)
            } else {
                EmptyStateText("No audio was saved for this call.")
            }
        }
    }

    private func load() async {
        guard let client = store.client else { return }
        do {
            record = try await client.callRecord(callId: call.id)
            error = nil
        } catch {
            self.error = "This call's record could not be loaded."
        }
        isLoading = false
    }

    private func retranscribe() async {
        guard let client = store.client else { return }
        isRetranscribing = true
        do {
            try await client.retranscribe(callId: call.id)
            await load()
        } catch let apiError as APIError where apiError.code == "not_configured" {
            error = "Transcription isn't configured, so the audio can't be read back yet."
        } catch {
            self.error = "The recording could not be transcribed."
        }
        isRetranscribing = false
    }
}

/// One transcript line with where in the call it was said. The offset is what
/// makes a transcript scannable — "they said that about twenty minutes in" is
/// how people actually remember a meeting.
private struct TranscriptOffsetRow: View {
    let line: TranscriptLine
    let startedAt: Date

    private var offsetLabel: String {
        let seconds = max(0, Int(line.atMs / 1000 - startedAt.timeIntervalSince1970))
        return "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }

    var body: some View {
        HStack(alignment: .top, spacing: Tokens.Space.x3) {
            Text(offsetLabel)
                .font(Tokens.Typography.caption.monospacedDigit())
                .foregroundStyle(Tokens.Palette.inkTertiary)
                .fixedSize()
                .frame(minWidth: 38, alignment: .trailing)
            VStack(alignment: .leading, spacing: 1) {
                Text(line.name)
                    .font(Tokens.Typography.captionEmphasis)
                    .foregroundStyle(Tokens.Palette.inkSecondary)
                Text(line.text)
                    .font(Tokens.Typography.row)
                    .foregroundStyle(Tokens.Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// One person's microphone for the whole call, saved as a WAV. The Mac writes
/// it through an `NSSavePanel`; the phone hands it to the share sheet, where
/// Save to Files is one of the choices and forwarding it is the rest.
private struct RecordingRow: View {
    @Environment(AppStore.self) private var store
    let callId: String
    let recording: CallRecording
    @State private var isPreparing = false
    @State private var share: ShareRequest?

    private var lengthLabel: String {
        Duration.seconds(recording.seconds)
            .formatted(.units(allowed: [.minutes, .seconds], width: .narrow))
    }

    var body: some View {
        HStack(spacing: Tokens.Space.x3) {
            AvatarView(name: recording.name, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(recording.name)
                    .font(Tokens.Typography.row)
                    .foregroundStyle(Tokens.Palette.ink)
                Text("\(lengthLabel) of audio")
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.inkTertiary)
            }
            Spacer(minLength: Tokens.Space.x3)
            Button(isPreparing ? "Preparing…" : "Share…") { prepare() }
                .buttonStyle(QuietCapsuleButtonStyle(height: Tokens.Layout.controlHeightSmall))
                .disabled(isPreparing)
        }
        .padding(.horizontal, Tokens.Space.x4)
        .padding(.vertical, Tokens.Space.x2)
        .sheet(item: $share) { request in
            ShareSheet(items: request.items)
        }
    }

    /// The share sheet needs something on disk to offer as a file, so the WAV
    /// lands in the temporary directory under the name a person would want to
    /// see in Files — never the device id it is fetched by.
    private func prepare() {
        guard let client = store.client else { return }
        isPreparing = true
        Task {
            defer { isPreparing = false }
            guard let data = try? await client.recordingData(
                callId: callId, deviceId: recording.deviceId
            ) else { return }
            let safeName = recording.name.replacingOccurrences(of: "/", with: "-")
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(safeName) - call.wav")
            guard (try? data.write(to: url, options: .atomic)) != nil else { return }
            share = ShareRequest([url])
        }
    }
}

/// A wrapping row. `HStack` clips its overflow and `LazyVGrid` wants fixed
/// columns; a handful of variable-width chips need neither.
private struct FlowRow: Layout {
    var spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: proposal.width ?? x, height: y + rowHeight)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(
                at: CGPoint(x: x, y: y), anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
