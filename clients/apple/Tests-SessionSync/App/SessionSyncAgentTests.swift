import XCTest

@testable import HQ

/// The app's side of session sync: when it may touch the system, the order of turning sync
/// on (the notice first, then the sign-in hand-off, then the start), and what the notice says.
/// Nothing here registers a login item, starts a helper or writes this Mac's configuration.
@MainActor
final class SessionSyncAgentTests: XCTestCase {
    private let server = "https://hq.example.test"
    private var previousServer: String?
    private var defaults: UserDefaults!
    private let suite = "session-sync-agent-tests"

    override func setUp() {
        previousServer = HQConfig.savedServer
        HQConfig.savedServer = server
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        HQConfig.savedServer = previousServer
        defaults.removePersistentDomain(forName: suite)
    }

    private var ada: StoredSession {
        StoredSession(
            bearer: "fixture-bearer", deviceId: "d1",
            person: Person(id: "p1", name: "Ada", kind: "person", isAdmin: false, avatarId: nil, removedAt: nil))
    }

    /// Records what turning sync on does, in order, and answers the notice as told.
    private final class Recorder {
        var events: [String] = []
        var config: HQ.SessionSyncConfig?
        var answer = SessionSyncNotice.Choice.ok
        var noticeServer: String?

        var effects: SessionSyncAgent.Effects {
            var effects = SessionSyncAgent.Effects()
            effects.loadConfig = { self.config }
            effects.saveConfig = { self.events.append($0.paused == true ? "save paused" : "save"); self.config = $0 }
            effects.showNotice = { kind, server in
                self.events.append("notice \(kind)")
                self.noticeServer = server
                return self.answer
            }
            effects.retireHelpers = { self.events.append("retire") }
            effects.configure = { _, _ in self.events.append("configure") }
            effects.start = { self.events.append("start") }
            effects.halt = { self.events.append("halt") }
            effects.writeStatus = { _ in self.events.append("status") }
            effects.openLoginItems = { self.events.append("open login items") }
            return effects
        }
    }

    private func turnOn(_ recorder: Recorder, ignoringPause: Bool = false) async -> SessionSyncAgent.Outcome {
        await SessionSyncAgent.turnOn(
            ada, ignoringPause: ignoringPause, environment: [:], defaults: defaults, isDebugBuild: false,
            effects: recorder.effects, isCurrent: { true }, isBuilt: true)
    }

    // MARK: When the system may be touched

    func testNothingTouchesTheSystemUnderATestHostOrAWorktreeRun() async throws {
        for environment in [["HQ_NO_SYSTEM_REGISTRATION": "1"], ["XCTestConfigurationFilePath": "/tmp/x"]] {
            XCTAssertTrue(SessionSyncGate.isSystemTouchBlocked(environment: environment))
            let started = try await SessionSyncAgent.start(environment: environment)
            XCTAssertFalse(started)
            XCTAssertFalse(SessionSyncAgent.retireRunningHelpers(environment: environment))
            XCTAssertFalse(SessionSyncAgent.disable(environment: environment))
            XCTAssertFalse(SessionSyncAgent.pause(environment: environment))
            let restored = await SessionSyncAgent.restore(ada, environment: environment)
            XCTAssertFalse(restored)
        }
    }

    func testADebugBuildStaysOffUnlessAskedAndNeverStopsAnInstalledAppsHelper() {
        XCTAssertFalse(SessionSyncGate.isRegistrationAllowed(environment: [:], isDebugBuild: true))
        XCTAssertTrue(SessionSyncGate.isRegistrationAllowed(environment: ["HQ_ALLOW_SYSTEM_REGISTRATION": "1"], isDebugBuild: true))
        XCTAssertFalse(
            SessionSyncGate.isRegistrationAllowed(
                environment: ["HQ_ALLOW_SYSTEM_REGISTRATION": "1", "HQ_NO_SYSTEM_REGISTRATION": "1"], isDebugBuild: true))
        XCTAssertTrue(SessionSyncGate.isRegistrationAllowed(environment: [:], isDebugBuild: false))
        // This test build is a Debug build: its own sign-out stops nothing.
        XCTAssertFalse(SessionSyncAgent.disable(environment: [:]))
    }

