#if DEBUG && targetEnvironment(simulator)
    import SwiftUI

    /// Isolated presentations for states whose normal entry points need live data.
    struct HQFixturePresentation: View {
        @State private var isPresented = true

        var body: some View {
            Color.clear.sheet(isPresented: $isPresented) { preview }
        }

        @ViewBuilder private var preview: some View {
            let kind = HQSimulatorFixture.scenario.replacingOccurrences(of: "preview-", with: "")
            let type = kind == "image" ? "image/png" : kind == "markdown" ? "text/markdown" : "application/pdf"
            AttachmentPreviewSheet(
                request: AttachmentPreviewRequest(
                    Attachment(
                        id: "fixture-unavailable-\(kind)", fileName: "Notes.\(kind == "markdown" ? "md" : kind)",
                        contentType: type, byteSize: 1024, width: nil, height: nil
                    )))
        }
    }
#endif
