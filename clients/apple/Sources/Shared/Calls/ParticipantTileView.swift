import SwiftUI
import WebRTC

// One person in the grid: their video if they are sending any, their initials
// if they are not, with the name chip and mic state Meet puts in the corners.
struct ParticipantTileView: View {
    @Environment(AppStore.self) private var store
    let participant: CallParticipant
    let video: RTCVideoTrack?
    var isSelf = false
    var isCompact = false

    // Everyone else's level comes from their inbound audio; your own comes
    // from the input tap, because inbound stats carry everyone but you. Same
    // stroke either way — on your own tile it is the proof the mic is live.
    private var isSpeaking: Bool {
        isSelf
            ? store.callEngine.isSelfSpeaking
            : store.callEngine.speakingDeviceIds.contains(participant.deviceId)
    }

    private var name: String {
        let person = store.people[participant.personId]?.name ?? "Someone"
        return isSelf ? "\(person) (You)" : person
    }

    var body: some View {
        ZStack {
            // The tile ground is stage chrome: one committed dark look, never
            // the adaptive underPageBackground (which went light-gray on the
            // black stage in light mode).
            RoundedRectangle(cornerRadius: Tokens.Radius.chip, style: .continuous)
                .fill(Tokens.Palette.stage)
            if let video {
                VideoView(track: video)
                    .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.chip, style: .continuous))
                    // A self-view is a mirror; everyone else is not.
                    .scaleEffect(x: isSelf ? -1 : 1, y: 1)
            } else {
                AvatarView(name: store.people[participant.personId]?.name ?? "?", size: isCompact ? 44 : 88)
            }
            if participant.isHandRaised {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: isCompact ? 16 : 22))
                    .foregroundStyle(.yellow)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(10)
            }
        }
        .overlay(alignment: .bottomLeading) {
            HStack(spacing: 6) {
                if participant.isMuted {
                    Image(systemName: "mic.slash.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                }
                Text(name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.black.opacity(0.55), in: Capsule())
            .padding(8)
        }
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.Radius.chip, style: .continuous)
                .strokeBorder(
                    isSpeaking
                        ? AnyShapeStyle(Tokens.Palette.accent)
                        : AnyShapeStyle(Tokens.Palette.stageInk.opacity(0.08)),
                    lineWidth: isSpeaking ? 3 : 1
                )
        )
        .animation(.easeOut(duration: 0.15), value: isSpeaking)
    }
}
