import AVFAudio
import WebRTC
import XCTest

final class CallAudioConfigurationTests: XCTestCase {
    func testWebRTCConfigurationKeepsSpeakerRouteWithoutEnablingCallKitAudio() throws {
        let session = RTCAudioSession.sharedInstance()
        let previousConfiguration = RTCAudioSessionConfiguration.webRTC()
        let previousSessionConfiguration = RTCAudioSessionConfiguration.current()
        let wasManualAudioEnabled = session.useManualAudio
        let wasAudioEnabled = session.isAudioEnabled
        session.lockForConfiguration()
        defer {
            try? session.setConfiguration(previousSessionConfiguration)
            session.unlockForConfiguration()
            RTCAudioSessionConfiguration.setWebRTC(previousConfiguration)
            session.useManualAudio = wasManualAudioEnabled
            session.isAudioEnabled = wasAudioEnabled
        }

        session.useManualAudio = true
        session.isAudioEnabled = false
        let wasActive = session.isActive
        // The green room works before WebRTC applies its own configuration.
        try session.setCategory(
            .playAndRecord, mode: .videoChat,
            options: [.allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker]
        )
        CallAudioConfiguration.install()

        // Use the same configuration API as WebRTC's audio-unit startup.
        // Repeat for a reconnect, which must keep the speaker route too.
        for _ in 0..<2 {
            try session.setConfiguration(RTCAudioSessionConfiguration.webRTC())
            XCTAssertEqual(session.category, AVAudioSession.Category.playAndRecord.rawValue)
            XCTAssertEqual(session.mode, AVAudioSession.Mode.videoChat.rawValue)
            XCTAssertTrue(session.categoryOptions.contains(.defaultToSpeaker))
            XCTAssertTrue(session.categoryOptions.contains(.allowBluetoothHFP))
            XCTAssertTrue(session.categoryOptions.contains(.allowBluetoothA2DP))
            XCTAssertTrue(session.useManualAudio)
            XCTAssertFalse(session.isAudioEnabled)
            XCTAssertEqual(session.isActive, wasActive)
        }
    }
}
