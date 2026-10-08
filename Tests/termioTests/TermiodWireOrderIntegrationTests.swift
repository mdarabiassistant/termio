import XCTest
import TermioShared
@testable import termio

/// Roster-then-exit ordering, against a real daemon and this app's real client.
///
/// The two halves of session-fact reporting are each tested against their own
/// fixtures — Rust encodes what it says it encodes, Swift decodes what it says
/// it decodes — and that pair of green suites still says nothing about the one
/// thing a user sees: a live row that updates while a session runs and then
/// settles onto its final state, in that order. A decode test cannot catch a
/// field the daemon never actually sends, an ordering the fan-out does not
/// preserve, or an exit row that overwrites the live cache on the way past.
///
/// Opt-in on the same terms as `TermiodFilesIntegrationTests`: point
/// `TERMIO_TERMIOD_TEST_BIN` at a built `termiod` and it runs, otherwise it
/// skips, so `swift test` never grows a cargo dependency.
final class TermiodWireOrderIntegrationTests: XCTestCase {
    private var binary = ""
    private var daemon: Process?
    private var socketDirectory: URL?

    override func setUpWithError() throws {
        try super.setUpWithError()
        let configured = ProcessInfo.processInfo.environment["TERMIO_TERMIOD_TEST_BIN"] ?? ""
        try XCTSkipIf(configured.isEmpty, "set TERMIO_TERMIOD_TEST_BIN to run this")
        binary = configured

        // Short socket directory name: `sun_path` is capped at 104 bytes and the
        // per-user temp directory already spends half of it.
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("two-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        socketDirectory = directory
        let socket = directory.appendingPathComponent("termiod.sock").path
        XCTAssertLessThan(socket.utf8.count, 104, "socket path must fit sun_path")
        setenv("TERMIOD_SOCK", socket, 1)

        let serve = Process()
        serve.executableURL = URL(fileURLWithPath: binary)
        serve.arguments = ["serve"]
        serve.environment = ProcessInfo.processInfo.environment.merging(
            ["TERMIOD_SOCK": socket]) { _, new in new }
        serve.standardOutput = FileHandle.nullDevice
        serve.standardError = FileHandle.nullDevice
        try serve.run()
        daemon = serve

        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: socket), Date() < deadline {
            usleep(50_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: socket), "daemon never bound")
    }

    override func tearDownWithError() throws {
        daemon?.terminate()
        daemon?.waitUntilExit()
        if let socketDirectory {
            try? FileManager.default.removeItem(at: socketDirectory)
        }
        unsetenv("TERMIOD_SOCK")
        try super.tearDownWithError()
    }

    func testSessionNamesAreFetchedByIndependentClientsAndDoNotChangeIdentity() throws {
        let handle = "name-test-\(UUID().uuidString.prefix(8))"
        let link = TermiodSessionLink(
            sessionName: handle,
            specification: Termiod.CreateSpecification(
                cwd: NSTemporaryDirectory(), argv: ["/bin/cat"], env: [], rows: 24, cols: 80,
                customName: "Creation name"), rows: 24, cols: 80)
        let attached = expectation(description: "session exists")
        link.onDaemonSessionID = { _ in attached.fulfill() }
        link.start()
        defer { link.detach() }
        wait(for: [attached], timeout: 10)
        // Every call opens a separate control connection, as independent viewers do.
        let first = try XCTUnwrap(Termiod.roster().sessions.first { $0.name == handle })
        XCTAssertEqual(first.customName, "Creation name")
        XCTAssertEqual(first.customNameRevision, 1)
        let renamed = try XCTUnwrap(Termiod.setSessionName(
            target: first.id, name: "Renamed λ", ifUnset: false))
        XCTAssertEqual(renamed.customNameRevision, 2)
        let fetched = try XCTUnwrap(Termiod.roster().sessions.first { $0.id == first.id })
        XCTAssertEqual(fetched.customName, "Renamed λ")
        XCTAssertEqual(fetched.name, handle)
        XCTAssertEqual(fetched.pid, first.pid)
        XCTAssertEqual(fetched.title, first.title)
        _ = try Termiod.setSessionName(target: first.id, name: nil, ifUnset: false)
        _ = try Termiod.setSessionName(target: first.id, name: "Stale cached name", ifUnset: true)
        let cleared = try XCTUnwrap(Termiod.roster().sessions.first { $0.id == first.id })
        XCTAssertNil(cleared.customName)
        XCTAssertEqual(cleared.customNameRevision, 3)
        XCTAssertEqual(cleared.pid, first.pid)
    }

