import TermioShared
import XCTest
@testable import termio

/// `TermioStore.adoptDevice` — the a-priori → a-posteriori transition. State is
/// authored against an SSH alias, because a machine's workspace has to exist
/// before anything has connected; the first `hello_ok` is the only moment that
/// alias becomes a machine. These tests pin what gets written down at that
/// moment, and just as importantly what does not.
@MainActor
final class TermiodDeviceAdoptionTests: XCTestCase {
    private func makeStore(
        workspaces: [Workspace] = [Workspace(name: "Sessions")], projects: [Project] = []
    ) -> TermioStore {
        let defaults = UserDefaults(suiteName: "adopt-\(UUID().uuidString)")
            ?? UserDefaults.standard
        return TermioStore(workspaces: workspaces, projects: projects,
                           settings: AppSettings(defaults: defaults))
    }

    private func device(_ id: String) -> TermiodDevice {
        TermiodDevice(id: id, daemonVersion: "termiod/0.1.0 linux-aarch64",
                      routes: [.ssh("vps")], lastSeen: Date())
    }

    private func remoteSession(_ title: String, host: String?) -> Session {
        var session = Session(title: title, agent: .terminal)
        session.termiodRemoteHost = host
        return session
    }

    private func deviceWorkspace(alias: String, sessions: [Session] = []) -> Workspace {
        Workspace(name: alias, terminals: sessions, deviceAlias: alias)
    }

    private func project(
        _ name: String, in workspace: Workspace, sessions: [Session] = []
    ) -> Project {
        Project(workspaceID: workspace.id, name: name, path: "/code/\(name)",
                branch: "main", sessions: sessions)
    }

    /// A checkout recorded before checkouts were device-keyed is promoted the
    /// first time its alias resolves. An old state file must keep working — and
    /// stop being old.
    func testPromotesALegacyAliasKeyedCheckout() {
        let home = Workspace(name: "Sessions")
        var checkout = project("termio", in: home)
        checkout.remoteCheckouts = ["vps": "/home/me/termio"]
        let store = makeStore(workspaces: [home], projects: [checkout])

        store.adoptDevice(device("h_aaaa"), forRoute: .ssh("vps"))

        XCTAssertEqual(store.projects[0].remoteCheckouts, ["h_aaaa": "/home/me/termio"])
    }

    /// The same repo cloned to one machine and reached by a second alias resolves
    /// to the one device-keyed entry — the case that keyed by alias would report
    /// as "not cloned yet" the day the user changes networks.
    func testASecondAliasForOneMachineFindsTheSameCheckout() {
        let home = Workspace(name: "Sessions")
        var checkout = project("termio", in: home)
        checkout.remoteCheckouts = ["vps-lan": "/home/me/termio"]
        let store = makeStore(workspaces: [home], projects: [checkout])

        store.adoptDevice(device("h_aaaa"), forRoute: .ssh("vps-lan"))
        store.adoptDevice(device("h_aaaa"), forRoute: .ssh("vps-wan"))

        XCTAssertEqual(
            store.projects[0].remoteCheckout(device: "h_aaaa", alias: "vps-wan"),
            "/home/me/termio"
        )
    }

    /// Adoption never invents a checkout: a project that was never cloned there
    /// still has none, and the "not cloned yet" path stays honest.
    func testAdoptionDoesNotInventACheckout() {
        let home = Workspace(name: "Sessions")
        let store = makeStore(workspaces: [home], projects: [project("termio", in: home)])

        store.adoptDevice(device("h_aaaa"), forRoute: .ssh("vps"))

        XCTAssertTrue(store.projects[0].remoteCheckouts.isEmpty)
    }

