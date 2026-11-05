import AppKit

#if DEBUG
/// A launch (fixture or live) with `HQ_UI_SNAPSHOT=<path.png>` writes its own
/// window to that PNG and quits — a render of a real screen for review without
/// anyone driving the Mac. `HQ_UI_SNAPSHOT_SIZE=1440x900` sets the window size first;
/// `HQ_UI_SNAPSHOT_SETTLE=<seconds>` (default 3) is how long it waits after that, which a
/// live launch may want so the first load has landed.
@MainActor
enum FixtureSnapshot {
    static func scheduleIfAsked() {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["HQ_UI_SNAPSHOT"], !path.isEmpty else { return }
        let size = (env["HQ_UI_SNAPSHOT_SIZE"] ?? "1440x900").split(separator: "x").compactMap { Double($0) }
        let settle = env["HQ_UI_SNAPSHOT_SETTLE"].flatMap(Double.init) ?? 3
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else { return }
            if size.count == 2 { window.setContentSize(NSSize(width: size[0], height: size[1])) }
            DispatchQueue.main.asyncAfter(deadline: .now() + settle) {
                Task { @MainActor in
                    write(window, to: URL(fileURLWithPath: path))
                    NSApp.terminate(nil)
                }
            }
        }
    }

    private static func write(_ window: NSWindow, to url: URL) {
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif
