import Foundation
import Observation

/// Device-local presentation choices, isolated by hub and signed-in person.
@MainActor @Observable
final class HomePreferences {
    enum Shortcut: String, CaseIterable, Codable, Identifiable {
        // `tasks` is the Projects shortcut: the raw value stays so stored
        // favorites survive. A stored value that is not a case simply fails to
        // decode and drops out.
        case calls, tasks, files
        var id: String { rawValue }

        /// The favorites a person starts with, in grid order.
        static let defaultShortcuts: [Shortcut] = [.calls, .tasks, .files]

        /// The shortcuts this person may see, in the enum's order.
        static var available: [Shortcut] { allCases }

        var title: String {
            switch self {
            case .calls: "Calls"
            case .tasks: "Tasks"
            case .files: "Files"
            }
        }
        var symbol: String {
            switch self {
            case .calls: "video.fill"
            case .tasks: "checklist"
            case .files: "folder.fill"
            }
        }
    }

    private struct Record: Codable {
        var pinnedIDs: [String]
        var shortcuts: [String]
    }
    static let maximumPins = 9
    static let maximumShortcuts = 3
    private(set) var pinnedIDs: [String]
    private(set) var shortcuts: [Shortcut]
    private let defaults: UserDefaults?
    private let key: String

    init(hub: String, personID: String, defaults: UserDefaults? = .standard, initialPins: [String] = []) {
        self.defaults = defaults
        let normalizedHub = hub.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let scope = try? JSONEncoder().encode([normalizedHub, personID])
        key = "hq-phone-home-v1." + (scope?.base64EncodedString() ?? "")
        let record = defaults?.data(forKey: key).flatMap { try? JSONDecoder().decode(Record.self, from: $0) }
        pinnedIDs = Array(Self.unique(record?.pinnedIDs ?? initialPins).prefix(Self.maximumPins))
        shortcuts = Array(Self.unique(record?.shortcuts ?? Shortcut.defaultShortcuts.map(\.rawValue))
            .compactMap(Shortcut.init(rawValue:)).prefix(Self.maximumShortcuts))
    }

    func isPinned(_ id: String) -> Bool { pinnedIDs.contains(id) }

    @discardableResult
    func pin(_ id: String) -> Bool {
        guard !id.isEmpty, !isPinned(id), pinnedIDs.count < Self.maximumPins else { return false }
        pinnedIDs.append(id)
        save()
        return true
    }

    func unpin(_ id: String) {
        pinnedIDs.removeAll { $0 == id }
        save()
    }

    func movePin(_ id: String, to target: String) {
        guard let source = pinnedIDs.firstIndex(of: id), let destination = pinnedIDs.firstIndex(of: target),
              source != destination else { return }
        pinnedIDs.remove(at: source)
        pinnedIDs.insert(id, at: min(destination, pinnedIDs.count))
        save()
    }

    func movePin(_ id: String, by offset: Int) {
        guard let index = pinnedIDs.firstIndex(of: id), pinnedIDs.indices.contains(index + offset) else { return }
        movePin(id, to: pinnedIDs[index + offset])
    }

    func setPinOrder(_ ids: [String]) {
        // Reordering visible pins must retain temporarily unavailable conversations.
        let visible = Self.unique(ids).filter { pinnedIDs.contains($0) }
        let visibleSet = Set(visible)
        var iterator = visible.makeIterator()
        pinnedIDs = pinnedIDs.map { visibleSet.contains($0) ? iterator.next() ?? $0 : $0 }
        save()
    }

    func setShortcuts(_ values: [Shortcut]) {
        shortcuts = Array(Self.unique(values.map(\.rawValue)).compactMap(Shortcut.init(rawValue:))
            .prefix(Self.maximumShortcuts))
        save()
    }

    private func save() {
        let record = Record(pinnedIDs: pinnedIDs, shortcuts: shortcuts.map(\.rawValue))
        if let data = try? JSONEncoder().encode(record) { defaults?.set(data, forKey: key) }
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
