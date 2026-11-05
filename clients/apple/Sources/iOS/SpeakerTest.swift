import AVFoundation
import Foundation
import WebRTC

/// "Test speakers" on the phone. The Mac plays `NSSound("Glass")` and is done:
/// AppKit's sound goes out the system's current output, which is the route the
/// call will use. A phone has no such guarantee — the default category is
/// playback-only and routes to the receiver, so a tone played before the
/// session is configured proves the earpiece, not the speaker the meeting will
/// come out of.
///
/// So the test configures the call's own session first, through
/// `RTCAudioSession`'s lock (WebRTC configures the same singleton, and two
/// writers without the lock race into a session that is neither one's), and
/// only then plays. What you hear is what the call will sound like, on the
/// speaker or on the AirPods, whichever is connected.
@MainActor
enum SpeakerTest {
    /// Held for the length of the tone: an `AVAudioPlayer` that goes out of
    /// scope stops mid-sound.
    private static var player: AVAudioPlayer?

    static func play() {
        configureCallRoute()
        guard let player = try? AVAudioPlayer(data: chime) else { return }
        Self.player = player
        player.volume = 0.7
        player.prepareToPlay()
        player.play()
    }

    /// The category the call uses, set idempotently: during a green room the
    /// level monitor has already asked for exactly this, and re-setting it
    /// bounces the route for no reason.
    private static func configureCallRoute() {
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        defer { session.unlockForConfiguration() }
        do {
            if session.category != AVAudioSession.Category.playAndRecord.rawValue {
                try session.setCategory(
                    .playAndRecord,
                    mode: .videoChat,
                    options: [.allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker]
                )
            }
            // CallKit owns activation when it is driving; claiming the session
            // on top of it is the race that connects a call silent.
            if !session.useManualAudio {
                try session.setActive(true)
            }
        } catch {
            // A speaker test that cannot configure the route is worth no
            // interruption of its own — the tone simply plays wherever iOS
            // has the session pointed.
        }
    }

    /// A two-note chime, synthesized rather than shipped: a WAV in memory
    /// costs nothing to build and saves an asset that would have to be
    /// licensed, bundled, and kept in step with the app icon set.
    private static let chime: Data = {
        let rate = 44_100.0
        let notes: [(frequency: Double, seconds: Double)] = [(880, 0.16), (1_318.5, 0.26)]
        var samples: [Int16] = []
        for note in notes {
            let count = Int(note.seconds * rate)
            samples.reserveCapacity(samples.count + count)
            for index in 0..<count {
                let time = Double(index) / rate
                // A quick attack and an exponential decay: a flat-topped tone
                // clicks at both ends and reads as a fault, not a chime.
                let attack = min(1, time / 0.006)
                let decay = exp(-time * 9)
                let value = sin(2 * .pi * note.frequency * time) * attack * decay
                samples.append(Int16(max(-1, min(1, value)) * 32_000))
            }
        }
        return wav(samples: samples, sampleRate: Int(rate))
    }()

    /// 16-bit mono PCM in a canonical 44-byte WAV header — the least that
    /// `AVAudioPlayer` will accept from memory.
    private static func wav(samples: [Int16], sampleRate: Int) -> Data {
        let bytesPerSample = 2
        let dataBytes = samples.count * bytesPerSample
        var data = Data(capacity: 44 + dataBytes)

        func appendASCII(_ text: String) { data.append(contentsOf: Array(text.utf8)) }
        func appendUInt32(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        func appendUInt16(_ value: UInt16) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }

        appendASCII("RIFF")
        appendUInt32(UInt32(36 + dataBytes))
        appendASCII("WAVE")
        appendASCII("fmt ")
        appendUInt32(16)
        appendUInt16(1)  // PCM
        appendUInt16(1)  // mono
        appendUInt32(UInt32(sampleRate))
        appendUInt32(UInt32(sampleRate * bytesPerSample))
        appendUInt16(UInt16(bytesPerSample))
        appendUInt16(16)
        appendASCII("data")
        appendUInt32(UInt32(dataBytes))
        for sample in samples {
            withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }
}
