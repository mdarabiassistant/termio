import TermioShared
import XCTest
@testable import termio

final class SessionNameTests: XCTestCase {
    private func information(name: String?, revision: UInt64?) throws -> Termiod.SessionInformation {
        var value: [String: Any] = ["id": "daemon-id", "name": "stable-handle", "title": "Automatic title"]
        if let name { value["custom_name"] = name }
        if let revision { value["custom_name_revision"] = revision }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Termiod.SessionInformation.self, from: JSONSerialization.data(withJSONObject: value))
    }

    func testCustomNameWinsWithoutChangingTheAttachHandleOrAutomaticTitle() throws {
        let row = try information(name: "build-λ", revision: 1)
        XCTAssertEqual(row.displayLabel, "build-λ")
        XCTAssertEqual(row.givenName, "build-λ")
        XCTAssertEqual(row.name, "stable-handle")
        XCTAssertEqual(row.title, "Automatic title")
    }

    func testOldDaemonKeepsLocalNamesAndLegacyDisplayFallback() throws {
        let row = try information(name: nil, revision: nil)
        var session = Session(title: "Terminal 1", agent: .terminal)
        session.givenTitle = "My work"
        session.acceptDaemonName(row)
        XCTAssertEqual(session.givenTitle, "My work")
        XCTAssertEqual(row.givenName, "Automatic title")
    }

    func testOnlyAuthoredNamesAreBackfilled() {
        var owner = Session(title: "Terminal 1", agent: .terminal)
        owner.givenTitle = "My work"
        owner.prepareNameBackfill()
        XCTAssertEqual(owner.pendingName?.value, "My work")
        XCTAssertEqual(owner.pendingName?.ifUnset, true)
        var viewer = Session(title: "zsh", agent: .terminal)
        viewer.givenTitle = "zsh"
        viewer.termiodSessionName = "stable-handle"
        viewer.prepareNameBackfill()
        XCTAssertNil(viewer.pendingName)
        viewer.chooseName("Explicit viewer rename")
        XCTAssertEqual(viewer.pendingName?.ifUnset, false)
    }

    func testFetchedNamesAreNeverUploadedAsNewEdits() throws {
        var session = Session(title: "Terminal 1", agent: .terminal)
        session.acceptDaemonName(try information(name: "Another client", revision: 2))
        session.prepareNameBackfill()
        XCTAssertNil(session.pendingName)
        XCTAssertEqual(session.givenTitle, "Another client")
    }

    func testOldFetchCannotOverwriteNewerAcknowledgement() throws {
        var session = Session(title: "Terminal 1", agent: .terminal)
        session.acceptDaemonName(try information(name: "New", revision: 3))
        session.acceptDaemonName(try information(name: "Old", revision: 2))
        XCTAssertEqual(session.givenTitle, "New")
    }

    func testPendingEditSurvivesFetchAndStateReload() throws {
        var session = Session(title: "Terminal 1", agent: .terminal)
        session.chooseName("Offline rename")
        session.acceptDaemonName(try information(name: "Old", revision: 2))
        let restored = try JSONDecoder().decode(Session.self, from: JSONEncoder().encode(session))
        XCTAssertEqual(restored.givenTitle, "Offline rename")
        XCTAssertEqual(restored.pendingName, session.pendingName)
    }

    func testClearSurvivesReloadWithoutRecoveringTheOldTitle() throws {
        var session = Session(title: "Former custom name", agent: .terminal)
        session.chooseName(nil)
        var restored = try JSONDecoder().decode(Session.self, from: JSONEncoder().encode(session))
        XCTAssertNotNil(restored.pendingName)
        XCTAssertNil(restored.pendingName?.value)
        restored.pendingName = nil
        restored.acceptDaemonName(try information(name: nil, revision: 4))
        let acknowledged = try JSONDecoder().decode(Session.self, from: JSONEncoder().encode(restored))
        XCTAssertNil(acknowledged.givenTitle)
        XCTAssertNil(acknowledged.pendingName)
        XCTAssertEqual(acknowledged.customNameRevision, 4)
    }

    @MainActor
    func testRosterFetchUpdatesAnAlreadyAdoptedRowWithoutDuplicatingIt() throws {
        let workspace = Workspace(name: "Local")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "session-names-\(UUID().uuidString)"))
        let store = TermioStore(workspaces: [workspace], projects: [], settings: AppSettings(defaults: defaults))
        let device = KnownDevice(alias: nil, deviceID: nil)
        store.reconcileExternalSessions([try information(name: "First", revision: 1)], from: device, route: .local)
        let adopted = try XCTUnwrap(store.allSessions.first)
        XCTAssertEqual(store.displayTitle(for: adopted), "First")
        store.reconcileExternalSessions([try information(name: "Second", revision: 2)], from: device, route: .local)
        XCTAssertEqual(store.allSessions.count, 1)
        XCTAssertEqual(store.allSessions.first?.id, adopted.id)
        XCTAssertEqual(store.allSessions.first?.givenTitle, "Second")
        store.reconcileExternalSessions([try information(name: nil, revision: 3)], from: device, route: .local)
        XCTAssertNil(store.allSessions.first?.givenTitle)
    }
}