    @MainActor
    func testStoreMigratesAnExistingNameAndPublishesSubsequentEdits() async throws {
        var session = Session(title: "Terminal 1", agent: .terminal)
        session.givenTitle = "Legacy owner name"
        var workspace = Workspace(name: "Local")
        workspace.terminals = [session]
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "name-store-\(UUID().uuidString)"))
        let store = TermioStore(workspaces: [workspace], projects: [], settings: AppSettings(defaults: defaults))
        let link = TermiodSessionLink(
            sessionName: session.id.uuidString,
            specification: Termiod.CreateSpecification(
                cwd: NSTemporaryDirectory(), argv: ["/bin/cat"], env: [], rows: 24, cols: 80),
            rows: 24, cols: 80)
        let attached = expectation(description: "legacy session exists")
        link.onDaemonSessionID = { _ in attached.fulfill() }
        link.start()
        defer { link.detach() }
        await fulfillment(of: [attached], timeout: 10)
        let device = KnownDevice(alias: nil, deviceID: nil)
        store.reconcileExternalSessions(try Termiod.roster().sessions, from: device, route: .local)
        for _ in 0..<500 where store.session(session.id)?.pendingName != nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(store.session(session.id)?.pendingName)
        let migrated = try XCTUnwrap(Termiod.roster().sessions.first { $0.name == session.id.uuidString })
        XCTAssertEqual(migrated.customName, "Legacy owner name")
        store.setSessionName("Edited in client", for: session.id)
        for _ in 0..<500 where store.session(session.id)?.pendingName != nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(store.session(session.id)?.pendingName)
        XCTAssertEqual(try Termiod.roster().sessions.first { $0.id == migrated.id }?.customName, "Edited in client")
        _ = try Termiod.setSessionName(target: migrated.id, name: "Edited elsewhere", ifUnset: false)
        store.reconcileExternalSessions(try Termiod.roster().sessions, from: device, route: .local)
        XCTAssertEqual(store.session(session.id)?.givenTitle, "Edited elsewhere")
        XCTAssertNil(store.session(session.id)?.pendingName)
    }

    /// What arrived, in the order it arrived. Recorded rather than asserted
    /// inline because the claim under test *is* the sequence.
    private enum Arrival {
        case information(Termiod.SessionInformation)
        case exit(Int32, Termiod.SessionInformation?)
    }

    @MainActor
    func testCompanionRenameConfirmsTheDaemonAndAnotherClientSeesTheSameName() async throws {
        let session = Session(title: "Terminal 1", agent: .terminal)
        var workspace = Workspace(name: "Local")
        workspace.terminals = [session]
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "companion-rename-\(UUID().uuidString)"))
        let store = TermioStore(workspaces: [workspace], projects: [], settings: AppSettings(defaults: defaults))
        let link = TermiodSessionLink(
            sessionName: session.id.uuidString,
            specification: Termiod.CreateSpecification(
                cwd: NSTemporaryDirectory(), argv: ["/bin/cat"], env: [], rows: 24, cols: 80),
            rows: 24, cols: 80)
        let attached = expectation(description: "session exists")
        link.onDaemonSessionID = { _ in attached.fulfill() }
        link.start()
        defer { link.detach() }
        await fulfillment(of: [attached], timeout: 10)
        let original = try XCTUnwrap(Termiod.roster().sessions.first { $0.name == session.id.uuidString })
        store.recordDaemonSessionID(original.id, for: session.id)
        let server = CompanionServer(
            port: 0, rosterProvider: { store.companionRoster() }, attachSession: { _ in nil },
            startSession: { _, _ in nil }, stopSession: { _ in false },
            startScratchTerminal: { _ in nil }, startSSHSession: { _, _ in nil },
            renameSession: { id, name, completion in
                store.companionRenameSession(sessionID: id, name: name, completion: completion)
            })
        server.start()
        defer { server.stop() }
        for _ in 0..<200 where (server.listeningPort ?? 0) == 0 { try await Task.sleep(for: .milliseconds(5)) }
        let port = try XCTUnwrap(server.listeningPort)
        let url = try XCTUnwrap(URL(string: "ws://127.0.0.1:\(port)/"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        let client = URLSession(configuration: configuration)
        defer { client.invalidateAndCancel() }
        let unpaired = client.webSocketTask(with: url)
        unpaired.resume()
        try await unpaired.send(.string(CompanionControl.renameSession(
            sessionID: session.id.uuidString, name: "Unpaired edit", requestID: "unpaired").encoded()))
        if case .string(let text) = try await unpaired.receive(),
           case .error(_, let code) = CompanionControl.decode(text) {
            XCTAssertEqual(code, WireRefusal.unauthorized)
        } else { XCTFail("An unpaired rename must be refused") }
        XCTAssertNil(store.session(session.id)?.givenTitle)
        unpaired.cancel(with: .goingAway, reason: nil)
        let paired = client.webSocketTask(with: url)
        paired.resume()
        defer { paired.cancel(with: .goingAway, reason: nil) }
        try await paired.send(.string(CompanionControl.auth(token: PairingToken.current, wire: Wire.current).encoded()))
        if case .string(let text) = try await paired.receive() {
            XCTAssertNotNil(CompanionRoster.decode(text))
        } else { XCTFail("Authentication must return the roster") }
        for name in ["  New Session  ", "  Release \"λ\" 日本語  ", "Terminal 9"] {
            let requestID = UUID().uuidString
            try await paired.send(.string(CompanionControl.renameSession(
                sessionID: session.id.uuidString, name: name, requestID: requestID).encoded()))
            var confirmed = false
            while !confirmed {
                guard case .string(let text) = try await paired.receive() else { continue }
                guard case .sessionRenamed(let id, let echoedName, let request, let error) = CompanionControl.decode(text) else { continue }
                XCTAssertEqual(id, session.id.uuidString)
                XCTAssertEqual(echoedName, name.trimmingCharacters(in: .whitespacesAndNewlines))
                XCTAssertEqual(request, requestID)
                XCTAssertNil(error)
                confirmed = true
            }
            let fetched = try XCTUnwrap(Termiod.roster().sessions.first { $0.id == original.id })
            XCTAssertEqual(fetched.customName, name.trimmingCharacters(in: .whitespacesAndNewlines))
            XCTAssertEqual(fetched.name, original.name)
            XCTAssertEqual(fetched.pid, original.pid)
            XCTAssertNil(store.session(session.id)?.pendingName)
            let nativeRow = store.companionRoster().projects.flatMap(\.sessions).first { $0.id == session.id.uuidString }
            XCTAssertEqual(nativeRow?.title, fetched.customName)
            let otherDefaults = try XCTUnwrap(UserDefaults(suiteName: "name-viewer-\(UUID().uuidString)"))
            let other = TermioStore(workspaces: [Workspace(name: "Other")], projects: [], settings: AppSettings(defaults: otherDefaults))
            other.reconcileExternalSessions([fetched], from: KnownDevice(alias: nil, deviceID: nil), route: .local)
            XCTAssertEqual(other.allSessions.first?.givenTitle, fetched.customName)
        }
    }

    @MainActor
    func testANameRequestedBeforeTheFirstAttachmentIsConfirmedAfterTheDaemonIdentityArrives() async throws {
        let session = Session(title: "Terminal 1", agent: .terminal)
        var workspace = Workspace(name: "Local")
        workspace.terminals = [session]
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "rename-creation-\(UUID().uuidString)"))
        let store = TermioStore(workspaces: [workspace], projects: [], settings: AppSettings(defaults: defaults))
        let confirmed = expectation(description: "name confirmed after first attachment")
        var confirmation: Result<Void, Error>?
        store.companionRenameSession(sessionID: session.id.uuidString, name: "New Session") { result in
            confirmation = result
            confirmed.fulfill()
        }
        XCTAssertNil(confirmation)
        let link = TermiodSessionLink(
            sessionName: session.id.uuidString,
            specification: Termiod.CreateSpecification(
                cwd: NSTemporaryDirectory(), argv: ["/bin/cat"], env: [], rows: 24, cols: 80,
                customName: store.session(session.id)?.givenTitle), rows: 24, cols: 80)
        link.onDaemonSessionID = { daemonID in
            Task { @MainActor in store.recordDaemonSessionID(daemonID, for: session.id) }
        }
        link.start()
        defer { link.detach() }
        await fulfillment(of: [confirmed], timeout: 10)
        if case .success = confirmation {} else { XCTFail("The first attachment must confirm the name") }
        let fetched = try XCTUnwrap(Termiod.roster().sessions.first { $0.name == session.id.uuidString })
        XCTAssertEqual(fetched.customName, "New Session")
        XCTAssertEqual(store.session(session.id)?.givenTitle, fetched.customName)
        XCTAssertNil(store.session(session.id)?.pendingName)
    }

    /// A session that outlives one foreground poll (2 s, `session.rs`
    /// `FOREGROUND_POLL`) and then exits with a status worth telling apart from
    /// zero, so the run covers a live update *and* a distinctive ending.
    func testALiveRowArrivesBeforeTheExitAndTheExitCarriesTheFinalWord() throws {
        let link = TermiodSessionLink(
            sessionName: "wire-order-\(UUID().uuidString.prefix(8))",
            specification: Termiod.CreateSpecification(
                cwd: NSTemporaryDirectory(),
                argv: ["/bin/sh", "-c", "sleep 3; exit 7"],
                env: [], rows: 24, cols: 80),
            rows: 24, cols: 80)

        var arrivals: [Arrival] = []
        let ended = expectation(description: "session exits")
        link.onInformation = { information in
            arrivals.append(.information(information))
        }
        link.onExit = { status, _, information in
            arrivals.append(.exit(status, information))
            ended.fulfill()
        }
        link.start()
        defer { link.detach() }

        wait(for: [ended], timeout: 30)

        guard let last = arrivals.last, case .exit(let status, let final) = last else {
            return XCTFail("the exit must be the last thing this client hears")
        }
        XCTAssertEqual(status, 7, "the child's own status, not a generic failure")

        let liveRows = arrivals.compactMap { arrival -> Termiod.SessionInformation? in
            if case .information(let information) = arrival { return information }
            return nil
        }
        XCTAssertFalse(liveRows.isEmpty,
                       "a session that outlives a foreground poll must push at least one row")
        XCTAssertTrue(liveRows.allSatisfy(\.alive),
                      "every row before the exit describes a living session")

        // §2.3(b): the replacement check is made on the exit path, so the exit
        // must carry a row of its own rather than leaving the client to reuse
        // the last live one.
        let information = try XCTUnwrap(final, "the exit must carry the device's final row")
        XCTAssertFalse(information.alive, "the final row describes a session that has ended")
    }

    /// The exit row must not land in the live cache on its way past. It
    /// describes a session that has **ended**, and a close confirmation that
    /// read it would ask about a job on a dead session.
    func testTheExitRowNeverBecomesTheLiveRow() throws {
        let link = TermiodSessionLink(
            sessionName: "exit-cache-\(UUID().uuidString.prefix(8))",
            specification: Termiod.CreateSpecification(
                cwd: NSTemporaryDirectory(),
                argv: ["/bin/sh", "-c", "sleep 3; exit 0"],
                env: [], rows: 24, cols: 80),
            rows: 24, cols: 80)

        let ended = expectation(description: "session exits")
        link.onExit = { _, _, _ in ended.fulfill() }
        link.start()
        defer { link.detach() }

        wait(for: [ended], timeout: 30)

        // Settle: the exit row and the live cache are written on the same queue,
        // so read after the callback rather than inside it.
        let drained = expectation(description: "callbacks settle")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 5)

        // Asserted non-nil rather than checked with `if let`: a session that ran
        // for three seconds outlives a foreground poll, so an empty cache here
        // would mean no roster ever arrived — which must fail this test, not
        // pass it by skipping the claim.
        let cached = try XCTUnwrap(
            link.latestInformation,
            "a session that outlived a foreground poll must have left a live row")
        XCTAssertTrue(cached.alive,
                      "the live cache holds the last *living* row, never the exit's")
    }
}