    /// A machine's fallback workspace records which machine its alias reached —
    /// and keeps being the alias's workspace. `deviceAlias` is demoted to a route,
    /// not removed: it is still how the workspace is matched before anything has
    /// connected.
    func testBackfillsAFallbackWorkspacesDeviceWithoutDisturbingItsAlias() {
        let store = makeStore(workspaces: [deviceWorkspace(alias: "vps")])

        store.adoptDevice(device("h_aaaa"), forRoute: .ssh("vps"))

        XCTAssertEqual(store.workspaces[0].deviceID, "h_aaaa")
        XCTAssertEqual(store.workspaces[0].deviceAlias, "vps",
                       "the alias stays the bootstrap identity")
        XCTAssertEqual(store.workspaces[0].device, .ssh(alias: "vps"))
    }

    /// Two aliases for one machine are recorded as one device but are **not**
    /// merged. Merging is specified in §9.5 of the device-architecture doc and
    /// deliberately not performed yet — it must not happen before the duplicate
    /// `host_id` case (a cloned VM) has an answer.
    func testDoesNotYetMergeTwoWorkspacesOnOneDevice() {
        let store = makeStore(workspaces: [
            deviceWorkspace(alias: "vps-lan"), deviceWorkspace(alias: "vps-wan"),
        ])

        store.adoptDevice(device("h_aaaa"), forRoute: .ssh("vps-lan"))
        store.adoptDevice(device("h_aaaa"), forRoute: .ssh("vps-wan"))

        XCTAssertEqual(store.workspaces.count, 2, "merging is a later step, not a side effect")
        XCTAssertEqual(store.workspaces.map(\.deviceID), ["h_aaaa", "h_aaaa"],
                       "but both know they are one machine")
    }

    /// A workspace for an alias that resolved elsewhere is left alone — adoption
    /// is scoped to the route that was actually travelled.
    func testLeavesOtherAliasesUntouched() {
        let store = makeStore(workspaces: [
            deviceWorkspace(alias: "vps"), deviceWorkspace(alias: "devbox"),
        ])

        store.adoptDevice(device("h_aaaa"), forRoute: .ssh("vps"))

        XCTAssertEqual(store.workspaces[0].deviceID, "h_aaaa")
        XCTAssertNil(store.workspaces[1].deviceID)
    }

    /// Sessions belong to a machine, not to the road taken to reach it.
    func testRecordsTheDeviceOnSessionsThatTookThatRoute() {
        let store = makeStore(workspaces: [
            deviceWorkspace(alias: "vps", sessions: [remoteSession("Terminal 1", host: "vps")]),
            deviceWorkspace(alias: "devbox",
                            sessions: [remoteSession("Terminal 1", host: "devbox")]),
        ])

        store.adoptDevice(device("h_aaaa"), forRoute: .ssh("vps"))

        XCTAssertEqual(store.workspaces[0].terminals[0].deviceID, "h_aaaa")
        XCTAssertNil(store.workspaces[1].terminals[0].deviceID)
    }

    /// This Mac is a device like any other: a local session's device is recorded
    /// exactly the same way, over the route that happens to be a Unix socket.
    func testLocalSessionsGetTheirDeviceToo() {
        let home = Workspace(name: "Sessions")
        let store = makeStore(
            workspaces: [home],
            projects: [project("termio", in: home,
                               sessions: [remoteSession("Terminal 1", host: nil)])])

        store.adoptDevice(device("h_mac"), forRoute: .local)

        XCTAssertEqual(store.projects[0].sessions[0].deviceID, "h_mac")
    }

    /// Re-adopting the same device changes nothing — every attach calls this.
    func testAdoptionIsIdempotent() {
        let home = Workspace(name: "Sessions")
        var checkout = project("termio", in: home,
                               sessions: [remoteSession("Terminal 1", host: "vps")])
        checkout.remoteCheckouts = ["vps": "/home/me/termio"]
        let store = makeStore(workspaces: [home], projects: [checkout])

        store.adoptDevice(device("h_aaaa"), forRoute: .ssh("vps"))
        let afterFirst = store.projects
        store.adoptDevice(device("h_aaaa"), forRoute: .ssh("vps"))

        XCTAssertEqual(store.projects, afterFirst)
    }

    /// Before anything has connected there is no device to key by, and the menu
    /// still has to answer. The legacy alias entry is what it answers from.
    func testCheckoutLookupFallsBackToTheAliasBeforeAnythingHasConnected() {
        var checkout = project("termio", in: Workspace(name: "Sessions"))
        checkout.remoteCheckouts = ["vps": "/home/me/termio"]

        XCTAssertEqual(checkout.remoteCheckout(device: nil, alias: "vps"), "/home/me/termio")
        XCTAssertNil(checkout.remoteCheckout(device: nil, alias: "devbox"))
    }

    /// A device-keyed entry wins over a stale alias entry for a different machine.
    func testDeviceKeyedEntryWinsOverTheAliasFallback() {
        var checkout = project("termio", in: Workspace(name: "Sessions"))
        checkout.remoteCheckouts = ["h_aaaa": "/srv/termio", "vps": "/home/me/termio"]

        XCTAssertEqual(checkout.remoteCheckout(device: "h_aaaa", alias: "vps"), "/srv/termio")
    }

    /// A machine that re-mints its `host_id` keeps its clones. The alias still
    /// reaches the same box — enough to offer the new identity a reading — while
    /// the old identity remains recorded in case the alias was repointed.
    func testCarriesCheckoutsAcrossAHostIdentityChange() {
        var remote = deviceWorkspace(alias: "vps")
        remote.deviceID = "h_old"
        var checkout = project("termio", in: Workspace(name: "Sessions"))
        checkout.remoteCheckouts = ["h_old": "/home/me/termio"]
        let store = makeStore(workspaces: [remote], projects: [checkout])

        store.adoptDevice(device("h_new"), forRoute: .ssh("vps"))

        XCTAssertEqual(store.projects[0].remoteCheckouts, [
            "h_old": "/home/me/termio",
            "h_new": "/home/me/termio",
        ])
    }

    /// A project filed under a machine's workspace is already a path over there,
    /// so it needs no recorded checkout to open a terminal in. This is the reading
    /// that survives an identity change even after the workspace has taken the new
    /// one, which leaves nothing to re-key from.
    func testAProjectFiledOnAMachineNeedsNoRecordedCheckout() {
        let remote = deviceWorkspace(alias: "vps")
        let checkout = project("termio", in: remote)
        let store = makeStore(workspaces: [remote], projects: [checkout])

        XCTAssertEqual(
            store.remoteCheckout(for: checkout,
                                 on: KnownDevice(alias: "vps", deviceID: "h_new")),
            "/code/termio"
        )
    }

    /// An alias is not proof that the host behind it is the same filesystem. Once
    /// the workspace identifies a different box, its path cannot be guessed for
    /// the new one or promoted into a checkout record.
    func testAnAliasRepointKeepsTheOldCheckoutAndDoesNotInventOneOnTheNewBox() {
        var remote = deviceWorkspace(alias: "vps")
        remote.deviceID = "h_old"
        let checkout = project("termio", in: remote)
        let store = makeStore(workspaces: [remote], projects: [checkout])

        store.adoptDevice(device("h_new"), forRoute: .ssh("vps"))

        XCTAssertNil(store.remoteCheckoutReading(
            for: store.projects[0], on: KnownDevice(alias: "vps", deviceID: "h_new")))
        XCTAssertTrue(store.projects[0].remoteCheckouts.isEmpty)
    }

    /// A project whose workspace still identifies the old box must not open its
    /// old path after an alias is reused for a new one.
    func testARepointedAliasRefusesTheWorkspacePath() {
        var remote = deviceWorkspace(alias: "vps")
        remote.deviceID = "h_old"
        let checkout = project("termio", in: remote)
        let store = makeStore(workspaces: [remote], projects: [checkout])

        XCTAssertNil(store.remoteCheckout(for: checkout,
                                          on: KnownDevice(alias: "vps", deviceID: "h_new")))
    }

