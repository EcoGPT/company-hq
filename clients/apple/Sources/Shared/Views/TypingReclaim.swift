import AppKit

/// Who a typed character belongs to on a page with no composer (RootView's
/// typing monitor): the last conversation's composer, unless something focused
/// is using it. A focused text view keeps every key. A focused control keeps
/// Space, which is how it is operated; a list or outline does not, since its
/// Space and letters are only type-to-select, so those still go to the
/// composer, as before Settings had tabs.
enum TypingReclaim {
    static func isFree(_ responder: NSResponder?, characters: String) -> Bool {
        if responder is NSText { return false }
        if characters == " ", responder is NSControl, !(responder is NSTableView) { return false }
        return true
    }
}
