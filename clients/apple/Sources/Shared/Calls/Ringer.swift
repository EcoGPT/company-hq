import AVFoundation
import Foundation
#if os(macOS)
import AppKit
#endif

// The sound a ringing call makes. On the Mac it is a looping system
// alert: the one sound every Mac already has, respecting the alert volume,
// with nothing to ship or license. iOS has no equivalent named-sound API, so
// the phone rings on the system's own new-mail tone via AudioServices and
// vibrates with it — the vibration is what actually gets noticed in a pocket.
// Either way it plays on the default output only: a call ringing into
// headphones nobody is wearing is the thing this is trying to avoid.
@MainActor
final class Ringer {
    #if os(macOS)
    private var sound: NSSound?
    #else
    private var repeatTimer: Timer?
    #endif

    func start() {
        #if os(macOS)
        guard sound == nil else { return }
        guard let ring = NSSound(named: "Submarine") else { return }
        ring.loops = true
        sound = ring
        ring.play()
        #else
        guard repeatTimer == nil else { return }
        ring()
        // AudioServices plays once; a ring has to keep asking.
        repeatTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { _ in
            Task { @MainActor in self.ring() }
        }
        #endif
    }

    func stop() {
        #if os(macOS)
        sound?.stop()
        sound = nil
        #else
        repeatTimer?.invalidate()
        repeatTimer = nil
        #endif
    }

    #if !os(macOS)
    private func ring() {
        AudioServicesPlayAlertSound(SystemSoundID(1_007))
    }
    #endif
}

// The soft pop when someone else joins a live meeting, so a filling room is
// audible from anywhere in the app instead of only visible on the Meetings
// badge. One-shot and distinct from both the ring (Submarine) and the
// speaker-test tone (Glass). Mac only: the phone already gets the ring for
// calls aimed at it, and an ambient join pop in a pocket is just noise.
@MainActor
enum JoinChime {
    static func play() {
        #if os(macOS)
        NSSound(named: "Pop")?.play()
        #endif
    }
}
