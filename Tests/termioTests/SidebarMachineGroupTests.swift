import XCTest
@testable import termio

@MainActor
final class SidebarMachineGroupTests: XCTestCase {
    private func groups(_ workspaces: [Workspace], known: [KnownDevice] = []) -> [SidebarMachineGroup] {
        SidebarMachineGroup.groups(workspaces: workspaces, knownDevices: known, localMachineName: "Test Mac")
    }

    func testAllWorkspaceMachinesAreVisibleWithTheLocalMachineFirst() {
        let local = Workspace(name: "Macbook pro", terminals: [Session(title: "Local")])
        let remote = Workspace(name: "mac-mini", terminals: [Session(title: "Remote")], deviceAlias: "mac-mini")
        let third = Workspace(name: "server", deviceAlias: "server")
        let result = groups([third, remote, local])
        XCTAssertEqual(result.map(\.name), ["Macbook pro", "mac-mini", "server"])
        XCTAssertEqual(result.flatMap(\.workspaces), [local, remote, third])
    }

    func testTheExistingCustomNameIsKeptAndDefaultUsesComputerName() {
        XCTAssertEqual(groups([Workspace(name: "Macbook pro")]).first?.name, "Macbook pro")
        XCTAssertEqual(groups([Workspace(name: Workspace.defaultName)]).first?.name, "Test Mac")
    }

    func testMultipleWorkspacesOnOneMachineKeepTheirOwnContentsAndOrder() {
        let first = Workspace(name: "Work", terminals: [Session(title: "One")])
        let second = Workspace(name: "Personal", terminals: [Session(title: "Two")])
        let result = groups([first, second])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.name, "Test Mac")
        XCTAssertEqual(result.first?.workspaces, [first, second])
    }

    func testAliasesForOneMachineShareOneHeadingWithoutMergingWorkspaces() {
        let first = Workspace(name: "Work", deviceAlias: "server-lan")
        let second = Workspace(name: "Personal", deviceAlias: "server-vpn", deviceID: "host-a")
        let result = groups([first, second], known: [KnownDevice(alias: "server-lan", deviceID: "host-a")])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.workspaces, [first, second])
    }

    func testUnresolvedHostsStaySeparate() {
        let alpha = Workspace(name: "alpha", deviceAlias: "alpha")
        let beta = Workspace(name: "beta", deviceAlias: "beta")
        XCTAssertEqual(groups([beta, alpha]).map(\.name), ["alpha", "beta"])
    }

    func testTheMachineWrapperDoesNotReclassifyTerminalsChatsOrSSHRows() throws {
        var terminal = Session(title: "Agent running in a terminal", agent: .claudeCode)
        terminal.pinned = true
        var ssh = Session(title: "SSH shell")
        ssh.sshHost = "server"
        let chat = Session(title: "Chat", agent: .claudeCode)
        let original = Workspace(name: "Macbook pro", terminals: [terminal, ssh], chats: [chat])
        let result = groups([original])
        let displayed = try XCTUnwrap(result.first?.workspaces.first)
        XCTAssertEqual(result.count, 1, "An SSH row does not acquire a different owner")
        XCTAssertEqual(displayed, original)
        XCTAssertEqual(displayed.terminals, [terminal, ssh])
        XCTAssertEqual(displayed.chats, [chat])
        XCTAssertTrue(displayed.terminals[0].pinned)
    }

    func testEmptyWorkspacesRemainWithoutAddingUnusedKnownHosts() {
        let local = Workspace(name: "Macbook pro")
        let remote = Workspace(name: "mac-mini", deviceAlias: "mac-mini")
        let result = groups([local, remote], known: [KnownDevice(alias: "unused", deviceID: "host-b")])
        XCTAssertEqual(result.map(\.name), ["Macbook pro", "mac-mini"])
        XCTAssertEqual(result.flatMap(\.workspaces), [local, remote])
    }

    func testAnAliasForThisMacDoesNotCreateADuplicateMachine() {
        let local = Workspace(name: "Macbook pro", deviceID: "local-id")
        let alias = Workspace(name: "Local via SSH", deviceAlias: "mac-lan", deviceID: "local-id")
        let result = groups([local, alias])
        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result.first?.device.isLocal == true)
        XCTAssertEqual(result.first?.workspaces, [local, alias])
    }

    func testSelectionKeepsEveryWorkspaceVisibleAndPreservesExistingSessionMenu() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "machine-sidebar-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults, settingsStore: SettingsStore(
            defaults: defaults, fileURL: directory.appendingPathComponent("settings.json"), domainName: suite))
        let localSession = Session(title: "Local")
        var remoteSession = Session(title: "Remote")
        remoteSession.termiodRemoteHost = "server"
        let local = Workspace(name: "Macbook pro", terminals: [localSession])
        let remote = Workspace(name: "server", terminals: [remoteSession], deviceAlias: "server")
        let store = TermioStore(workspaces: [remote, local], settings: settings)
        let originalMenu = store.sidebarSessionGroups.flatMap(\.sessions).map(\.id)
        XCTAssertEqual(store.sidebarSessionGroups.map(\.name), [localized("Terminals"), localized("Terminals")])

        store.selectedSessionID = remoteSession.id
        XCTAssertEqual(store.currentWorkspaceID, remote.id)
        XCTAssertEqual(store.sidebarMachineGroups.flatMap(\.workspaces).map(\.id), [local.id, remote.id])

        store.selectedSessionID = localSession.id
        XCTAssertEqual(store.currentWorkspaceID, local.id)
        XCTAssertEqual(store.sidebarMachineGroups.flatMap(\.workspaces).map(\.id), [local.id, remote.id])
        XCTAssertEqual(store.sidebarSessionGroups.flatMap(\.sessions).map(\.id), originalMenu)
        XCTAssertEqual(store.workspaces.map(\.id), [remote.id, local.id])
    }
}