    func testTheHelperIsNamedFromTheAppsBundleId() {
        XCTAssertEqual(SessionSyncAgent.identifier, HQIdentity.bundleID + ".session-sync")
        XCTAssertEqual(HQ.SessionSyncIdentity.appBundleID, HQIdentity.bundleID)
        XCTAssertTrue(SessionSyncAgent.helper.path.hasSuffix("Contents/Library/LoginItems/HQSessionSync.app"))
    }

    // MARK: Turning it on

    func testTheNoticeIsAnsweredBeforeAnythingIsConfiguredOrStarted() async {
        let recorder = Recorder()
        let outcome = await turnOn(recorder)
        XCTAssertEqual(outcome, .running)
        XCTAssertEqual(recorder.events, ["retire", "notice intro", "configure", "save", "start"])
        XCTAssertEqual(recorder.noticeServer, server)
        XCTAssertEqual(recorder.config?.hasAcceptedRules, true, "the answer is what lets the helper upload")
    }

    func testPauseInTheNoticeStartsNothingAndSticks() async {
        let recorder = Recorder()
        recorder.answer = .pause
        let outcome = await turnOn(recorder)
        XCTAssertEqual(outcome, .paused)
        XCTAssertEqual(recorder.events, ["retire", "notice intro", "save paused", "halt"])
        XCTAssertEqual(recorder.config?.paused, true)
        let again = await turnOn(recorder)
        XCTAssertEqual(again, .paused, "a later sign-in does not undo it")
        XCTAssertFalse(recorder.events.contains("start"))
    }

    func testClosingTheNoticeIsNoAnswer() async {
        let recorder = Recorder()
        recorder.answer = .dismissed
        let outcome = await turnOn(recorder)
        XCTAssertEqual(outcome, .unanswered)
        XCTAssertEqual(recorder.events, ["retire", "notice intro"])
        XCTAssertTrue(SessionSyncNotice.shouldShow(defaults: defaults, personID: "p1", baseURL: server), "it asks again")
    }

    func testTheNoticeIsShownOncePerPersonAndServer() async {
        let recorder = Recorder()
        _ = await turnOn(recorder)
        recorder.events = []
        _ = await turnOn(recorder)
        XCTAssertEqual(recorder.events, ["configure", "save", "start"], "no second notice")
        XCTAssertTrue(SessionSyncNotice.shouldShow(defaults: defaults, personID: "p2", baseURL: server))
        XCTAssertTrue(SessionSyncNotice.shouldShow(defaults: defaults, personID: "p1", baseURL: "https://other.example.test"))
    }

    func testResumeClearsAPauseAndStartsAfterTheNotice() async {
        let recorder = Recorder()
        recorder.config = HQ.SessionSyncConfig(enabled: false, personID: "p1", baseURL: server, sources: []).pausedByPerson()
        let blocked = await turnOn(recorder)
        XCTAssertEqual(blocked, .paused)
        XCTAssertTrue(recorder.events.isEmpty)
        let resumed = await turnOn(recorder, ignoringPause: true)
        XCTAssertEqual(resumed, .running)
        XCTAssertNil(recorder.config?.paused)
    }

    /// A local (ad-hoc) build never turns sync on: no notice, no sign-in hand-off, no login item.
    func testABuildWithoutATeamLeavesSyncOffAndSaysSo() async {
        let recorder = Recorder()
        let outcome = await SessionSyncAgent.turnOn(
            ada, environment: [:], defaults: defaults, isDebugBuild: false, effects: recorder.effects, isCurrent: { true },
            isBuilt: false)
        XCTAssertEqual(outcome, .unavailable)
        XCTAssertTrue(recorder.events.isEmpty)
        XCTAssertTrue(SessionSyncNotice.shouldShow(defaults: defaults, personID: "p1", baseURL: server), "no notice was marked")
        XCTAssertTrue(SessionSyncCard.unavailableLine.contains("HQ_SIGNING_MODE=team"))
        #if !HQ_SESSION_SYNC
        XCTAssertFalse(SessionSyncAgent.isBuilt, "a local build is not built for sync")
        #endif
    }

