import Foundation
import TermioShared
import XCTest
@testable import termio

/// The Chief of Staff's rules that need no window (docs/design/20261019-chief-of-staff.md):
/// who gets fleet scope, what an event turn may do, how its folder is seeded,
/// and what the feed types in.
@MainActor
final class ChiefOfStaffTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("chief-folders-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory
    }

    func testChiefFolderDefaultsAndTildePaths() throws {
        let defaults = try ChiefOfStaffSetup.directories(working: "", data: "")
        XCTAssertEqual(defaults.working, ChiefOfStaffSetup.folder.standardizedFileURL)
        XCTAssertEqual(defaults.data, defaults.working)
        let selected = try ChiefOfStaffSetup.directories(working: "~/projects", data: "~/notes/chief")
        let home = FileManager.default.homeDirectoryForCurrentUser
        XCTAssertEqual(selected.working, home.appendingPathComponent("projects", isDirectory: true))
        XCTAssertEqual(selected.data, home.appendingPathComponent("notes/chief", isDirectory: true))
        XCTAssertThrowsError(try ChiefOfStaffSetup.directories(working: "projects", data: ""))
        XCTAssertThrowsError(try ChiefOfStaffSetup.directories(working: "/tmp", data: "/tmp/a\nb"))
    }

    func testSeparateDataFolderPreservesProjectsAndExistingNotes() throws {
        let root = try temporaryDirectory()
        let working = root.appendingPathComponent("projects", isDirectory: true)
        let data = root.appendingPathComponent("chief data", isDirectory: true)
        try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)
        for name in ["AGENTS.md", "CLAUDE.md"] {
            try "Project instructions: leave these alone.".write(
                to: working.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let directories = try ChiefOfStaffSetup.directories(working: working.path, data: data.path)
        try ChiefOfStaffSetup.prepare(cli: "termio-test", directories: directories)
        let notes = data.appendingPathComponent("notes.md")
        try "User preferences to retain.".write(to: notes, atomically: true, encoding: .utf8)
        let instructions = data.appendingPathComponent("AGENTS.md")
        let content = try String(contentsOf: instructions, encoding: .utf8)
        try (content + "\nUser instructions to retain.\n").write(to: instructions, atomically: true, encoding: .utf8)
        try ChiefOfStaffSetup.prepare(cli: "termio-test", directories: directories)
        XCTAssertEqual(try String(contentsOf: notes, encoding: .utf8), "User preferences to retain.")
        XCTAssertTrue(try String(contentsOf: instructions, encoding: .utf8).hasSuffix("User instructions to retain.\n"))
        XCTAssertTrue(content.contains(notes.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: data.appendingPathComponent("scratch").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: working.appendingPathComponent(".claude").path))
        for name in ["AGENTS.md", "CLAUDE.md"] {
            XCTAssertEqual(try String(contentsOf: working.appendingPathComponent(name), encoding: .utf8),
                           "Project instructions: leave these alone.")
        }
    }

    func testInvalidFoldersLeaveTheRunningChiefAndSettingsAlone() throws {
        let root = try temporaryDirectory()
        let fleet = makeFleet()
        let previousWorking = fleet.store.settings.chiefOfStaffWorkingDirectory
        let previousData = fleet.store.settings.chiefOfStaffDataDirectory
        let data = root.appendingPathComponent("must-not-be-created")
        XCTAssertThrowsError(try fleet.store.saveChiefOfStaffDirectories(
            working: root.appendingPathComponent("missing").path, data: data.path))
        XCTAssertEqual(fleet.store.chiefOfStaffID, fleet.chief.id)
        XCTAssertEqual(fleet.store.settings.chiefOfStaffWorkingDirectory, previousWorking)
        XCTAssertEqual(fleet.store.settings.chiefOfStaffDataDirectory, previousData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: data.path))
        XCTAssertTrue(fleet.store.surfaces.isEmpty)
        let file = root.appendingPathComponent("a-file")
        try Data().write(to: file)
        XCTAssertThrowsError(try ChiefOfStaffSetup.prepare(cli: "termio-test", directories:
            ChiefOfStaffSetup.directories(working: file.path, data: data.path)))
    }

    func testFolderSettingsPersistIndependently() throws {
        let root = try temporaryDirectory()
        let suite = "chief-folder-settings-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let file = root.appendingPathComponent("settings.json")
        let settings = AppSettings(defaults: defaults,
            settingsStore: SettingsStore(defaults: defaults, fileURL: file, domainName: suite))
        settings.chiefOfStaffWorkingDirectory = "~/projects"
        settings.chiefOfStaffDataDirectory = "~/chief notes"
        let restored = AppSettings(defaults: defaults,
            settingsStore: SettingsStore(defaults: defaults, fileURL: file, domainName: suite))
        XCTAssertEqual(restored.chiefOfStaffWorkingDirectory, "~/projects")
        XCTAssertEqual(restored.chiefOfStaffDataDirectory, "~/chief notes")
    }

    func testSessionRemembersBothFoldersAcrossAppRestarts() throws {
        var session = Session(title: "Chief", agent: .claudeCode)
        session.role = .chief
        let legacy = try ChiefOfStaffSetup.directories(working: "", data: "")
        XCTAssertTrue(legacy.matches(session))
        let selected = try ChiefOfStaffSetup.directories(working: "/tmp/projects", data: "/tmp/chief")
        session.spawnDirectory = selected.working.path
        session.chiefDataDirectory = selected.data.path
        let restored = try JSONDecoder().decode(Session.self, from: JSONEncoder().encode(session))
        XCTAssertTrue(selected.matches(restored))
        let changedData = try ChiefOfStaffSetup.directories(working: "/tmp/projects", data: "/tmp/other")
        XCTAssertFalse(changedData.matches(restored), "a surviving agent must not keep reading the previous data folder")
    }

    func testChiefLaunchUsesTheDataFolderWithoutShellExpansion() throws {
        let fleet = makeFleet()
        var chief = fleet.chief
        chief.spawnDirectory = "/tmp/projects"
        chief.chiefDataDirectory = "/tmp/Chief's $HOME `date` data"
        func arguments(_ command: String) throws -> [String] {
            let shell = Process()
            shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
            shell.arguments = ["-f", "-c", command]
            let output = Pipe()
            shell.standardOutput = output
            try shell.run()
            let bytes = output.fileHandleForReading.readDataToEndOfFile()
            shell.waitUntilExit()
            XCTAssertEqual(shell.terminationStatus, 0)
            return String(decoding: bytes, as: UTF8.self).split(separator: "\n").map(String.init)
        }
        let data = try XCTUnwrap(chief.chiefDataDirectory)
        XCTAssertEqual(try arguments(fleet.store.chiefOfStaffLaunchCommand("print -rl --", for: chief)), [
            "--settings", data + "/.claude/settings.json",
            "--append-system-prompt-file", data + "/CLAUDE.md", "--add-dir", data,
        ])
        chief.agent = .codex
        let codexArguments = try arguments(fleet.store.chiefOfStaffLaunchCommand("print -rl --", for: chief))
        XCTAssertEqual(Array(codexArguments.prefix(2)), ["--no-daemon", "--config"])
        let roots = try XCTUnwrap(codexArguments.last)
        let prefix = "sandbox_workspace_write.writable_roots="
        XCTAssertTrue(roots.hasPrefix(prefix))
        XCTAssertFalse(roots.contains("\\/"), "TOML basic strings do not accept escaped slashes")
        XCTAssertEqual(try JSONDecoder().decode([String].self, from: Data(roots.dropFirst(prefix.count).utf8)), [data])
        XCTAssertFalse(codexArguments.contains("--add-dir"), "read-only startup must reach Codex's trust gate")
        XCTAssertFalse(codexArguments.contains("--sandbox"), "the user's sandbox mode is retained")
        let prompt = try XCTUnwrap(fleet.store.chiefOfStaffLaunchPrompt(for: chief))
        XCTAssertTrue(prompt.contains(data + "/AGENTS.md"))
        XCTAssertTrue(prompt.contains(data + "/notes.md"))
        chief.role = nil
        XCTAssertEqual(fleet.store.chiefOfStaffLaunchCommand("codex", for: chief), "codex")
    }

    func testDaemonReadinessSurvivesReattachButNotAnAgentRestart() async throws {
        let fleet = makeFleet()
        func roster(_ ready: Bool?, alive: Bool = true, blocked: Bool = false) throws -> Termiod.SessionsPayload {
            var row: [String: Any] = ["id": "owned-chief", "name": fleet.chief.id.uuidString,
                                      "alive": alive, "status": "idle", "status_blocking": blocked]
            if let ready { row["agent_ready"] = ready }
            let payload = try JSONSerialization.data(withJSONObject: ["op": "sessions", "sessions": [row]])
            guard case .sessions(let roster) = try Termiod.decodeControl(payload) else {
                throw NSError(domain: "fixture", code: 1)
            }
            return roster
        }
        let ready = try roster(true)
        let waiting = try roster(false)
        let legacy = try roster(nil)
        fleet.store.noteChiefOfStaffAgentRestarted()
        let restored = await fleet.store.refreshChiefOfStaffReadiness(fetching: { _ in ready })
        XCTAssertTrue(restored)
        XCTAssertEqual(fleet.store.companionRoster().projects.flatMap(\.sessions)
            .first(where: { $0.id == fleet.chief.id.uuidString })?.ready, true)
        let blocked = try roster(true, blocked: true)
        let promptBlocked = await fleet.store.refreshChiefOfStaffReadiness(fetching: { _ in blocked })
        XCTAssertFalse(promptBlocked, "a live agent's permission question is not a composer")
        let unblocked = await fleet.store.refreshChiefOfStaffReadiness(fetching: { _ in ready })
        XCTAssertTrue(unblocked, "answering the question retains the same agent's readiness")
        let restarted = await fleet.store.refreshChiefOfStaffReadiness(fetching: { _ in waiting })
        XCTAssertFalse(restarted)
        let unknown = await fleet.store.refreshChiefOfStaffReadiness(fetching: { _ in legacy })
        XCTAssertFalse(unknown, "an old daemon does not supply proof")
        fleet.store.noteChiefOfStaffAgentReported()
        let manual = await fleet.store.refreshChiefOfStaffReadiness(fetching: { _ in legacy })
        XCTAssertTrue(manual, "old daemons retain the manual exchange fallback")
        let ended = try roster(true, alive: false)
        let gone = await fleet.store.refreshChiefOfStaffReadiness(fetching: { _ in ended })
        XCTAssertFalse(gone)
        XCTAssertTrue(fleet.store.surfaces.isEmpty)
    }

    // MARK: - Fleet scope and the guards, through the control socket

    func testPhoneSendRefusalsNeverMountOrAuthorizeASession() async throws {
        let fleet = makeFleet()
        let store = fleet.store
        store.chiefOfStaff.origin = .event
        store.chiefOfStaff.owesNotice = false
        let selected = store.selectedSessionID
        func code(_ reply: CompanionControl) -> String? {
            guard case .error(_, let code) = reply else { XCTFail("Expected a refusal"); return nil }
            return code
        }
        let unknown = await store.companionSendToChief(sessionID: UUID().uuidString, text: "hello")
        XCTAssertEqual(code(unknown), "not_chief")
        let ordinary = await store.companionSendToChief(sessionID: fleet.homeTerminal.id.uuidString, text: "hello")
        XCTAssertEqual(code(ordinary), "not_chief")
        let unready = await store.companionSendToChief(sessionID: fleet.chief.id.uuidString, text: "hello")
        XCTAssertEqual(code(unready), "not_ready")
        store.noteChiefOfStaffAgentReported()
        let empty = await store.companionSendToChief(sessionID: fleet.chief.id.uuidString, text: " \n ")
        XCTAssertEqual(code(empty), "no_text")
        store.chiefOfStaff.delivering = true
        let busy = await store.companionSendToChief(sessionID: fleet.chief.id.uuidString, text: "hello")
        XCTAssertEqual(code(busy), "busy")
        store.chiefOfStaff.delivering = false
        store.lastUserInputAt[fleet.chief.id] = Date()
        let typing = await store.companionSendToChief(sessionID: fleet.chief.id.uuidString, text: "hello")
        XCTAssertEqual(code(typing), "user_typing")
        store.lastUserInputAt.removeAll()
        store.noteChiefOfStaffAgentRestarted()
        let restarted = await store.companionSendToChief(sessionID: fleet.chief.id.uuidString, text: "hello")
        XCTAssertEqual(code(restarted), "not_ready")
        XCTAssertEqual(store.chiefOfStaff.origin, .event)
        XCTAssertFalse(store.chiefOfStaff.owesNotice)
        XCTAssertEqual(store.selectedSessionID, selected)
        XCTAssertTrue(store.backgroundActivationIDs.isEmpty)
        XCTAssertTrue(store.termiodLinks.isEmpty)
    }

    func testNotifyForwardsEveryCallerButKeepsOnlyTheChiefForReconnect() async throws {
        let fleet = makeFleet()
        var notices: [WireNotice] = []
        fleet.store.onCompanionNotice = { notices.append($0) }
        _ = await fleet.store.handleSessionControl(try request([
            "op": "notify", "caller_session": fleet.chief.id.uuidString,
            "about": fleet.homeTerminal.id.uuidString, "text": "Choose a path.",
        ]))
        let chiefNotice = try XCTUnwrap(notices.first)
        XCTAssertEqual(chiefNotice.from, fleet.chief.id.uuidString)
        XCTAssertEqual(chiefNotice.about, fleet.homeTerminal.id.uuidString)
        XCTAssertEqual(chiefNotice.body, "Choose a path.")
        XCTAssertEqual(fleet.store.chiefOfStaffWireNotice, chiefNotice)
        _ = await fleet.store.handleSessionControl(try request([
            "op": "notify", "caller_session": fleet.homeTerminal.id.uuidString,
            "text": "The shell finished.", "title": "Shell result",
        ]))
        XCTAssertEqual(notices.count, 2)
        XCTAssertEqual(notices.last?.from, fleet.homeTerminal.id.uuidString)
        XCTAssertEqual(notices.last?.title, "Shell result")
        XCTAssertEqual(fleet.store.chiefOfStaffWireNotice, chiefNotice)
        fleet.store.noteChiefOfStaffNotice("A newer answer.", about: nil)
        XCTAssertNotEqual(fleet.store.chiefOfStaffWireNotice?.id, chiefNotice.id)
        XCTAssertEqual(fleet.store.chiefOfStaffWireNotice, notices.last)
    }

    func testFallbackReachesPhoneOnceAndIsUnspoken() throws {
        let fleet = makeFleet()
        var notices: [WireNotice] = []
        fleet.store.onCompanionNotice = { notices.append($0) }
        fleet.store.noteChiefOfStaffUserInput()
        fleet.store.noteChiefOfStaffStatus(.working)
        fleet.store.noteChiefOfStaffStatus(.idle)
        fleet.store.noteChiefOfStaffStatus(.done)
        XCTAssertEqual(notices.count, 1)
        XCTAssertEqual(notices.first?.from, fleet.chief.id.uuidString)
        XCTAssertEqual(notices.first?.speak, false)
        XCTAssertEqual(fleet.store.chiefOfStaffWireNotice, notices.first)
        fleet.store.noteChiefOfStaffUserInput()
        fleet.store.noteChiefOfStaffStatus(.working)
        fleet.store.noteChiefOfStaffNotice("Here is the answer.", about: nil)
        fleet.store.noteChiefOfStaffStatus(.done)
        XCTAssertEqual(notices.count, 2, "an explicit notice prevents the fallback")
    }

    func testCompanionRosterIdentifiesChiefAndCarriesItsNotice() throws {
        let fleet = makeFleet()
        fleet.store.noteChiefOfStaffNotice("The API session needs you.", about: fleet.projectSession.id)
        let rows = fleet.store.companionRoster().projects.flatMap(\.sessions)
        let chief = try XCTUnwrap(rows.first { $0.id == fleet.chief.id.uuidString })
        XCTAssertEqual(chief.role, "chief")
        XCTAssertEqual(chief.subtitle, "The API session needs you.")
        XCTAssertTrue(rows.filter { $0.id != chief.id }.allSatisfy { $0.role == nil })
    }

    private struct Fleet {
        let store: TermioStore
        let chief: Session
        let homeTerminal: Session
        let siblingChat: Session
        let otherTerminal: Session
        let projectSession: Session
    }

    private func makeFleet() -> Fleet {
        var chief = Session(title: "Chief of Staff", agent: .claudeCode)
        chief.role = .chief
        let homeTerminal = Session(title: "Terminal 1")
        let siblingChat = Session(title: "Chat 1", agent: .claudeCode)
        let otherTerminal = Session(title: "Terminal 2")
        let projectSession = Session(title: "Claude Code", agent: .claudeCode)
        let home = Workspace(name: "Home", terminals: [homeTerminal], chats: [chief, siblingChat])
        let other = Workspace(name: "Devbox", terminals: [otherTerminal])
        let project = Project(
            workspaceID: home.id, name: "termio", path: "/tmp/termio",
            branch: "main", sessions: [projectSession])
        let suite = "chief-of-staff-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? UserDefaults.standard
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(suite).json")
        let settings = AppSettings(
            defaults: defaults,
            settingsStore: SettingsStore(defaults: defaults, fileURL: file, domainName: nil))
        settings.sessionControlEnabled = true
        settings.chiefOfStaffEnabled = true
        let store = TermioStore(workspaces: [home, other], projects: [project], settings: settings)
        store.noteChiefOfStaffUserInput()
        return Fleet(store: store, chief: chief, homeTerminal: homeTerminal, siblingChat: siblingChat,
                     otherTerminal: otherTerminal, projectSession: projectSession)
    }

    private func request(_ fields: [String: Any]) throws -> ControlRequest {
        try JSONDecoder().decode(ControlRequest.self, from: JSONSerialization.data(withJSONObject: fields))
    }

    private func reply(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func links(_ reply: [String: Any]) -> Set<String> {
        let sessions = reply["sessions"] as? [[String: Any]] ?? []
        return Set(sessions.compactMap { $0["link"] as? String })
    }

    func testOnlyTheChiefOfStaffSeesEverySession() async throws {
        let fleet = makeFleet()
        let store = fleet.store
        let fromChief = try reply(await store.handleSessionControl(request([
            "op": "list", "format": "json", "caller_session": fleet.chief.id.uuidString,
        ])))
        XCTAssertEqual(links(fromChief), [
            store.sessionLink(for: fleet.homeTerminal),
            store.sessionLink(for: fleet.siblingChat),
            store.sessionLink(for: fleet.otherTerminal),
            store.sessionLink(for: fleet.projectSession),
        ], "the fleet is every session but the Chief of Staff itself")
        XCTAssertNotNil(fromChief["devices"], "the fleet says which machines Termio knows")

        let fromTerminal = try reply(await store.handleSessionControl(request([
            "op": "list", "format": "json", "caller_session": fleet.homeTerminal.id.uuidString,
        ])))
        XCTAssertEqual(links(fromTerminal), [store.sessionLink(for: fleet.homeTerminal)],
                       "any other caller keeps its own roster")
        XCTAssertNil(fromTerminal["devices"])
    }

    func testListRowsSayWhereEachSessionRuns() async throws {
        let fleet = makeFleet()
        let fromChief = try reply(await fleet.store.handleSessionControl(request([
            "op": "list", "format": "json", "caller_session": fleet.chief.id.uuidString,
        ])))
        let sessions = try XCTUnwrap(fromChief["sessions"] as? [[String: Any]])
        let projectRow = try XCTUnwrap(sessions.first {
            ($0["link"] as? String) == fleet.store.sessionLink(for: fleet.projectSession)
        })
        XCTAssertEqual(projectRow["device"] as? String, "local")
        XCTAssertEqual(projectRow["section"] as? String, "project")
        XCTAssertEqual(projectRow["project_name"] as? String, "termio")
        XCTAssertEqual(projectRow["workspace"] as? String, "Home")
        XCTAssertEqual(projectRow["cwd"] as? String, "/tmp/termio")
    }

    func testOnlyTheChiefOfStaffMayNameAPlace() async throws {
        let fleet = makeFleet()
        let refused = try reply(await fleet.store.handleSessionControl(request([
            "op": "send", "format": "json", "caller_session": fleet.homeTerminal.id.uuidString,
            "text": "fix the build", "place_cwd": "/tmp",
        ])))
        XCTAssertEqual(refused["error"] as? String, "bad_place")
    }

    func testTheChiefOfStaffAlwaysNamesAPlace() async throws {
        let fleet = makeFleet()
        let refused = try reply(await fleet.store.handleSessionControl(request([
            "op": "send", "format": "json", "caller_session": fleet.chief.id.uuidString,
            "text": "fix the build", "agent": "claude",
        ])))
        XCTAssertEqual(refused["error"] as? String, "no_place")
    }

    func testAnUnknownMachineIsNamedNotGuessed() async throws {
        let fleet = makeFleet()
        let refused = try reply(await fleet.store.handleSessionControl(request([
            "op": "send", "format": "json", "caller_session": fleet.chief.id.uuidString,
            "text": "fix the build", "agent": "claude", "place_cwd": "nowhere:~/src",
        ])))
        XCTAssertEqual(refused["error"] as? String, "unknown_device")
    }

    func testAnEventTurnCanReadButNotAct() async throws {
        let fleet = makeFleet()
        let store = fleet.store
        store.chiefOfStaff.origin = .event
        let send = try reply(await store.handleSessionControl(request([
            "op": "send", "format": "json", "caller_session": fleet.chief.id.uuidString,
            "target": store.sessionLink(for: fleet.homeTerminal), "text": "push it",
        ])))
        XCTAssertEqual(send["error"] as? String, "not_user_turn")
        for op in ["close", "focus", "answer"] {
            let acted = try reply(await store.handleSessionControl(request([
                "op": op, "format": "json", "caller_session": fleet.chief.id.uuidString,
                "target": store.sessionLink(for: fleet.homeTerminal), "text": "1",
            ])))
            XCTAssertEqual(acted["error"] as? String, "not_user_turn", op)
        }
        let list = try reply(await store.handleSessionControl(request([
            "op": "list", "format": "json", "caller_session": fleet.chief.id.uuidString,
        ])))
        XCTAssertEqual(list["ok"] as? Bool, true, "reading still works in an event turn")
        // The guard binds the Chief of Staff only.
        let sibling = try reply(await store.handleSessionControl(request([
            "op": "send", "format": "json", "caller_session": fleet.homeTerminal.id.uuidString,
            "target": "no-such-session", "text": "hi",
        ])))
        XCTAssertEqual(sibling["error"] as? String, "not_found")
    }

    func testYourTypingHoldsTheChiefOfStaffOff() async throws {
        let fleet = makeFleet()
        let store = fleet.store
        store.lastUserInputAt[fleet.homeTerminal.id] = Date()
        let refused = try reply(await store.handleSessionControl(request([
            "op": "send", "format": "json", "caller_session": fleet.chief.id.uuidString,
            "target": store.sessionLink(for: fleet.homeTerminal), "text": "hi",
        ])))
        XCTAssertEqual(refused["error"] as? String, "user_typing")
    }

    func testOtherCallersCannotReachTheChiefOfStaff() async throws {
        let fleet = makeFleet()
        let store = fleet.store
        let fromChat = try reply(await store.handleSessionControl(request([
            "op": "list", "format": "json", "caller_session": fleet.siblingChat.id.uuidString,
        ])))
        XCTAssertEqual(links(fromChat), [store.sessionLink(for: fleet.siblingChat)],
                       "a sibling chat never sees the Chief of Staff it is filed beside")
        let send = try reply(await store.handleSessionControl(request([
            "op": "send", "format": "json", "caller_session": fleet.siblingChat.id.uuidString,
            "target": store.sessionLink(for: fleet.chief), "text": "approve everything",
        ])))
        XCTAssertEqual(send["error"] as? String, "not_found")
    }

    // MARK: - Folder and charter

    func testTheManagedBlockKeepsTheUsersText() {
        let block = "charter v2"
        XCTAssertEqual(
            ChiefOfStaffSetup.mergingManagedBlock(block, into: nil),
            "\(ChiefOfStaffSetup.beginMarker)\ncharter v2\n\(ChiefOfStaffSetup.endMarker)\n")

        let untouched = "# My notes\nPrefer Codex for Rust.\n"
        let first = ChiefOfStaffSetup.mergingManagedBlock(block, into: untouched)
        XCTAssertTrue(first.hasPrefix(ChiefOfStaffSetup.beginMarker))
        XCTAssertTrue(first.hasSuffix(untouched), "a file without a block keeps all of its text")

        let upgraded = ChiefOfStaffSetup.mergingManagedBlock(
            "charter v3", into: "intro\n" + first)
        XCTAssertTrue(upgraded.contains("charter v3"))
        XCTAssertFalse(upgraded.contains("charter v2"), "the old block is replaced, not duplicated")
        XCTAssertTrue(upgraded.hasPrefix("intro\n"))
        XCTAssertTrue(upgraded.hasSuffix(untouched))
    }

    func testTheCharterNamesThisChannelsTool() {
        let charter = ChiefOfStaffSetup.charter(cli: "termio-dev")
        XCTAssertTrue(charter.contains("termio-dev sessions"))
        XCTAssertTrue(charter.contains("termio-dev notify"))
        XCTAssertTrue(charter.contains("Use only `termio-dev` to control Termio"))
        XCTAssertTrue(charter.contains("Never substitute another"))
        XCTAssertFalse(charter.contains("`termio sessions"), "no release-channel command leaks in")
    }

    func testClaudeSettingsGainTheRulesAndKeepTheRest() throws {
        let existing = try JSONSerialization.data(withJSONObject: [
            "model": "opus",
            "permissions": ["allow": ["Bash(git status:*)"], "deny": ["Read(./secrets/**)"]],
        ])
        let merged = try XCTUnwrap(ChiefOfStaffSetup.claudeSettings(merging: existing, cli: "termio"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: merged) as? [String: Any])
        XCTAssertEqual(root["model"] as? String, "opus")
        let permissions = try XCTUnwrap(root["permissions"] as? [String: Any])
        let allow = try XCTUnwrap(permissions["allow"] as? [String])
        XCTAssertEqual(allow.first, "Bash(git status:*)")
        XCTAssertTrue(allow.contains("Bash(termio sessions:*)"))
        XCTAssertTrue(allow.contains("Bash(termio notify:*)"))
        XCTAssertEqual(permissions["deny"] as? [String], ["Read(./secrets/**)"])

        let again = try XCTUnwrap(ChiefOfStaffSetup.claudeSettings(merging: merged, cli: "termio"))
        let rules = try XCTUnwrap(
            (JSONSerialization.jsonObject(with: again) as? [String: Any])?["permissions"]
                as? [String: Any])["allow"] as? [String]
        XCTAssertEqual(rules?.count, allow.count, "merging twice adds nothing")

        XCTAssertNil(ChiefOfStaffSetup.claudeSettings(merging: Data("{ not json".utf8), cli: "termio"),
                     "a file the user broke is left for them, not replaced")
    }

    func testChiefReadinessHookUsesThisBuildAndPreservesUserHooks() throws {
        let root = try temporaryDirectory()
        let daemon = root.appendingPathComponent("daemon's test helper")
        try "#!/bin/sh\nprintf '%s\\n' \"$@\"\n".write(to: daemon, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: daemon.path)
        let userHook: [String: Any] = ["matcher": "resume", "hooks": [["type": "command", "command": "echo user-hook"]]]
        let existing = try JSONSerialization.data(withJSONObject: ["hooks": [
            "SessionStart": [userHook], "Stop": [userHook],
        ]])
        let first = try XCTUnwrap(ChiefOfStaffSetup.claudeSettings(
            merging: existing, cli: "termio-dev", daemon: "/old/build/termiod"))
        let updated = try XCTUnwrap(ChiefOfStaffSetup.claudeSettings(
            merging: first, cli: "termio-dev", daemon: daemon.path))
        let settings = try XCTUnwrap(JSONSerialization.jsonObject(with: updated) as? [String: Any])
        let hooks = try XCTUnwrap(settings["hooks"] as? [String: Any])
        let startup = try XCTUnwrap(hooks["SessionStart"] as? [[String: Any]])
        XCTAssertEqual(startup.count, 2, "an upgrade replaces only Termio's readiness hook")
        XCTAssertEqual(startup.first?["matcher"] as? String, "resume")
        XCTAssertEqual((hooks["Stop"] as? [[String: Any]])?.count, 1)
        let managed = try XCTUnwrap(startup.last)
        XCTAssertEqual(managed["matcher"] as? String, "startup|resume|clear")
        let handlers = try XCTUnwrap(managed["hooks"] as? [[String: Any]])
        let command = try XCTUnwrap(handlers.first?["command"] as? String)
        XCTAssertFalse(command.contains("/old/build/termiod"))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-f", "-c", command]
        process.environment = ["TERMIOD_SESSION_ID": "test-chief"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                       "set-status\ntest-chief\nidle\n--transcript\n--tool-from\ntool_name\n")
    }

    func testScreenReadWaitsUntilTheRemoteOutputArrives() async {
        var samples = 0
        let lines = await TermioStore.waitForControlScreen(timeout: 1) {
            samples += 1
            return samples < 3 ? nil : ["Your decision is needed."]
        }
        XCTAssertEqual(lines, ["Your decision is needed."])
        XCTAssertEqual(samples, 3)
    }

    func testScreenReadTimeoutDoesNotBecomeABlankScreen() async {
        let lines = await TermioStore.waitForControlScreen(timeout: 0.01) { nil }
        XCTAssertNil(lines)
    }

    func testAReceivedBlankScreenIsStillAValidRead() async {
        let lines = await TermioStore.waitForControlScreen { [] }
        XCTAssertEqual(lines, [])
    }

    // MARK: - Places

    func testPlacesNameAMachineOnlyWhenTermioKnowsIt() {
        let known: Set<String> = ["devbox"]
        XCTAssertEqual(try SpawnPlace.parse("devbox:~/src/api", knownDevices: known).get(),
                       SpawnPlace(device: "devbox", path: "~/src/api"))
        XCTAssertEqual(try SpawnPlace.parse("devbox:", knownDevices: known).get(),
                       SpawnPlace(device: "devbox", path: "~"))
        XCTAssertEqual(try SpawnPlace.parse("local:~/src", knownDevices: known).get(),
                       SpawnPlace(device: nil, path: "~/src"))
        XCTAssertEqual(try SpawnPlace.parse("/Users/me/src/termio", knownDevices: known).get(),
                       SpawnPlace(device: nil, path: "/Users/me/src/termio"))
        XCTAssertEqual(SpawnPlace.parse("mini:~/src", knownDevices: known),
                       .failure(.unknownDevice("mini")))
        XCTAssertEqual(SpawnPlace.parse("  ", knownDevices: known), .failure(.empty))
        XCTAssertEqual(SpawnPlace.expanding("~", home: "/Users/me"), "/Users/me")
        XCTAssertEqual(SpawnPlace.expanding("~/src", home: "/Users/me"), "/Users/me/src")
        XCTAssertEqual(SpawnPlace.expanding("/srv/app", home: "/Users/me"), "/srv/app")
    }

    func testTwoAliasesForOneHostAreOneMachine() {
        let machines = FleetMachines(
            devices: [
                .thisMac,
                KnownDevice(alias: "192.0.2.55", deviceID: "h_mini"),
                KnownDevice(alias: "mac-mini", deviceID: "h_mini"),
                KnownDevice(alias: "devbox", deviceID: nil),
            ],
            sessionAliases: ["mac-mini", "mac-mini", "192.0.2.55", "devbox"])
        XCTAssertEqual(machines.machines, [
            FleetMachines.Machine(name: "mac-mini", aliases: ["192.0.2.55"]),
            FleetMachines.Machine(name: "devbox", aliases: []),
        ], "named by the alias most of its sessions use")
        XCTAssertEqual(machines.name(forAlias: "192.0.2.55"), "mac-mini")
        XCTAssertEqual(machines.name(forAlias: "devbox"), "devbox")
        XCTAssertNil(machines.name(forAlias: nil), "this Mac has no alias")
        XCTAssertEqual(machines.name(forAlias: "elsewhere"), "elsewhere",
                       "an alias the roster doesn't know yet still names its machine")

        let unused = FleetMachines(
            devices: [KnownDevice(alias: "vps-wan", deviceID: "h_vps"),
                      KnownDevice(alias: "vps-lan", deviceID: "h_vps")],
            sessionAliases: [])
        XCTAssertEqual(unused.machines, [FleetMachines.Machine(name: "vps-lan", aliases: ["vps-wan"])],
                       "with no sessions to go by, the first alias in order names it")
    }

    // MARK: - Feed

    func testTheFeedMessageIsOneBlockPerEvent() {
        let message = ChiefOfStaffFeed.message(for: [
            .init(status: "needs-you", link: "termio://session/a", machine: "this Mac",
                  folder: "~/src/termio", title: "Protocol bump", agent: "Codex",
                  prompt: "Raise the wire version?\n› 1. Yes"),
            .init(status: "done", link: "termio://session/b", machine: "devbox",
                  folder: "/home/me/api", title: "Flaky test", agent: "Claude Code",
                  transcript: "/home/me/.claude/projects/x.jsonl", transcriptLines: 860),
            .init(status: "stalled", link: "termio://session/c", machine: "this Mac",
                  folder: "", title: "Build", agent: "Codex",
                  evidence: "working 42m, no repo change, transcript +3 lines"),
        ])
        XCTAssertEqual(message, """
            [termio] 3 events
            needs-you  termio://session/a  this Mac ~/src/termio › Protocol bump (Codex)
              │ Raise the wire version?
              │ › 1. Yes
            done  termio://session/b  devbox /home/me/api › Flaky test (Claude Code)
              transcript: /home/me/.claude/projects/x.jsonl, ends at line 860
            stalled  termio://session/c  this Mac › Build (Codex) — working 42m, no repo change, transcript +3 lines
            """)
    }

    func testTheFeedWaitsForAQuietChiefOfStaff() {
        let now = Date()
        XCTAssertNil(ChiefOfStaffFeed.hold(
            agentReady: true, chiefWorking: false, lastUserInput: nil, now: now))
        XCTAssertEqual(ChiefOfStaffFeed.hold(
            agentReady: true, chiefWorking: true, lastUserInput: nil, now: now), .briefly)
        XCTAssertEqual(ChiefOfStaffFeed.hold(
            agentReady: true, chiefWorking: false, lastUserInput: now.addingTimeInterval(-2), now: now),
            .briefly)
        XCTAssertNil(ChiefOfStaffFeed.hold(
            agentReady: true, chiefWorking: false, lastUserInput: now.addingTimeInterval(-30), now: now))
    }

    /// A Return typed into an agent still on its folder trust prompt answers the
    /// prompt; one typed into the shell it exited to runs the message.
    func testTheFeedNeverTypesIntoAnAgentThatHasNotReported() {
        XCTAssertEqual(ChiefOfStaffFeed.hold(
            agentReady: false, chiefWorking: false, lastUserInput: nil, now: Date()),
            .untilAgentReports, "however quiet it looks")
    }

    func testAShellsBellIsNotNewsButWhatBlocksYouIs() {
        let fleet = makeFleet()
        let store = fleet.store
        store.noteForChiefOfStaff(status: "needs-you", for: fleet.homeTerminal.id)
        XCTAssertTrue(store.chiefOfStaff.pending.isEmpty,
                      "a prompt's bell after a command is not a question")

        store.noteForChiefOfStaff(status: "needs-you", for: fleet.siblingChat.id)
        XCTAssertEqual(store.chiefOfStaff.pending.map(\.id), [fleet.siblingChat.id],
                       "an agent's bell or notification is how it asks")

        store.blockingAttention.insert(fleet.homeTerminal.id)
        store.noteForChiefOfStaff(status: "needs-you", for: fleet.homeTerminal.id)
        XCTAssertEqual(store.chiefOfStaff.pending.map(\.id),
                       [fleet.siblingChat.id, fleet.homeTerminal.id],
                       "something observable blocked on you is news from any session")
    }

    /// A bell lit the dot first, so the blocking report behind it writes no new
    /// status, and the feed hears it only through this hand-off.
    func testABlockingSignalBehindABellStillReachesTheFeed() {
        let fleet = makeFleet()
        let store = fleet.store
        store.blockingAttention.insert(fleet.homeTerminal.id)
        store.noteBlockingUpgradeForChiefOfStaff(fleet.homeTerminal.id)
        XCTAssertEqual(store.chiefOfStaff.pending.map(\.id), [fleet.homeTerminal.id],
                       "the shell's bell was passed over, so the question is news")

        store.chiefOfStaff.pending.removeAll()
        store.noteBlockingUpgradeForChiefOfStaff(fleet.siblingChat.id)
        XCTAssertTrue(store.chiefOfStaff.pending.isEmpty,
                      "an agent's bell already reached the feed; a second would repeat it")
    }

    func testAResolvedEventIsNoLongerNews() {
        XCTAssertTrue(ChiefOfStaffFeed.stillCurrent(status: "needs-you", now: .needsAttention))
        XCTAssertFalse(ChiefOfStaffFeed.stillCurrent(status: "needs-you", now: .working))
        XCTAssertTrue(ChiefOfStaffFeed.stillCurrent(status: "done", now: .done))
        XCTAssertFalse(ChiefOfStaffFeed.stillCurrent(status: "done", now: .idle),
                       "a finished session you already looked at")
        XCTAssertTrue(ChiefOfStaffFeed.stillCurrent(status: "stalled", now: .working))
        XCTAssertFalse(ChiefOfStaffFeed.stillCurrent(status: "stalled", now: .done))
    }

    func testAnInterruptedBriefRetainsOnlyCurrentEventsAndPreservesNewerOnes() {
        let fleet = makeFleet()
        let store = fleet.store
        store.setStatus(.done, for: fleet.siblingChat.id)
        store.setStatus(.done, for: fleet.projectSession.id)
        store.chiefOfStaff.pending = [.init(id: fleet.siblingChat.id, status: "done", evidence: "newer")]
        store.requeueChiefOfStaffEvents([
            .init(id: fleet.siblingChat.id, status: "needs-you", evidence: "old"),
            .init(id: fleet.projectSession.id, status: "done"),
            .init(id: fleet.otherTerminal.id, status: "needs-you"),
        ], for: fleet.chief.id)
        XCTAssertEqual(store.chiefOfStaff.pending.map(\.id), [fleet.siblingChat.id, fleet.projectSession.id])
        XCTAssertEqual(store.chiefOfStaff.pending.first?.evidence, "newer")
        store.settings.chiefOfStaffBriefsEnabled = false
        store.chiefOfStaff.pending.removeAll()
        store.requeueChiefOfStaffEvents([.init(id: fleet.projectSession.id, status: "done")], for: fleet.chief.id)
        XCTAssertTrue(store.chiefOfStaff.pending.isEmpty)
    }

    func testFoldersAreSpelledFromHome() {
        XCTAssertEqual(ChiefOfStaffFeed.abbreviated("/Users/me/src/x", home: "/Users/me"), "~/src/x")
        XCTAssertEqual(ChiefOfStaffFeed.abbreviated("/Users/me", home: "/Users/me"), "~")
        XCTAssertEqual(ChiefOfStaffFeed.abbreviated("/Users/meadow/x", home: "/Users/me"),
                       "/Users/meadow/x", "a sibling directory sharing the prefix is not home")
    }

    func testTheGuardRefusesOnlyActingVerbsInEventTurns() {
        for op in ["send", "answer", "close", "focus"] {
            XCTAssertTrue(ChiefOfStaffGuard.refuses(op: op, origin: .event), op)
            XCTAssertFalse(ChiefOfStaffGuard.refuses(op: op, origin: .user), op)
        }
        for op in ["list", "read", "watch", "notify"] {
            XCTAssertFalse(ChiefOfStaffGuard.refuses(op: op, origin: .event), op)
        }
    }

    func testCodexStartupPromptCannotGainAuthorityFromTrustAnswers() throws {
        let fleet = makeFleet()
        var codex = fleet.chief
        codex.agent = .codex
        let prompt = try XCTUnwrap(fleet.store.chiefOfStaffLaunchPrompt(for: codex))
        XCTAssertTrue(prompt.contains("AGENTS.md"))
        XCTAssertTrue(prompt.contains("wait for the user"))
        XCTAssertFalse(fleet.store.chiefOfStaff.owesNotice)
        fleet.store.noteChiefOfStaffUserInput() // Accepting its trust question.
        XCTAssertTrue(ChiefOfStaffGuard.refuses(op: "send", origin: fleet.store.chiefOfStaff.origin))
        fleet.store.noteChiefOfStaffAgentReported()
        XCTAssertFalse(fleet.store.chiefOfStaff.bootstrapPending)
        XCTAssertTrue(ChiefOfStaffGuard.refuses(op: "send", origin: fleet.store.chiefOfStaff.origin))
        fleet.store.noteChiefOfStaffUserInput() // A real message after startup.
        XCTAssertFalse(ChiefOfStaffGuard.refuses(op: "send", origin: fleet.store.chiefOfStaff.origin))
        XCTAssertTrue(fleet.store.chiefOfStaff.owesNotice)
        _ = fleet.store.chiefOfStaffLaunchPrompt(for: codex) // A replacement process.
        XCTAssertTrue(ChiefOfStaffGuard.refuses(op: "send", origin: fleet.store.chiefOfStaff.origin))
    }

    func testCodexChiefKeepsHooksInItsOwnTerminal() {
        let fleet = makeFleet()
        var codex = fleet.chief
        codex.agent = .codex
        XCTAssertEqual(fleet.store.chiefOfStaffLaunchCommand("codex --model chosen", for: codex),
                       "codex --model chosen --no-daemon")
        XCTAssertEqual(fleet.store.chiefOfStaffLaunchCommand("codex --no-daemon", for: codex),
                       "codex --no-daemon")
        codex.role = nil
        XCTAssertEqual(fleet.store.chiefOfStaffLaunchCommand("codex", for: codex), "codex")
        XCTAssertEqual(fleet.store.chiefOfStaffLaunchCommand("claude", for: fleet.chief),
                       "claude --settings " + TermioStore.shellQuoted(
                        ChiefOfStaffSetup.folder.appendingPathComponent(".claude/settings.json").path))
    }

    func testStartupPromptDoesNotChangeOtherSessions() {
        let fleet = makeFleet()
        XCTAssertNil(fleet.store.chiefOfStaffLaunchPrompt(for: fleet.chief))
        var ordinary = fleet.chief
        ordinary.agent = .codex
        ordinary.role = nil
        XCTAssertNil(fleet.store.chiefOfStaffLaunchPrompt(for: ordinary))
        XCTAssertFalse(fleet.store.chiefOfStaff.bootstrapPending)
        XCTAssertEqual(fleet.store.chiefOfStaff.origin, .user)
    }

    func testReattachingCannotAuthorizeASurvivingEventTurn() {
        let restored = ChiefOfStaffState()
        XCTAssertEqual(restored.origin, .event)
        XCTAssertTrue(ChiefOfStaffGuard.refuses(op: "send", origin: restored.origin))
        let fleet = makeFleet()
        fleet.store.chiefOfStaff = restored
        fleet.store.noteChiefOfStaffUserInput()
        XCTAssertFalse(ChiefOfStaffGuard.refuses(op: "send", origin: fleet.store.chiefOfStaff.origin))
    }

    // MARK: - Persistence and wire

    func testTheRoleSurvivesTheStateFileAndAnUnknownOneDegrades() throws {
        var session = Session(title: "Chief of Staff", agent: .claudeCode)
        session.role = .chief
        let decoded = try JSONDecoder().decode(Session.self, from: JSONEncoder().encode(session))
        XCTAssertEqual(decoded.role, .chief)

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as? [String: Any])
        object["role"] = "from-a-newer-build"
        let future = try JSONDecoder().decode(
            Session.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(future.role, "an unknown role is no role, not a failed state file")
    }

    func testTheDaemonsRoleAndClaimDecode() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let row = try decoder.decode(Termiod.SessionInformation.self, from: Data("""
            {"id":"s_1","name":"n","role":"chief"}
            """.utf8))
        XCTAssertEqual(row.role, "chief")

        guard case .chief(let held) = try Termiod.decodeControl(Data("""
            {"op":"chief","claim":{"machine":"m1","machine_name":"Mac mini","session":"termio://session/x","since_unix":7},"refused":true,"re":1}
            """.utf8)) else { return XCTFail("a chief reply decodes as one") }
        XCTAssertEqual(held.claim?.machineName, "Mac mini")
        XCTAssertTrue(held.refused)

        guard case .chief(let empty) = try Termiod.decodeControl(Data("""
            {"op":"chief","re":1}
            """.utf8)) else { return XCTFail("an empty claim still decodes") }
        XCTAssertNil(empty.claim)
        XCTAssertFalse(empty.refused)
    }

    func testAReleaseSendsNoClaim() throws {
        let release = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Termiod.setChiefPayload(claim: nil, holder: "m1")) as? [String: Any])
        XCTAssertEqual(release["op"] as? String, "set_chief")
        XCTAssertEqual(release["holder"] as? String, "m1")
        XCTAssertNil(release["claim"], "no claim is what the daemon reads as a release")

        let claim = Termiod.ChiefClaim(machine: "m1", machineName: "MacBook", session: "s", sinceUnix: 5)
        let write = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Termiod.setChiefPayload(claim: claim, holder: "m1", takeover: true)) as? [String: Any])
        let sent = try XCTUnwrap(write["claim"] as? [String: Any])
        XCTAssertEqual(sent["machine_name"] as? String, "MacBook")
        XCTAssertEqual(sent["since_unix"] as? Int, 5)
        XCTAssertEqual(write["takeover"] as? Bool, true)
    }
}
