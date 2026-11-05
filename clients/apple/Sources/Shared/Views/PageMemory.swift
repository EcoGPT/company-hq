import AppKit
import SwiftUI

/// The pages that read their own data (Files) keep it here, with where the person was inside
/// each, so a return draws what was read and refreshes behind it. RootView holds one
/// above its destination switch; everything goes when the signed-in person
/// changes or signs out.
@MainActor @Observable
final class PageMemory {
    private(set) var personID: String?
    private(set) var files = FilesPage()

    /// The same person keeps every page; signing out, or someone else signing
    /// in, starts them all over. The first person takes them as they are:
    /// nothing reads without a signed-in person, and a page already reading
    /// for them must not lose its model mid-read.
    func keep(for personID: String?) {
        guard personID != self.personID else { return }
        defer { self.personID = personID }
        guard self.personID != nil else { return }
        files = FilesPage()
    }
}

#if DEBUG
/// A page's fixture route (`HQ_UI_ROUTE`) opens once per launch, the way a
/// person's first click would; a return finds whatever the page kept.
@MainActor
enum FixtureRoute {
    static var isApplied = false
}
#endif