    func testSignedOutHasNothingToTurnOn() async {
        let recorder = Recorder()
        let outcome = await SessionSyncAgent.turnOn(
            nil, environment: [:], defaults: defaults, isDebugBuild: false, effects: recorder.effects, isCurrent: { true },
            isBuilt: true)
        XCTAssertEqual(outcome, .signedOut)
        XCTAssertTrue(recorder.events.isEmpty)
    }

    // MARK: The notice

    func testTheNoticeSaysWhatLeavesTheMacToWhomAndHowToStopIt() {
        let title = SessionSyncNotice.title(server: "https://hq.example.test:8443")
        let body = SessionSyncNotice.body(server: "https://hq.example.test:8443")
        XCTAssertTrue(title.contains("hq.example.test:8443"))
        for phrase in [
            "Claude Code and Codex", "last 7 days", "and new ones", "uploaded as text to hq.example.test:8443",
            "Everyone on this server and the person who runs it can read them",
            "best-effort", "Pause stops it",
        ] {
            XCTAssertTrue(body.contains(phrase), phrase)
        }
        XCTAssertEqual(SessionSyncNotice.host("not a url"), "your server")
        XCTAssertEqual(SessionSyncNotice.host("http://127.0.0.1:8790"), "127.0.0.1:8790")
    }

    func testANewVersionOfTheRulesIsShownAgain() {
        let next = SessionSyncConfig.currentRules + 1
        XCTAssertTrue(SessionSyncNotice.shouldShow(defaults: defaults, personID: "p1", baseURL: server))
        SessionSyncNotice.markShown(defaults: defaults, personID: "p1", baseURL: server)
        XCTAssertFalse(SessionSyncNotice.shouldShow(defaults: defaults, personID: "p1", baseURL: server))
        XCTAssertTrue(
            SessionSyncNotice.shouldShow(defaults: defaults, personID: "p1", baseURL: server, rules: next),
            "a notice that changed is asked again of everyone who answered the old one")
        SessionSyncNotice.markShown(defaults: defaults, personID: "p1", baseURL: server, rules: next)
        XCTAssertFalse(SessionSyncNotice.shouldShow(defaults: defaults, personID: "p1", baseURL: server, rules: next))
        XCTAssertNotEqual(
            SessionSyncNotice.shownKey(personID: "p1", baseURL: server),
            SessionSyncNotice.shownKey(personID: "p1", baseURL: server, rules: next))
    }

    // MARK: Sign-out and the helper's copy of the sign-in

