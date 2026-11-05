import SwiftUI

// One panel, two tabs' worth of content — people or the meeting's own thread.
// In-call chat is the conversation the call belongs to, so nothing said in a
// meeting is lost when the meeting ends.
struct MeetingSidePanel: View {
    @Environment(AppStore.self) private var store
    let panel: MeetingView.SidePanel
    let call: Call?
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(panel == .people ? "People" : "In-call messages")
                    .font(Tokens.Typography.cardTitle)
                    .foregroundStyle(Tokens.Palette.ink)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(Tokens.Typography.buttonSmall)
                        .foregroundStyle(Tokens.Palette.inkSecondary)
                        .frame(width: 26, height: 26)
                        .background(Tokens.Palette.surfaceHover, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Close")
            }
            .padding(Tokens.Space.x4)
            RowDivider(inset: 0)
            if panel == .people {
                peopleList
            } else if let conversationId = call?.conversationId {
                ChatView(conversationId: conversationId, isInMeetingPanel: true)
            }
        }
        .background(Tokens.Palette.surface)
    }

    private var peopleList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(call?.presentParticipants ?? []) { participant in
                    HStack(spacing: Tokens.Space.x3) {
                        AvatarView(name: store.people[participant.personId]?.name ?? "?", size: 28)
                        Text(store.people[participant.personId]?.name ?? "Someone")
                            .font(Tokens.Typography.row)
                            .foregroundStyle(Tokens.Palette.ink)
                        Spacer()
                        if participant.isHandRaised {
                            Image(systemName: "hand.raised.fill")
                                .foregroundStyle(.yellow)
                                .font(.system(size: 11))
                        }
                        if participant.isScreenSharing {
                            Image(systemName: "rectangle.on.rectangle")
                                .foregroundStyle(Tokens.Palette.inkSecondary)
                                .font(.system(size: 11))
                        }
                        Image(systemName: participant.isMuted ? "mic.slash.fill" : "mic.fill")
                            .foregroundStyle(
                                participant.isMuted ? Tokens.Palette.inkTertiary : Tokens.Palette.ink
                            )
                            .font(.system(size: 11))
                    }
                    .padding(.horizontal, Tokens.Space.x4)
                    .padding(.vertical, 6)
                }
            }
            .padding(.vertical, 8)
        }
    }
}
