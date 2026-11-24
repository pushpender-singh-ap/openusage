import XCTest
@testable import OpenUsage

/// Antigravity hosted as an ACP agent by T3 Code: the agent process (`antigravity acp …`) serves the
/// local quota RPC, and its conversations live under T3 Code's own Gemini homes, not `~/.gemini`.
final class AntigravityACPHostTests: XCTestCase {
    private static let t3AgentCommand = "/Users/x/.t3/tools/antigravity-acp/darwin-arm64/versions/abc/antigravity acp "
        + "--gemini-dir /Users/x/.t3/userdata/providers/antigravity/def --app-data-dir antigravity-acp"

    private let acpOptions = LanguageServerDiscovery.Options(
        processName: "antigravity", markers: [], csrfFlag: "", portFlag: nil, subcommand: "acp"
    )

    // MARK: - Process discovery

    func testRankedCandidatesMatchTheACPAgentOnlyByItsSubcommand() {
        let ps = """
        4221 /Applications/Antigravity.app/Contents/MacOS/Antigravity
        4276 /Applications/Antigravity.app/Contents/Resources/bin/language_server --standalone --override_ide_name antigravity --csrf_token tok --app_data_dir antigravity
        4300 /Users/x/.gemini/antigravity/bin/agentapi
        55695 \(Self.t3AgentCommand)
        """
        XCTAssertEqual(LanguageServerDiscovery.rankedCandidates(psOutput: ps, options: acpOptions).map(\.pid), [55695])
        XCTAssertEqual(LanguageServerDiscovery.firstArgument(command: Self.t3AgentCommand), "acp")
        XCTAssertNil(LanguageServerDiscovery.firstArgument(command: "/Users/x/.local/bin/agy"))

        // The earlier `language_server` and `agy` probes must not claim the ACP agent.
        let agy = LanguageServerDiscovery.Options(processName: "agy", markers: [], csrfFlag: "", portFlag: nil)
        XCTAssertTrue(LanguageServerDiscovery.rankedCandidates(psOutput: "55695 \(Self.t3AgentCommand)", options: agy).isEmpty)
    }

    /// Regression: T3 Code's agent never matched discovery, so OpenUsage fell back to Cloud Code even
    /// while the agent was running. With no Keychain login, only the agent can supply this snapshot.
    @MainActor
    func testRefreshReadsQuotaFromTheACPAgent() async {
        let routing = RoutingHTTPClient { request in
            let path = request.url.path
            if path.hasSuffix("/RetrieveUserQuotaSummary") {
                let body = #"{"response":{"groups":[{"buckets":[{"bucketId":"gemini-5h","remainingFraction":0.63},{"bucketId":"3p-5h","remainingFraction":0}]}]}}"#
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8))
            }
            if path.hasSuffix("/GetUserStatus") {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"userStatus":{"userTier":{"name":"Google AI Pro"}}}"#.utf8))
            }
            return HTTPResponse(statusCode: 500, headers: [:], body: Data())
        }
        let provider = AntigravityProvider(
            authStore: AntigravityAuthStore(keychain: FakeKeychain(nil), files: FakeFiles()),
            usageClient: AntigravityUsageClient(lsHTTP: routing, http: routing),
            discovery: LanguageServerDiscovery(processRunner: ACPAgentProcessRunner(command: Self.t3AgentCommand)),
            dbUsageScanner: AntigravityDbUsageScanner(conversationsDirectories: { ["/nonexistent-antigravity-tests"] })
        )

        let snapshot = await provider.refresh()
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(snapshot.plan, "Pro")
        XCTAssertEqual(snapshot.lines.map(\.label), ["Session", "Claude"])
        XCTAssertTrue(routing.requests.allSatisfy { $0.url.host == "127.0.0.1" && $0.url.port == 60416 })
    }

    // MARK: - Conversation stores

    func testDiscoversConversationStoresUnderT3CodeGeminiHomes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        for path in ["def/antigravity-acp/conversations", "def/antigravity-cli", "def/config", "abc/antigravity-acp/conversations"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        try Data().write(to: root.appendingPathComponent(".DS_Store"))
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let homes = try AntigravityDbUsageScanner.geminiHomes(underT3Root: root.path)
        XCTAssertEqual(homes, [root.path + "/abc", root.path + "/def"], "a stray file is not a Gemini home")
        XCTAssertEqual(
            try homes.flatMap { try AntigravityDbUsageScanner.conversationsDirectories(underGeminiHome: $0) },
            [
                root.path + "/abc/antigravity-acp/conversations",
                root.path + "/def/antigravity-acp/conversations",
                root.path + "/def/antigravity-cli/conversations",
            ]
        )
        XCTAssertEqual(try AntigravityDbUsageScanner.geminiHomes(underT3Root: "/nonexistent-\(UUID().uuidString)"), [])
    }
}

/// `ps` lists only the given agent command; `lsof` reports its HTTPS RPC port.
private struct ACPAgentProcessRunner: ProcessRunning {
    let command: String

    func run(executable: String, arguments: [String], environment: [String: String], timeout: TimeInterval) throws -> ProcessResult {
        if executable.hasSuffix("/ps") {
            return ProcessResult(exitCode: 0, stdout: "55695 \(command)\n", stderr: "")
        }
        let lsof = "antigravi 55695 user 12u IPv4 0x0 0t0 TCP 127.0.0.1:60416 (LISTEN)\n"
        return ProcessResult(exitCode: 0, stdout: lsof, stderr: "")
    }
}
