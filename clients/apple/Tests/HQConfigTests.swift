import XCTest

@testable import HQ

/// The Server field's rules: a bare host takes https, plain http is for this
/// machine or this network only, and what is typed comes back as a base URL.
final class HQConfigTests: XCTestCase {
    private func accepted(_ input: String) -> String? {
        if case .success(let url) = HQConfig.normalizedServer(input) { return url }
        return nil
    }

    func testABareHostTakesHttps() {
        XCTAssertEqual(accepted("hq.example.com"), "https://hq.example.com")
        XCTAssertEqual(accepted("  hq.example.com/  "), "https://hq.example.com")
        XCTAssertEqual(accepted("hq.example.com:8443"), "https://hq.example.com:8443")
    }

    func testHttpsIsKeptAndATrailingSlashIsDropped() {
        XCTAssertEqual(accepted("https://hq.example.com/"), "https://hq.example.com")
        XCTAssertEqual(accepted("https://hq.example.com/team/"), "https://hq.example.com/team")
        XCTAssertEqual(accepted("https://hq.example.com?x=1#frag"), "https://hq.example.com")
    }

    func testPlainHttpIsOnlyForLocalHosts() {
        XCTAssertEqual(accepted("http://localhost:8787"), "http://localhost:8787")
        XCTAssertEqual(accepted("http://127.0.0.1:8787"), "http://127.0.0.1:8787")
        XCTAssertEqual(accepted("http://studio.local"), "http://studio.local")
        XCTAssertEqual(accepted("localhost:8787"), "http://localhost:8787")
        XCTAssertEqual(accepted("studio.local"), "http://studio.local")
        XCTAssertNil(accepted("http://hq.example.com"))
        XCTAssertNil(accepted("http://192.168.1.20:8787"))
        XCTAssertNil(accepted("http://example.local.evil.com"))
    }

    func testNothingUsableIsRefused() {
        XCTAssertNil(accepted(""))
        XCTAssertNil(accepted("   "))
        XCTAssertNil(accepted("ftp://hq.example.com"))
        XCTAssertNil(accepted("https://"))
    }

    func testTheServerIsRememberedAndOnlyItsHostIsTrusted() {
        let previous = HQConfig.savedServer
        defer { HQConfig.savedServer = previous }
        HQConfig.savedServer = "https://hq.example.com:8443"
        XCTAssertTrue(HQConfig.isServerHost("HQ.example.com"))
        XCTAssertFalse(HQConfig.isServerHost("evil.example.org"))
        XCTAssertFalse(HQConfig.isServerHost(nil))
        XCTAssertTrue(HQConfig.isServerURL(URL(string: "https://hq.example.com/x")!))
        XCTAssertFalse(HQConfig.isServerURL(URL(string: "http://hq.example.com/x")!))
        XCTAssertEqual(HQConfig.storeSuffix, "@hq.example.com:8443")
        XCTAssertEqual(HQConfig.webSocketURL?.absoluteString, "wss://hq.example.com:8443/v1/ws")
    }

    func testNoServerMeansNoRequest() {
        let previous = HQConfig.savedServer
        defer { HQConfig.savedServer = previous }
        HQConfig.savedServer = nil
        XCTAssertEqual(HQConfig.baseURLString, "")
        XCTAssertFalse(HQConfig.isServerHost("hq.example.com"))
    }
}