    /// A workspace records only its latest identity. A checkout stranded under an
    /// older one remains a fact and must not be discarded while adopting another.
    func testKeepsCheckoutOlderThanTheWorkspacesCurrentIdentity() {
        var remote = deviceWorkspace(alias: "vps")
        remote.deviceID = "h_current"
        var checkout = project("termio", in: Workspace(name: "Sessions"))
        checkout.remoteCheckouts = ["h_older": "/home/me/termio"]
        let store = makeStore(workspaces: [remote], projects: [checkout])

        store.adoptDevice(device("h_new"), forRoute: .ssh("vps"))

        XCTAssertEqual(store.projects[0].remoteCheckouts,
                       ["h_older": "/home/me/termio"])
    }

    /// The fallback is scoped to the machine the project is filed on: a checkout
    /// on this Mac still has to have been cloned before a terminal opens on a box,
    /// or the shell would land in a directory that is not there.
    func testAProjectOnThisMacStillNeedsARecordedCheckout() {
        let home = Workspace(name: "Sessions")
        let checkout = project("termio", in: home)
        let store = makeStore(workspaces: [home, deviceWorkspace(alias: "vps")],
                              projects: [checkout])

        XCTAssertNil(
            store.remoteCheckout(for: checkout,
                                 on: KnownDevice(alias: "vps", deviceID: "h_new")))
    }

    /// Workspace state survives a round trip through the state file, or the device
    /// would have to be re-learned on every launch.
    func testDeviceFieldsSurviveEncoding() throws {
        var workspace = deviceWorkspace(alias: "vps",
                                        sessions: [remoteSession("t", host: "vps")])
        workspace.deviceID = "h_aaaa"
        workspace.terminals[0].deviceID = "h_aaaa"

        let decoded = try JSONDecoder().decode(
            Workspace.self, from: try JSONEncoder().encode(workspace))

        XCTAssertEqual(decoded.deviceID, "h_aaaa")
        XCTAssertEqual(decoded.deviceAlias, "vps")
        XCTAssertEqual(decoded.terminals[0].deviceID, "h_aaaa")
    }

    /// A state file written before devices existed still loads, with the device
    /// simply unknown — that is the normal starting state, not a corrupt one.
    func testStateFilesWrittenBeforeDevicesStillDecode() throws {
        let json = Data("""
        {"id":"\(UUID().uuidString)","name":"vps","path":"~","branch":"—","kind":"host",
         "sshHost":"vps","remoteCheckouts":{"vps":"/home/me/termio"},"sessions":[]}
        """.utf8)

        let decoded = try JSONDecoder().decode(
            WorkspaceMigration.LegacyProject.self, from: json)

        XCTAssertNil(decoded.deviceID)
        XCTAssertEqual(decoded.sshHost, "vps")
        XCTAssertEqual(decoded.remoteCheckouts, ["vps": "/home/me/termio"])
    }
}

@MainActor
final class RemoteSessionDiscoveryTests: XCTestCase {
    private func makeStore(workspaces: [Workspace]) -> TermioStore {
        let defaults = UserDefaults(suiteName: "discovery-\(UUID().uuidString)") ?? .standard
        return TermioStore(workspaces: workspaces, settings: AppSettings(defaults: defaults))
    }

    private func payload(name: String? = nil, attached: Int = 0) throws -> Termiod.SessionsPayload {
        let sessions: [[String: Any]] = name.map {
            [["id": "\($0)-daemon", "name": $0, "pid": 42, "alive": true,
              "cwd": "/srv/work", "attachedClients": attached]]
        } ?? []
        return try JSONDecoder().decode(
            Termiod.SessionsPayload.self,
            from: JSONSerialization.data(withJSONObject: ["sessions": sessions]))
    }

