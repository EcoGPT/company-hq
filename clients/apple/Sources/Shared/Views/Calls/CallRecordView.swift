import AppKit
import SwiftUI

// What a finished call left behind: the assistant's summary at the top, the
// speaker-attributed transcript under it, and what audio is on file. A past
// call in the Meetings list used to open nothing at all — the record existed
// only as a chat message that scrolled away.
struct CallRecordView: View {
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
        VStack(alignment: .leading, spacing: 0) {
            header
            RowDivider(inset: 0)
            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.Space.x5) {
                    if isLoading {
                        EmptyStateText("Loading…")
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
                .padding(Tokens.Space.x5)
            }
        }
        .frame(width: 620, height: 560)
        .background(Tokens.Palette.surface)
        .task { await load() }
    }

    private var header: some View {
        HStack(spacing: Tokens.Space.x3) {
            IconTile(symbol: "video.fill", style: .neutral, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(call.title ?? "Call")
                    .font(Tokens.Typography.sheetTitle)
                    .foregroundStyle(Tokens.Palette.ink)
                Text(whenLabel)
                    .font(Tokens.Typography.meta)
                    .foregroundStyle(Tokens.Palette.inkSecondary)
            }
            Spacer(minLength: Tokens.Space.x3)
            Button("Done") { dismiss() }
                .buttonStyle(QuietCapsuleButtonStyle())
                .keyboardShortcut(.cancelAction)
        }
        .padding(Tokens.Space.x4)
    }

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x2) {
            SectionLabel("Summary")
            if let summary = record?.summary {
                Text(summary)
                    .font(Tokens.Typography.row)
                    .foregroundStyle(Tokens.Palette.ink)
                    .textSelection(.enabled)
            } else {
                EmptyStateText(
                    record?.hasAudio == true
                        ? "No summary — nothing was transcribed. The audio is still on file."
                        : "No summary for this call."
                )
            }
        }
    }

    // The flight recorder, summed. A clean call shows nothing at all —
    // this section exists for the call someone opens to ask "what happened".
    @ViewBuilder private var healthSection: some View {
        if let health = record?.health, !health.isClean {
            VStack(alignment: .leading, spacing: Tokens.Space.x2) {
                SectionLabel("Reliability")
                HStack(spacing: Tokens.Space.x2) {
                    ForEach(health.troubles, id: \.label) { trouble in
                        Text("\(trouble.count) \(trouble.label)\(trouble.count == 1 ? "" : "s")")
                            .font(Tokens.Typography.caption)
                            .foregroundStyle(Tokens.Palette.danger)
                            .padding(.horizontal, Tokens.Space.x2)
                            .padding(.vertical, 3)
                            .background(
                                Capsule().fill(Tokens.Palette.danger.opacity(0.12))
                            )
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
                        TranscriptLineRow(line: line, startedAt: call.startedDate)
                    }
                }
                .textSelection(.enabled)
            } else {
                EmptyStateText("Nothing was transcribed.")
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

private struct TranscriptLineRow: View {
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
                .frame(width: 38, alignment: .trailing)
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

// One person's microphone for the whole call, saved to disk as a WAV. This
// is the archive, not a player.
private struct RecordingRow: View {
    @Environment(AppStore.self) private var store
    let callId: String
    let recording: CallRecording
    @State private var isSaving = false

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
            Button(isSaving ? "Saving…" : "Save…") { save() }
                .buttonStyle(QuietCapsuleButtonStyle(height: Tokens.Layout.controlHeightSmall))
                .disabled(isSaving)
        }
        .padding(.horizontal, Tokens.Space.x4)
        .padding(.vertical, Tokens.Space.x2)
    }

    private func save() {
        guard let client = store.client else { return }
        isSaving = true
        Task {
            defer { isSaving = false }
            guard let data = try? await client.recordingData(
                callId: callId, deviceId: recording.deviceId
            ) else { return }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "\(recording.name) - call.wav"
            guard await panel.begin() == .OK, let url = panel.url else { return }
            try? data.write(to: url)
        }
    }
}