    private func scratchDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hq-forget-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func add(_ item: String) { lock.withLock { items.append(item) } }
        var all: [String] { lock.withLock { items } }
    }

    func testTheForgetMarkerHoldsNoSecretAndLastsUntilItIsCleared() {
        let directory = scratchDirectory()
        XCTAssertFalse(ForgetPending.isSet(in: directory))
        ForgetPending.set(in: directory)
        XCTAssertTrue(ForgetPending.isSet(in: directory))
        XCTAssertEqual(try? Data(contentsOf: ForgetPending.file(in: directory)), Data(), "an empty file")
        ForgetPending.clear(in: directory)
        XCTAssertFalse(ForgetPending.isSet(in: directory))
    }

    func testAFailedForgetIsKeptAndRetriedUntilTheHelperSucceeds() async {
        let directory = scratchDirectory()
        ForgetPending.set(in: directory)
        let calls = Calls()
        await SessionSyncAgent.forgetSignIn(directory: directory) {
            calls.add("timed out")
            throw SessionSyncAgent.HelperFailure(status: 15)
        }
        XCTAssertTrue(ForgetPending.isSet(in: directory), "still owed")
        await SessionSyncAgent.forgetSignIn(directory: directory) {
            calls.add("helper exited 1")
            throw SessionSyncAgent.HelperFailure(status: 1)
        }
        XCTAssertTrue(ForgetPending.isSet(in: directory), "still owed")
        await SessionSyncAgent.forgetSignIn(directory: directory) { calls.add("done") }
        XCTAssertFalse(ForgetPending.isSet(in: directory), "cleared by the helper's success")
        await SessionSyncAgent.forgetSignIn(directory: directory) { calls.add("not owed") }
        XCTAssertEqual(calls.all, ["timed out", "helper exited 1", "done"], "nothing owed, nothing run")
    }

    func testANewSignInReplacesWhatASignOutOwed() async throws {
        let directory = scratchDirectory()
        ForgetPending.set(in: directory)
        let calls = Calls()
        try await SessionSyncAgent.configure(ada, base: server, directory: directory) { _ in calls.add("configure") }
        XCTAssertFalse(ForgetPending.isSet(in: directory))
        await SessionSyncAgent.forgetSignIn(directory: directory) { calls.add("forget") }
        XCTAssertEqual(calls.all, ["configure"], "a delete that was waiting never removes the new sign-in")
    }

    func testTheHandOffAndTheDeleteNeverRunAtTheSameTime() async throws {
        let directory = scratchDirectory()
        ForgetPending.set(in: directory)
        let calls = Calls()
        let signOut = Task {
            await SessionSyncAgent.forgetSignIn(directory: directory) {
                calls.add("forget start")
                try await Task.sleep(for: .milliseconds(300))
                calls.add("forget end")
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        let signIn = Task {
            try await SessionSyncAgent.configure(ada, base: server, directory: directory) { _ in
                calls.add("configure start")
                calls.add("configure end")
            }
        }
        await signOut.value
        try await signIn.value
        XCTAssertEqual(calls.all, ["forget start", "forget end", "configure start", "configure end"])
    }

    func testTheGateRunsWorkInTheOrderItArrivedAndOneAtATime() async {
        let gate = SerialGate()
        let calls = Calls()
        let tasks = (0..<4).map { index in
            Task {
                await gate.run {
                    calls.add("start \(index)")
                    try? await Task.sleep(for: .milliseconds(40))
                    calls.add("end \(index)")
                }
            }
        }
        for task in tasks {
            await task.value
        }
        let all = calls.all
        XCTAssertEqual(all.count, 8)
        for pair in stride(from: 0, to: 8, by: 2) {
            XCTAssertEqual(all[pair].dropFirst(6), all[pair + 1].dropFirst(4), "each piece ends before the next starts")
        }
    }

    // MARK: Running the helper

    private func run(
        _ path: String, _ arguments: [String] = [], input: Int = 16_000, timeout: TimeInterval = 20,
        writingAfter delay: TimeInterval = 0
    ) async throws {
        try await SessionSyncAgent.runHelper(
            executable: URL(fileURLWithPath: path), arguments, input: Data(repeating: 65, count: input),
            timeout: timeout, writingAfter: delay)
    }

    func testAHelperThatReadsItsInputAndExitsZeroSucceeds() async throws {
        try await run("/bin/cat")
    }

    func testAHelperThatFailsOrIsMissingThrows() async {
        do {
            try await run("/bin/sh", ["-c", "exit 3"])
            XCTFail("a helper that exits 3 must throw")
        } catch {
            XCTAssertEqual(error as? SessionSyncAgent.HelperFailure, .init(status: 3))
        }
        do {
            try await run("/nonexistent/helper")
            XCTFail("a missing helper must throw")
        } catch {
            XCTAssertNil(error as? SessionSyncAgent.HelperFailure)
        }
    }

    func testAHelperThatNeverAnswersIsStoppedAfterTheTimeout() async {
        let started = Date()
        do {
            try await run("/bin/sleep", ["30"], timeout: 0.5)
            XCTFail("a helper that never exits must be stopped")
        } catch {
            XCTAssertNotNil(error as? SessionSyncAgent.HelperFailure)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    func testAHelperThatExitsBeforeReadingDoesNotKillTheApp() async throws {
        // `true` has exited long before the input is written: the write meets a closed pipe
        // (SIGPIPE, which ends the process unless the pipe is told not to raise it).
        try? await run("/usr/bin/true", writingAfter: 0.3)
        try await Task.sleep(for: .seconds(1))
    }
}
