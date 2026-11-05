import XCTest

@testable import HQ

/// The desktop widgets' real networking, `WidgetAPI` and `HQClient`, against a real HQ Community
/// server: no fixtures and no mocks. A device mints a widget key; the key reads the summary and
/// nothing else; minting again or revoking ends it.
///
/// Skipped unless all three are set, as `LiveServerTests` is (pass them through `TEST_RUNNER_`,
/// which `xcodebuild` strips before handing them to the test host):
///
///     HQ_LIVE_SERVER   the server's address, e.g. http://127.0.0.1:18790
///     HQ_LIVE_KEY_A    an invite key for an admin named Ada
///     HQ_LIVE_KEY_B    an invite key for a member named Bo
///
/// The server needs the Tasks app (the summary is the person's tasks). Run against a throwaway
/// database: every run adds devices, widget keys and tasks.
@MainActor
final class LiveWidgetTests: XCTestCase {
    private struct Who {
        let response: HQClient.EnrollResponse
        var client: HQClient { HQClient(bearer: response.bearer) }
        var id: String { response.person.id }
    }

    private var server: String!
    private var keyA: String!
    private var keyB: String!
    private var previousServer: String?

    override func setUp() async throws {
        let env = ProcessInfo.processInfo.environment
        func value(_ name: String) -> String? {
            let text = env[name]?.trimmingCharacters(in: .whitespacesAndNewlines)
            return text?.isEmpty == false ? text : nil
        }
        guard let server = value("HQ_LIVE_SERVER"), let keyA = value("HQ_LIVE_KEY_A"),
              let keyB = value("HQ_LIVE_KEY_B")
        else { throw XCTSkip("HQ_LIVE_SERVER, HQ_LIVE_KEY_A and HQ_LIVE_KEY_B are not all set") }
        XCTAssertFalse(HQSimulatorFixture.isEnabled, "a live run must not be a fixture run")
        guard case .success(let normalized) = HQConfig.normalizedServer(server) else {
            throw XCTSkip("HQ_LIVE_SERVER is not a usable server address")
        }
        self.server = normalized
        self.keyA = keyA
        self.keyB = keyB
        previousServer = HQConfig.savedServer
        HQConfig.savedServer = normalized
    }

    override func tearDown() async throws {
        if server != nil { HQConfig.savedServer = previousServer }
    }

    // MARK: - Helpers

    private func signIn(_ key: String, _ name: String) async throws -> Who {
        Who(response: try await HQClient.enroll(key: key, personName: nil, deviceName: "LiveWidgetTests \(name)"))
    }

    /// The widget API on the bearer given: a device's, or a widget key.
    private func api(_ bearer: String) -> WidgetAPI {
        WidgetAPI(baseURL: URL(string: server)!, bearer: bearer)
    }

    private func tag() -> String {
        String(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(8))
    }

    /// The status the server refused the request with.
    private func refusal<T>(
        _ call: () async throws -> T, file: StaticString = #filePath, line: UInt = #line
    ) async -> WidgetAPI.Failure? {
        do {
            _ = try await call()
            XCTFail("the server accepted a request it should refuse", file: file, line: line)
        } catch let failure as WidgetAPI.Failure {
            return failure
        } catch {
            XCTFail("expected a refusal, got \(error)", file: file, line: line)
        }
        return nil
    }

    // MARK: - Tests

    func testADeviceMintsAKeyThatReadsTheSummaryAndNothingElse() async throws {
        let ada = try await signIn(keyA, "Ada")
        let word = tag()
        // A task in progress is listed first of its status, whatever else the person owes.
        let made = try await ada.client.createTask(title: "Widget \(word)", ownerPersonId: ada.id)
        _ = try await ada.client.updateTaskStatus(id: made.id, status: "in_progress")

        let key = try await api(ada.response.bearer).mintKey()
        XCTAssertTrue(key.hasPrefix("hq_widget_"), "a widget key says what it is")
        let widget = api(key)

        // The summary with the key decodes as the widgets decode it, and shows the task.
        let (summary, data) = try await widget.summary()
        XCTAssertEqual(summary.version, 1)
        XCTAssertEqual(summary.me.id, ada.id)
        XCTAssertEqual(summary.me.name, ada.response.person.name)
        let card = try XCTUnwrap(summary.work.tasks.first { $0.id == made.id })
        XCTAssertEqual(card.title, "Widget \(word)")
        XCTAssertEqual(card.status, "in_progress")
        XCTAssertEqual(card.ref, made.ref)
        XCTAssertGreaterThanOrEqual(summary.work.inProgress, 1)
        // The bytes the shelf would keep decode again, and carry no analytics or alerts.
        XCTAssertEqual(try WidgetSummary.decode(data), summary)
        let keys = Set(try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]).keys)
        XCTAssertEqual(keys, ["version", "generated_at", "me", "work"])
        // The device bearer reads the same summary.
        let (viaDevice, _) = try await api(ada.response.bearer).summary()
        XCTAssertEqual(viaDevice.work.tasks.map(\.id), summary.work.tasks.map(\.id))

        // The key works on no other route, and cannot mint another key.
                for path in ["/v1/conversations", "/v1/tasks", "/v1/people", "/v1/calls"] {
            let failure = await refusal { try await widget.request("GET", path) }
            XCTAssertEqual(failure?.status, 401, path)
        }
        let minted = await refusal { try await widget.mintKey() }
        XCTAssertEqual(minted?.status, 403)
        XCTAssertEqual(minted?.code, "device_bearer_required")
    }

    func testMintingAgainAndRevokingEndTheKey() async throws {
        let ada = try await signIn(keyA, "Ada")
        let device = api(ada.response.bearer)
        let first = try await device.mintKey()
        let second = try await device.mintKey()
        XCTAssertNotEqual(first, second)

        // Minting again ended the first key on this device.
        let stale = await refusal { try await api(first).summary() }
        XCTAssertEqual(stale?.status, 401)
        _ = try await api(second).summary()

        // Revoking ends the second, and nothing is left to revoke the second time.
        try await device.revokeKey()
        let revoked = await refusal { try await api(second).summary() }
        XCTAssertEqual(revoked?.status, 401)
        try await device.revokeKey()
        // The device itself carries on: a new key works.
        let third = try await device.mintKey()
        _ = try await api(third).summary()
    }

    func testEachPersonsKeyShowsOnlyTheirOwnTasks() async throws {
        let ada = try await signIn(keyA, "Ada")
        let bo = try await signIn(keyB, "Bo")
        let word = tag()
        for (who, title) in [(ada, "Ada's \(word)"), (bo, "Bo's \(word)")] {
            let task = try await who.client.createTask(title: title, ownerPersonId: who.id)
            _ = try await who.client.updateTaskStatus(id: task.id, status: "blocked")
        }

        let adaKey = try await api(ada.response.bearer).mintKey()
        let boKey = try await api(bo.response.bearer).mintKey()
        let (adas, _) = try await api(adaKey).summary()
        let (bos, _) = try await api(boKey).summary()
        XCTAssertEqual(adas.me.id, ada.id)
        XCTAssertEqual(bos.me.id, bo.id)
        XCTAssertTrue(adas.work.tasks.contains { $0.title == "Ada's \(word)" })
        XCTAssertFalse(adas.work.tasks.contains { $0.title == "Bo's \(word)" })
        XCTAssertTrue(bos.work.tasks.contains { $0.title == "Bo's \(word)" })
        XCTAssertFalse(bos.work.tasks.contains { $0.title == "Ada's \(word)" })
    }
}
