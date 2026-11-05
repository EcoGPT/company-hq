import Foundation

/// Where the person put the Live canvas's nodes: a pin per node,
/// kept on this device. A pin is the node's centre as a fraction of the layout's
/// width plus a height in canvas points, so it survives a window that is wider
/// or narrower; `LiveCanvasLayout.layout` applies pins after the automatic
/// layout and draws every line from the moved frames. A pin may lie anywhere
///: left of the layout (a negative fraction), right of it (over 1)
/// or above its top (a negative `y`); the canvas grows to hold the node. Only a value
/// past the sanity bounds is held to them (`maxFraction`, `maxY`): the canvas is drawn at its
/// full size, so a bound keeps it a size a Mac can draw. A person can also be mirrored
/// (a double-click on their face): their pills stand on the other side of the avatar,
/// a flag per person kept beside the pins. Pure Foundation so the rules run in unit tests.
///
/// Keys: `person:<id>` (a person with agents), `idle:<id>` (the same person's
/// face in the idle row: a separate place, so a person dragged while active
/// does not drag their idle face, and the reverse), `session:<id>`,
/// and `hub:<id>` (a project in the centre).
struct LiveCanvasPositions: Codable, Equatable {
    struct Pin: Codable, Equatable {
        /// The node centre across the layout's width: 0...1 inside it, outside that when the
        /// node was put past the left or right edge.
        var xFraction: Double
        /// The node centre down the canvas, in canvas points from the automatic layout's top;
        /// negative above it.
        var y: Double
        var savedAt: Date
    }

    /// The furthest a pin may sit from the layout's left edge, in layouts, either way: a canvas
    /// at this bound is about eight layouts wide. This and `maxY` keep the canvas (its line layers
    /// are as big as it is, one redrawn thirty times a second) a size a Mac can draw; a pin past
    /// them is held at them, on load too.
    static let maxFraction = 4.0
    /// The furthest a pin may sit above or below the automatic layout's top, in canvas points.
    static let maxY = 10_000.0
    /// Most pins kept: the oldest go first.
    static let maxPins = 500
    /// A session pin not saved for this long is dropped: the session is long gone.
    static let sessionKeepDays = 14

    private(set) var pins: [String: Pin] = [:]
    /// The people whose pills stand on the other side of their avatar, as `person:<id>` keys. The
    /// flag carries the pills the person never moved; a pill that was pinned has its pin reflected
    /// when the flag changes (`mirrorPerson`). Optional in the saved record: one written before it
    /// existed has none, and a bad value costs the flag, never the pins.
    private(set) var mirrored: Set<String> = []

    init() {}

    var isEmpty: Bool { pins.isEmpty && mirrored.isEmpty }

    static func personKey(_ id: String) -> String { "person:" + id }
    static func sessionKey(_ id: String) -> String { "session:" + id }
    static func hubKey(_ id: String) -> String { "hub:" + id }
    static func idleKey(_ id: String) -> String { "idle:" + id }
    /// A person outside HQ on Control's canvas.
    static func outsideKey(_ id: String) -> String { "outside:" + id }

    func pin(for key: String) -> Pin? { pins[key] }

    func contains(_ key: String) -> Bool { pins[key] != nil }

    /// Whether "Put Back" has something to undo for `key`: a pin, or a person's mirror flag.
    func holds(_ key: String) -> Bool { pins[key] != nil || mirrored.contains(key) }

    /// Whether the person at `key` (`person:<id>`) has their pills on the other side.
    func isMirrored(_ key: String) -> Bool { mirrored.contains(key) }

    mutating func setMirrored(_ key: String, _ isMirrored: Bool) {
        guard !key.isEmpty else { return }
        if isMirrored { mirrored.insert(key) } else { mirrored.remove(key) }
    }

    /// Flips the person at `key` to the other side of their avatar, whose centre line is at `axis`
    /// (a fraction of the layout's width, like a pin's). The flag turns over, and each of `pills`
    /// (the pin keys of the person's pills) that was pinned is reflected about the axis, at the same
    /// height and held to the bounds as a drag is; a pill with no pin is left to the flag.
    mutating func mirrorPerson(_ key: String, aroundX axis: Double, pills: [String], at date: Date) {
        guard !key.isEmpty, axis.isFinite else { return }
        for pill in pills {
            guard let pin = pins[pill] else { continue }
            set(pill, xFraction: 2 * axis - pin.xFraction, y: pin.y, at: date)
        }
        setMirrored(key, !mirrored.contains(key))
    }

    /// A place held to the sanity bounds: any real place passes unchanged.
    static func bounded(xFraction: Double, y: Double) -> (xFraction: Double, y: Double) {
        (min(max(xFraction, -maxFraction), maxFraction), min(max(y, -maxY), maxY))
    }

    /// Pins the node at `key`, its centre at `xFraction` of the width and `y` down. Anywhere
    /// is fine (a negative fraction or `y`, a fraction over 1); a value past `maxFraction` or `maxY`
    /// is held to them, and a value that is not finite is refused.
    mutating func set(_ key: String, xFraction: Double, y: Double, at date: Date) {
        guard !key.isEmpty, xFraction.isFinite, y.isFinite else { return }
        let place = Self.bounded(xFraction: xFraction, y: y)
        pins[key] = Pin(xFraction: place.xFraction, y: place.y, savedAt: date)
    }

    /// Puts `key` back: its pin goes, and with it a person's mirror flag.
    mutating func remove(_ key: String) {
        pins[key] = nil
        mirrored.remove(key)
    }

    /// Holds every pin to the sanity bounds: a record past them (an earlier build) lands at the
    /// nearest place inside them and is not dropped.
    mutating func clampToBounds() {
        for (key, pin) in pins {
            let place = Self.bounded(xFraction: pin.xFraction, y: pin.y)
            if place.xFraction != pin.xFraction || place.y != pin.y {
                pins[key] = Pin(xFraction: place.xFraction, y: place.y, savedAt: pin.savedAt)
            }
        }
    }

    mutating func removeAll() {
        pins = [:]
        mirrored = []
    }

    private enum CodingKeys: String, CodingKey {
        case pins, mirrored
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pins = try container.decode([String: Pin].self, forKey: .pins)
        mirrored = (try? container.decodeIfPresent(Set<String>.self, forKey: .mirrored)) ?? []
    }

    /// With no flag the record is the one every earlier build wrote, byte for byte in shape.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pins, forKey: .pins)
        if !mirrored.isEmpty { try container.encode(mirrored, forKey: .mirrored) }
    }

    /// Drops session pins older than `sessionKeepDays`, then the oldest pins past `maxPins`.
    mutating func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-Double(Self.sessionKeepDays) * 86_400)
        pins = pins.filter { !($0.key.hasPrefix("session:") && $0.value.savedAt < cutoff) }
        guard pins.count > Self.maxPins else { return }
        let oldestFirst = pins.sorted { ($0.value.savedAt, $0.key) < ($1.value.savedAt, $1.key) }
        for entry in oldestFirst.prefix(pins.count - Self.maxPins) { pins[entry.key] = nil }
    }
}

/// The pins on disk, one record per hub and signed-in person, the way
/// `HomePreferences` scopes its own. The canvas that owns them picks the prefix: the
/// Agents canvas keeps `hq-live-canvas-positions-v1` (the value is stored on every Mac,
/// so it never changes) and Control keeps its own, so neither moves the other's nodes.
struct LiveCanvasPositionsStore {
    static let liveKeyPrefix = "hq-live-canvas-positions-v1"
    static let controlKeyPrefix = "hq-control-canvas-positions-v1"

    private let defaults: UserDefaults?
    let key: String

    init(hub: String, personID: String, defaults: UserDefaults? = .standard, keyPrefix: String = Self.liveKeyPrefix) {
        self.defaults = defaults
        let normalizedHub = hub.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let scope = try? JSONEncoder().encode([normalizedHub, personID])
        key = keyPrefix + "." + (scope?.base64EncodedString() ?? "")
    }

    /// What is saved, or nothing for an unreadable record.
    func load(now: Date = Date()) -> LiveCanvasPositions {
        var positions = defaults?.data(forKey: key).flatMap { try? JSONDecoder().decode(LiveCanvasPositions.self, from: $0) }
            ?? LiveCanvasPositions()
        positions.clampToBounds()
        positions.prune(now: now)
        return positions
    }

    /// Prunes, then writes. Returns what was kept.
    @discardableResult
    func save(_ positions: LiveCanvasPositions, now: Date = Date()) -> LiveCanvasPositions {
        var kept = positions
        kept.prune(now: now)
        if kept.isEmpty {
            defaults?.removeObject(forKey: key)
        } else if let data = try? JSONEncoder().encode(kept) {
            defaults?.set(data, forKey: key)
        }
        return kept
    }
}
