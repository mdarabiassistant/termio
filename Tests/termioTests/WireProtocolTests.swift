@testable import termio
import TermioShared
import XCTest

final class WireProtocolTests: XCTestCase {
    /// The keys every wire-2 project carries, spliced into the fixtures below so
    /// each test is about the one tolerance it names rather than about these.
    private static let workspaceFields =
        #""workspaceID":"w1","workspaceName":"Sessions","branch":"","kind":"folder""#

    /// The wire-2 break, stated as a test: a project from a v1 Mac names no
    /// workspace, so it is unreadable rather than half-read. The version gate is
    /// what turns that into "update the other end"; this only pins that the
    /// decoder does not quietly invent a workspace for it.
    func testProjectWithoutAWorkspaceIsUnreadable() throws {
        let json = #"""
        {"t":"roster","projects":[{"id":"p1","name":"termio","path":"/tmp/termio","sessions":[]}]}
        """#

        let decoded = try XCTUnwrap(CompanionRoster.decode(json))

        XCTAssertEqual(decoded.projects, [])
    }

    func testAuthRoundTripCarriesCurrentWireVersion() {
        let auth = CompanionControl.auth(token: "pairing-token", wire: Wire.current)

        XCTAssertEqual(CompanionControl.decode(auth.encoded()), auth)
    }

    func testSessionRenameRoundTripsArbitraryNamesAndCorrelatedResults() {
        let name = "Release \"λ\" 日本語 \\ branch"
        let request = CompanionControl.renameSession(sessionID: "session-id", name: name, requestID: "request-id")
        XCTAssertEqual(CompanionControl.decode(request.encoded()), request)
        for error: String? in [nil, "The machine is offline."] {
            let reply = CompanionControl.sessionRenamed(
                sessionID: "session-id", name: name, requestID: "request-id", error: error)
            XCTAssertEqual(CompanionControl.decode(reply.encoded()), reply)
        }
        for malformed in [
            #"{"t":"renameSession","session":"s","name":"n"}"#,
            #"{"t":"renameSession","session":"s","name":42,"request":"r"}"#,
            #"{"t":"sessionRenamed","name":"n","request":"r"}"#,
        ] {
            XCTAssertNil(CompanionControl.decode(malformed))
        }
        XCTAssertEqual(Wire.minimumClient, 2)
        XCTAssertEqual(Wire.minimumServer, 2)
    }

    func testAuthWithoutWireDecodesAsLegacy() {
        XCTAssertEqual(
            CompanionControl.decode(#"{"t":"auth","token":"pairing-token"}"#),
            .auth(token: "pairing-token", wire: Wire.legacy)
        )
    }

    func testChiefSendAndNoticeRoundTripArbitraryText() throws {
        let text = "Which \"λ\" session?\nLook in ~/src\\project 日本語"
        let notice = WireNotice(id: "n1", from: "chief", about: "worker", title: "Needs you",
                                body: text, at: 1_792_580_000_123)
        for control: CompanionControl in [
            .send(sessionID: "chief", text: text), .sent(sessionID: "chief"), .notice(notice),
            .notice(WireNotice(id: "n2", from: "chief", title: "Chief of Staff", body: text,
                               at: 1_792_580_000_456, speak: false)),
            .auth(token: "paired", wire: Wire.current, lastNoticeID: "n1"),
        ] {
            XCTAssertEqual(CompanionControl.decode(control.encoded()), control)
        }
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(CompanionControl.notice(notice).encoded().utf8)) as? [String: Any])
        XCTAssertEqual(fields["from"] as? String, "chief")
        XCTAssertEqual(fields["about"] as? String, "worker")
        XCTAssertNil(fields["speak"], "normal notices keep the agreed minimal shape")
        XCTAssertEqual(Wire.current, 4)
        XCTAssertEqual(Wire.minimumClient, 2, "older phones retain their terminal access")
    }

    func testChiefMessagesRejectMissingOrWrongRequiredFields() {
        for malformed in [
            #"{"t":"send","text":"hello"}"#,
            #"{"t":"send","session":"chief","text":42}"#,
            #"{"t":"sent"}"#,
            #"{"t":"notice","id":"n","from":"chief","title":"title","body":"body"}"#,
            #"{"t":"notice","id":"n","from":"chief","title":"title","body":"body","at":"yesterday"}"#,
        ] {
            XCTAssertNil(CompanionControl.decode(malformed))
        }
    }

    func testRosterRoleIsOptionalAndOrdinarySessionsOmitIt() throws {
        let ordinary = RosterSession(id: "s", title: "Shell", agent: "terminal", status: "idle")
        let chief = RosterSession(id: "c", title: "Chief", agent: "claude", status: "idle", role: "chief")
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        XCTAssertEqual(try decoder.decode(RosterSession.self, from: encoder.encode(chief)), chief)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(ordinary)) as? [String: Any])
        XCTAssertNil(fields["role"])
        let old = Data(#"{"id":"old","title":"Shell","agent":"terminal","status":"idle"}"#.utf8)
        XCTAssertNil(try decoder.decode(RosterSession.self, from: old).role)
    }

    @MainActor
    func testChiefWireAuthenticatesSendsWithoutAttachAndReplaysOnlyUnseenLatestNotice() async throws {
        var delivered: [(String, String)] = []
        var attachments = 0
        var latest = WireNotice(id: "latest", from: "chief", about: "worker",
                                title: "Chief", body: "Choose a path.", at: 123)
        let server = CompanionServer(
            port: 0, rosterProvider: { CompanionRoster(projects: []) },
            attachSession: { _ in attachments += 1; return nil },
            startSession: { _, _ in XCTFail("send must not start a session"); return nil },
            stopSession: { _ in false }, startScratchTerminal: { _ in nil },
            startSSHSession: { _, _ in nil }, renameSession: { _, _, _ in },
            sendToChief: { session, text in
                delivered.append((session, text))
                return .sent(sessionID: session)
            }, latestChiefNotice: { latest }, pairingToken: { "test-token" })
        server.start()
        defer { server.stop() }
        for _ in 0..<200 where (server.listeningPort ?? 0) == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        let port = try XCTUnwrap(server.listeningPort)
        let url = try XCTUnwrap(URL(string: "ws://127.0.0.1:\(port)/"))
        let client = URLSession(configuration: .ephemeral)
        defer { client.invalidateAndCancel() }

        let unpaired = client.webSocketTask(with: url)
        unpaired.resume()
        try await unpaired.send(.string(CompanionControl.send(sessionID: "chief", text: "hello").encoded()))
        let refusal = CompanionControl.decode(try await receiveText(unpaired))
        guard case .error(_, let refusalCode) = refusal else { return XCTFail("Unpaired send was accepted") }
        XCTAssertEqual(refusalCode, WireRefusal.unauthorized)
        XCTAssertTrue(delivered.isEmpty)
        unpaired.cancel(with: .goingAway, reason: nil)

        let paired = client.webSocketTask(with: url)
        paired.resume()
        try await paired.send(.string(CompanionControl.auth(token: "test-token", wire: Wire.current).encoded()))
        let firstRoster = try await receiveText(paired)
        XCTAssertNotNil(CompanionRoster.decode(firstRoster))
        let replay = try await receiveText(paired)
        XCTAssertEqual(CompanionControl.decode(replay), .notice(latest))
        let text = "Which session needs me?\nKeep the \"λ\" details."
        try await paired.send(.string(CompanionControl.send(sessionID: "chief", text: text).encoded()))
        let sent = try await receiveText(paired)
        XCTAssertEqual(CompanionControl.decode(sent), .sent(sessionID: "chief"))
        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(delivered.first?.0, "chief")
        XCTAssertEqual(delivered.first?.1, text)
        XCTAssertEqual(attachments, 0)
        let ordinary = WireNotice(id: "ordinary", from: "worker", title: "Worker", body: "Done.", at: 124)
        server.publishNotice(ordinary)
        let forwarded = try await receiveText(paired)
        XCTAssertEqual(CompanionControl.decode(forwarded), .notice(ordinary))
        paired.cancel(with: .goingAway, reason: nil)

        let seen = client.webSocketTask(with: url)
        seen.resume()
        try await seen.send(.string(CompanionControl.auth(
            token: "test-token", wire: Wire.current, lastNoticeID: latest.id).encoded()))
        let seenRoster = try await receiveText(seen)
        XCTAssertNotNil(CompanionRoster.decode(seenRoster))
        try await seen.send(.string(CompanionControl.send(sessionID: "chief", text: "again").encoded()))
        let afterSeen = try await receiveText(seen)
        XCTAssertEqual(CompanionControl.decode(afterSeen), .sent(sessionID: "chief"),
                       "the next message must be the acknowledgement, not a duplicate notice")
        seen.cancel(with: .goingAway, reason: nil)

        latest = WireNotice(id: "newest", from: "chief", title: "Chief", body: "New answer.", at: 125)
        let reconnected = client.webSocketTask(with: url)
        reconnected.resume()
        try await reconnected.send(.string(CompanionControl.auth(
            token: "test-token", wire: Wire.current, lastNoticeID: "latest").encoded()))
        _ = try await receiveText(reconnected)
        let newest = try await receiveText(reconnected)
        XCTAssertEqual(CompanionControl.decode(newest), .notice(latest))
        reconnected.cancel(with: .goingAway, reason: nil)

        let older = client.webSocketTask(with: url)
        older.resume()
        try await older.send(.string(CompanionControl.auth(token: "test-token", wire: 3).encoded()))
        let oldRoster = try await receiveText(older)
        XCTAssertNotNil(CompanionRoster.decode(oldRoster))
        server.publishNotice(ordinary)
        try await older.send(.string(CompanionControl.send(sessionID: "chief", text: "old").encoded()))
        let oldReply = CompanionControl.decode(try await receiveText(older))
        guard case .error(_, let oldCode) = oldReply else { return XCTFail("Older phone got a notice or sent text") }
        XCTAssertEqual(oldCode, WireRefusal.clientTooOld)
        XCTAssertEqual(delivered.count, 2)
        XCTAssertEqual(attachments, 0)
        older.cancel(with: .goingAway, reason: nil)
    }

    private func receiveText(_ socket: URLSessionWebSocketTask) async throws -> String {
        let message = try await withThrowingTaskGroup(of: URLSessionWebSocketTask.Message.self) { group in
            group.addTask { try await socket.receive() }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                socket.cancel(with: .goingAway, reason: nil)
                throw NSError(domain: "WireProtocolTests", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for a wire message"])
            }
            defer { group.cancelAll() }
            let next = try await group.next()
            return try XCTUnwrap(next)
        }
        guard case .string(let text) = message else {
            throw NSError(domain: "WireProtocolTests", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Expected a text frame"])
        }
        return text
    }

    func testRosterRoundTripCarriesCurrentWireVersion() throws {
        let roster = CompanionRoster(projects: [])

        let decoded = try XCTUnwrap(CompanionRoster.decode(roster.encodedJSON()))
        XCTAssertEqual(decoded, roster)
        XCTAssertEqual(decoded.wire, Wire.current)
    }

    func testRosterWithoutWireDecodesAsLegacy() throws {
        let decoded = try XCTUnwrap(
            CompanionRoster.decode(#"{"t":"roster","projects":[]}"#)
        )

        XCTAssertEqual(decoded.wire, Wire.legacy)
    }

    /// The whole point: one session the phone can't read costs that row, not the
    /// tree. Before lossy decoding this returned nil and the phone showed an
    /// empty app.
    func testRosterDropsOnlyTheUnreadableSession() throws {
        let json = """
        {"t":"roster","projects":[{"id":"p1","name":"termio","path":"/tmp/termio",\
        \(Self.workspaceFields),"sessions":[\
        {"id":"s1","title":"Good","agent":"claude","status":"idle"},\
        {"id":"s2","title":"Missing agent and status"},\
        {"id":"s3","title":"Also good","agent":"codex","status":"working"}]}]}
        """

        let decoded = try XCTUnwrap(CompanionRoster.decode(json))

        XCTAssertEqual(decoded.projects.count, 1)
        XCTAssertEqual(decoded.projects.first?.sessions.map(\.id), ["s1", "s3"])
    }

    func testRosterDropsOnlyTheUnreadableProject() throws {
        let json = """
        {"t":"roster","projects":[\
        {"id":"p1","name":"termio","path":"/tmp/termio",\(Self.workspaceFields),"sessions":[]},\
        {"name":"no id","path":"/tmp/broken",\(Self.workspaceFields),"sessions":[]},\
        {"id":"p3","name":"other","path":"/tmp/other",\(Self.workspaceFields),"sessions":[]}]}
        """

        let decoded = try XCTUnwrap(CompanionRoster.decode(json))

        XCTAssertEqual(decoded.projects.map(\.id), ["p1", "p3"])
    }

    /// A session from a newer Mac carrying fields this build never heard of
    /// still decodes — unknown keys are ignored, not fatal.
    func testRosterKeepsSessionWithUnknownFields() throws {
        let json = """
        {"t":"roster","projects":[{"id":"p1","name":"termio","path":"/tmp/termio",\
        \(Self.workspaceFields),"sessions":[\
        {"id":"s1","title":"Good","agent":"claude","status":"idle","somethingNewer":{"a":1}}]}]}
        """

        let decoded = try XCTUnwrap(CompanionRoster.decode(json))

        XCTAssertEqual(decoded.projects.first?.sessions.map(\.id), ["s1"])
    }

    /// An unknown tag has to arrive as a value, not as nil: the drop is only
    /// loggable if the receiver is handed something.
    func testUnknownControlTypeDecodesAsUnsupported() {
        XCTAssertEqual(
            CompanionControl.decode(#"{"t":"somethingFromANewerPhone","x":1}"#),
            .unsupported(type: "somethingFromANewerPhone")
        )
    }

    func testMalformedControlFrameStillDecodesToNil() {
        XCTAssertNil(CompanionControl.decode("not json at all"))
    }

    /// A bad element is not always an object. The slot-consuming decode has to
    /// swallow scalars, null, and arrays too, or the array truncates at the
    /// first one of those and everything after it is lost.
    func testRosterSkipsNonObjectSessionEntries() throws {
        for bad in ["null", "42", #""a string""#, "[1,2]", "[]", "true"] {
            let json = """
            {"t":"roster","projects":[{"id":"p1","name":"termio","path":"/tmp/termio",\
            \(Self.workspaceFields),"sessions":[\
            {"id":"s1","title":"Good","agent":"claude","status":"idle"},\
            \(bad),\
            {"id":"s3","title":"Also good","agent":"codex","status":"working"}]}]}
            """

            let decoded = try XCTUnwrap(CompanionRoster.decode(json), "failed for \(bad)")

            XCTAssertEqual(
                decoded.projects.first?.sessions.map(\.id), ["s1", "s3"],
                "the element after \(bad) was lost"
            )
        }
    }

    func testRosterDropsOnlyTheUnreadableAgent() throws {
        let json = """
        {"t":"roster","projects":[],"agents":[\
        {"id":"claude","name":"Claude Code"},\
        {"id":"missing name"},\
        {"id":"codex","name":"Codex"}]}
        """

        let decoded = try XCTUnwrap(CompanionRoster.decode(json))

        XCTAssertEqual(decoded.agents.map(\.id), ["claude", "codex"])
    }

    /// `RosterProject` decodes through a hand-written `init(from:)` while its
    /// encoder stays synthesized, so the two can drift apart. Every optional
    /// field has to be populated or the round trip proves nothing.
    func testPopulatedRosterRoundTrips() throws {
        let roster = CompanionRoster(
            projects: [
                RosterProject(
                    id: "p1", name: "termio", path: "/tmp/termio",
                    workspaceID: "w1", workspaceName: "ukvps", deviceAlias: "ukvps",
                    branch: "fix/wire-tolerance", kind: "folder",
                    sessions: [
                        RosterSession(
                            id: "s1", title: "Session", agent: "claude", status: "working",
                            subtitle: "Working — Bash", branch: "fix/wire-tolerance"
                        )
                    ]
                )
            ],
            agents: [RosterAgent(id: "claude", name: "Claude Code", tintHex: "#D97757")]
        )

        XCTAssertEqual(CompanionRoster.decode(roster.encodedJSON()), roster)
    }

    /// Re-encoding an unsupported message must not hand a peer the command this
    /// build refused to read: `.unsupported("startTerminal")` may never come
    /// back out as a real `.startTerminal`.
    func testUnsupportedDoesNotReEncodeAsARealCommand() {
        let unsupported = CompanionControl.unsupported(type: "startTerminal")

        XCTAssertNotEqual(
            CompanionControl.decode(unsupported.encoded()), .startTerminal(workspaceID: nil))
        XCTAssertEqual(CompanionControl.decode(unsupported.encoded()), unsupported)
    }

    /// The workspace a phone-started terminal lands in is additive: a phone that
    /// predates the field sends the older shape, and it has to keep meaning what
    /// it meant — "the Mac picks" — rather than failing to decode.
    func testStartWithoutAWorkspaceStillDecodes() {
        XCTAssertEqual(
            CompanionControl.decode(#"{"t":"startTerminal"}"#), .startTerminal(workspaceID: nil))
        XCTAssertEqual(
            CompanionControl.decode(#"{"t":"startSSH","host":"vps"}"#),
            .startSSH(host: "vps", workspaceID: nil))
    }

    /// And a named workspace survives the round trip, so the Mac resolves the
    /// funnel where the phone said rather than where its own window is pointed.
    func testStartCarriesItsWorkspace() {
        let terminal = CompanionControl.startTerminal(workspaceID: "WS-1")
        let ssh = CompanionControl.startSSH(host: "vps", workspaceID: "WS-2")

        XCTAssertEqual(CompanionControl.decode(terminal.encoded()), terminal)
        XCTAssertEqual(CompanionControl.decode(ssh.encoded()), ssh)
    }

    /// Both ends build a loose section's wire id, so a phone can address the
    /// Chats funnel of a workspace the Mac has not opened one in yet.
    @MainActor
    func testLooseSectionIDMatchesTheMacsOwn() {
        let workspace = Workspace(name: "Alpha")

        XCTAssertEqual(
            TermioStore.looseWireID(workspace: workspace, chats: true),
            Wire.looseSectionID(workspaceID: workspace.id.uuidString, chats: true))
        XCTAssertEqual(
            TermioStore.looseWireID(workspace: workspace, chats: false),
            Wire.looseSectionID(workspaceID: workspace.id.uuidString, chats: false))
    }

    /// The tag reaches a `.public` log field and a paired phone picks it, so a
    /// newline in it would forge a log line and a long one would bury its
    /// neighbours.
    func testLoggableTagCannotForgeALogLine() {
        let forged = CompanionServer.loggableTag("secret-value\nmisleading log text")

        XCTAssertFalse(forged.contains("\n"))
        XCTAssertFalse(forged.contains(" "))
        XCTAssertEqual(forged, "secret-value?misleading?log?text")
    }

    func testLoggableTagIsBounded() {
        XCTAssertEqual(CompanionServer.loggableTag(String(repeating: "a", count: 500)).count, 40)
    }

    func testLoggableTagKeepsRealTagsReadable() {
        XCTAssertEqual(CompanionServer.loggableTag("startTerminal"), "startTerminal")
        XCTAssertEqual(CompanionServer.loggableTag("read-file_v2.1"), "read-file_v2.1")
        XCTAssertEqual(CompanionServer.loggableTag(""), "(empty)")
    }
}

/// A refusal is the one server message a person has to read and act on, and the
/// Mac has no idea what language the phone is in. The code is what the phone
/// words; the English is what a phone too old to know the code shows instead —
/// so a refusal that loses either half loses a reader.
final class WireRefusalTests: XCTestCase {
    func testARefusalCarriesItsCodeAndItsEnglish() throws {
        let message = CompanionControl.error(
            message: "Update Termio on your phone to connect to this Mac.",
            code: WireRefusal.clientTooOld
        )

        let decoded = try XCTUnwrap(CompanionControl.decode(message.encoded()))

        XCTAssertEqual(decoded, message)
    }

    /// An older Mac sends no code at all. Its sentence still has to arrive.
    func testARefusalWithoutACodeStillDecodes() throws {
        let decoded = try XCTUnwrap(
            CompanionControl.decode(#"{"t":"error","message":"unknown project"}"#))

        XCTAssertEqual(decoded, .error(message: "unknown project", code: nil))
    }

    /// Errors that are not refusals stay codeless, so the phone shows the Mac's
    /// own words rather than a wording table entry that does not exist.
    func testARequestErrorNamesNoCode() {
        let encoded = CompanionControl.error(message: "unknown project").encoded()

        XCTAssertEqual(encoded, #"{"t":"error","message":"unknown project"}"#)
    }

    func testAQuoteInARefusalSurvivesEncoding() throws {
        let message = CompanionControl.error(
            message: #"could not read "a".txt"#, code: WireRefusal.unauthorized)

        let decoded = try XCTUnwrap(CompanionControl.decode(message.encoded()))

        XCTAssertEqual(decoded, message)
    }
}
