import SwiftUI

struct ActiveCallBanner: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        CallReturnStrip { MeetingWindow.spotlight(using: openWindow) }
    }
}