    private func waitForRoster(_ route: TermiodRoute, in store: TermioStore) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while true {
            if let fetch = store.rosterFetches[route.description],
               !fetch.inFlight, fetch.settledAt != nil { return }
            guard ContinuousClock.now < deadline else {
                XCTFail("The roster request for \(route) did not finish")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func testKnownDevicesIncludeEmptyRemoteWorkspacesAndLooseSessions() {
        let workspaceAlias = "workspace-\(UUID().uuidString)"
        let sessionAlias = "session-\(UUID().uuidString)"
        var session = Session(title: "Remote shell", agent: .terminal)
        session.termiodRemoteHost = sessionAlias
        session.deviceID = "h_session"
        let store = makeStore(workspaces: [
            Workspace(name: "Local", terminals: [session]),
            Workspace(name: "Remote", deviceAlias: workspaceAlias, deviceID: "h_workspace"),
        ])

        let known = DeviceRoster.known(in: store)
        XCTAssertEqual(known.first, .thisMac)
        XCTAssertEqual(known.first { $0.alias == workspaceAlias }?.deviceID, "h_workspace")
        XCTAssertEqual(known.first { $0.alias == sessionAlias }?.deviceID, "h_session")
        XCTAssertEqual(known.filter { $0.alias == sessionAlias }.count, 1)
    }

    func testStartupDiscoversAttachedRemoteSessionsWithoutMovingTheLocalSelection() async throws {
        let alias = "discovery-\(UUID().uuidString)"
        let localSession = Session(title: "Local shell", agent: .terminal)
        let local = Workspace(name: "Local", terminals: [localSession])
        let remote = Workspace(name: "Remote", deviceAlias: alias)
        let store = makeStore(workspaces: [local, remote])
        let remotePayload = try payload(name: "already-running", attached: 2)
        let empty = try payload()
        let loader: @Sendable (TermiodRoute) throws -> Termiod.SessionsPayload = { route in
            route == .ssh(alias) ? remotePayload : empty
        }

        store.refreshKnownDeviceSessions(fetchingRoster: loader)
        try await waitForRoster(.local, in: store)
        try await waitForRoster(.ssh(alias), in: store)

        let adopted = store.sessions(inWorkspace: remote.id).first
        XCTAssertEqual(adopted?.termiodSessionName, "already-running")
        XCTAssertEqual(adopted?.termiodDaemonID, "already-running-daemon")
        XCTAssertEqual(adopted?.termiodRemoteHost, alias)
        XCTAssertEqual(adopted?.termiodRemoteCwd, "/srv/work")
        XCTAssertEqual(store.selectedSessionID, localSession.id)
        XCTAssertEqual(store.currentWorkspaceID, local.id)
        XCTAssertNil(store.currentDeviceAlias)
        XCTAssertEqual(store.deviceSessionsRoute, TermiodRoute.local.description)
        XCTAssertEqual(store.deviceSessions.sessions?.live.count, 0)

        store.refreshKnownDeviceSessions(fetchingRoster: loader)
        try await waitForRoster(.ssh(alias), in: store)
        XCTAssertEqual(store.sessions(inWorkspace: remote.id).map(\.id), [adopted?.id].compactMap { $0 })
    }

    func testAnUnreachableRemotePreservesLocalRosterAndCanBeRetried() async throws {
        let alias = "offline-\(UUID().uuidString)"
        var remoteSession = Session(title: "Remote shell", agent: .terminal)
        remoteSession.termiodRemoteHost = alias
        let store = makeStore(workspaces: [
            Workspace(name: "Local"),
            Workspace(name: "Remote", terminals: [remoteSession], deviceAlias: alias),
        ])
        let empty = try payload()
        store.refreshKnownDeviceSessions { route in
            if route == .ssh(alias) { throw URLError(.cannotConnectToHost) }
            return empty
        }
        try await waitForRoster(.local, in: store)
        try await waitForRoster(.ssh(alias), in: store)

        XCTAssertEqual(store.deviceSessionsRoute, TermiodRoute.local.description)
        XCTAssertNotNil(store.deviceSessions.sessions)
        XCTAssertNotNil(store.session(remoteSession.id))

        let live = try payload(name: "back-online")
        store.refreshDeviceSessions(on: KnownDevice(alias: alias, deviceID: nil)) { _ in live }
        try await waitForRoster(.ssh(alias), in: store)
        XCTAssertTrue(store.allSessions.contains { $0.termiodSessionName == "back-online" })
        XCTAssertEqual(store.deviceSessionsRoute, TermiodRoute.local.description)
    }

    func testAReplyAfterSwitchingDevicesStillAdoptsWithoutReplacingTheDisplayedRoster() async throws {
        let alias = "slow-\(UUID().uuidString)"
        let otherAlias = "other-\(UUID().uuidString)"
        let store = makeStore(workspaces: [Workspace(name: "Local")])
        let live = try payload(name: "slow-session")
        let release = DispatchSemaphore(value: 0)
        let started = expectation(description: "The remote request started")
        store.refreshDeviceSessions(on: KnownDevice(alias: alias, deviceID: nil)) { _ in
            started.fulfill()
            guard release.wait(timeout: .now() + 3) == .success else {
                throw URLError(.timedOut)
            }
            return live
        }
        await fulfillment(of: [started], timeout: 3)
        store.currentDeviceAlias = otherAlias
        store.deviceSessionsRoute = TermiodRoute.ssh(otherAlias).description
        store.deviceSessions = .ready(DeviceSessions(live: [], tombstones: []))
        release.signal()
        try await waitForRoster(.ssh(alias), in: store)

        XCTAssertEqual(store.allSessions.first?.termiodRemoteHost, alias)
        XCTAssertEqual(store.currentDeviceAlias, otherAlias)
        XCTAssertEqual(store.deviceSessionsRoute, TermiodRoute.ssh(otherAlias).description)
        XCTAssertEqual(store.deviceSessions.sessions?.live.count, 0)
        XCTAssertNil(store.selectedSessionID)
    }

    func testLocalDiscoveryWhileViewingARemoteWorkspaceFilesSessionsLocally() async throws {
        let local = Workspace(name: "Local")
        let remote = Workspace(name: "Remote", deviceAlias: "viewing-\(UUID().uuidString)")
        let store = makeStore(workspaces: [local, remote])
        store.currentWorkspaceID = remote.id
        store.currentDeviceAlias = remote.deviceAlias
        let live = try payload(name: "local-session")

        store.refreshDeviceSessions(on: .thisMac) { _ in live }
        try await waitForRoster(.local, in: store)

        XCTAssertEqual(store.sessions(inWorkspace: local.id).first?.termiodSessionName, "local-session")
        XCTAssertTrue(store.sessions(inWorkspace: remote.id).isEmpty)
        XCTAssertEqual(store.currentWorkspaceID, remote.id)
        XCTAssertNil(store.deviceSessionsRoute)
    }
}

@MainActor
final class RemoteDiscoveryIdentityTests: XCTestCase {
    private func makeStore(workspaces: [Workspace]) -> TermioStore {
        let defaults = UserDefaults(suiteName: "discovery-identity-\(UUID().uuidString)") ?? .standard
        return TermioStore(workspaces: workspaces, settings: AppSettings(defaults: defaults))
    }

    private func payload() throws -> Termiod.SessionsPayload {
        try JSONDecoder().decode(Termiod.SessionsPayload.self, from: Data("""
        {"sessions":[{"id":"existing-daemon","name":"existing-shell","pid":42,
          "alive":true,"cwd":"/srv/work","attachedClients":2}]}
        """.utf8))
    }

    private func waitForRoster(_ route: TermiodRoute, in store: TermioStore) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while store.rosterFetches[route.description]?.inFlight != false {
            guard ContinuousClock.now < deadline else {
                XCTFail("The roster request did not finish")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func testConcurrentAliasesKeepTheExistingRowBeforeItsRouteReplies() async throws {
        let firstAlias = "first-\(UUID().uuidString)"
        let secondAlias = "second-\(UUID().uuidString)"
        let identity = "h_\(UUID().uuidString)"
        for alias in [firstAlias, secondAlias] {
            TermiodDeviceRegistry.shared.record(
                hostID: identity, daemonVersion: "test", route: .ssh(alias))
        }
        var existing = Session(title: "Existing shell", agent: .terminal)
        existing.termiodRemoteHost = secondAlias
        existing.termiodSessionName = "existing-shell"
        let remote = Workspace(name: "Remote", terminals: [existing], deviceAlias: secondAlias)
        let store = makeStore(workspaces: [Workspace(name: "Local"), remote])
        let live = try payload()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        store.refreshDeviceSessions(on: KnownDevice(alias: secondAlias, deviceID: identity)) { _ in
            guard release.wait(timeout: .now() + 5) == .success else { throw URLError(.timedOut) }
            return live
        }
        store.refreshDeviceSessions(on: KnownDevice(alias: firstAlias, deviceID: identity)) { _ in live }
        try await waitForRoster(.ssh(firstAlias), in: store)
        XCTAssertEqual(store.allSessions.map(\.id), [existing.id])
        XCTAssertEqual(store.sessions(inWorkspace: remote.id).first?.termiodDaemonID, "existing-daemon")
        release.signal()
        try await waitForRoster(.ssh(secondAlias), in: store)
        XCTAssertEqual(store.allSessions.map(\.id), [existing.id])
    }

    func testDifferentMachinesCanDiscoverTheSameSessionName() async throws {
        let first = Workspace(name: "First", deviceAlias: "first-\(UUID().uuidString)", deviceID: "h_first")
        let second = Workspace(name: "Second", deviceAlias: "second-\(UUID().uuidString)", deviceID: "h_second")
        let store = makeStore(workspaces: [Workspace(name: "Local"), first, second])
        let live = try payload()
        store.refreshDeviceSessions(on: KnownDevice(alias: first.deviceAlias, deviceID: first.deviceID)) { _ in live }
        store.refreshDeviceSessions(on: KnownDevice(alias: second.deviceAlias, deviceID: second.deviceID)) { _ in live }
        try await waitForRoster(TermiodRoute(sshAlias: first.deviceAlias), in: store)
        try await waitForRoster(TermiodRoute(sshAlias: second.deviceAlias), in: store)
        XCTAssertEqual(store.sessions(inWorkspace: first.id).first?.termiodRemoteHost, first.deviceAlias)
        XCTAssertEqual(store.sessions(inWorkspace: second.id).first?.termiodRemoteHost, second.deviceAlias)
        XCTAssertEqual(store.allSessions.count, 2)
    }

    func testLocalDiscoveryCreatesALocalWorkspaceWhenOnlyRemoteWorkspacesExist() async throws {
        let remote = Workspace(name: "Remote", deviceAlias: "remote-\(UUID().uuidString)")
        let store = makeStore(workspaces: [remote])
        store.currentDeviceAlias = remote.deviceAlias
        let live = try payload()
        store.refreshDeviceSessions(on: .thisMac) { _ in live }
        try await waitForRoster(.local, in: store)
        // An attached local session belongs to another local client.
        XCTAssertTrue(store.allSessions.isEmpty)
        let detached = try JSONDecoder().decode(Termiod.SessionsPayload.self, from: Data("""
        {"sessions":[{"id":"local-daemon","name":"local-shell","pid":43,
          "alive":true,"cwd":"/srv/work","attachedClients":0}]}
        """.utf8))
        store.refreshDeviceSessions(on: .thisMac) { _ in detached }
        try await waitForRoster(.local, in: store)
        XCTAssertEqual(store.workspaces.first { $0.device.isThisMac }?.terminals.first?.termiodSessionName, "local-shell")
        XCTAssertTrue(store.sessions(inWorkspace: remote.id).isEmpty)
        XCTAssertEqual(store.currentWorkspaceID, remote.id)
    }
}
