import AVFAudio
import WebRTC

enum CallAudioConfiguration {
    static func install() {
        // WebRTC reapplies these defaults when its audio unit starts or restarts.
        // Setting only AVAudioSession loses the speaker route at that point.
        let configuration = RTCAudioSessionConfiguration()
        configuration.category = AVAudioSession.Category.playAndRecord.rawValue
        configuration.mode = AVAudioSession.Mode.videoChat.rawValue
        configuration.categoryOptions = [.allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker]
        RTCAudioSessionConfiguration.setWebRTC(configuration)
    }
}
