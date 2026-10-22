import XCTest
@testable import termio

/// How the pieces a user authors become one command line.
///
/// `AppSettings.command(for:on:)` splices three separately-edited things — the
/// machine's path, the agent's arguments, the bypass switch — into a single
/// string that is later handed to `zsh -ilc`. The order they land in and the
/// rule that a flag is never added twice are the parts a caller cannot see.
@MainActor
final class AgentLaunchCommandTests: XCTestCase {

    func testFreshPrivateProfileInstallsTheBundledToolUnderItsOwnName() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("cli-copy-\(UUID().uuidString)")
        defer { try? files.removeItem(at: root) }
        for (identifier, resourceName) in [("sh.termio.app.dev", "termio-dev"),
                                           ("sh.termio.app", "termio")] {
            let app = root.appendingPathComponent("\(identifier).app")
            let resources = app.appendingPathComponent("Contents/Resources")
            try files.createDirectory(at: resources, withIntermediateDirectories: true)
            let info = try PropertyListSerialization.data(fromPropertyList: [
                "CFBundleIdentifier": identifier, "CFBundlePackageType": "APPL",
            ], format: .xml, options: 0)
            try info.write(to: app.appendingPathComponent("Contents/Info.plist"))
            // Execute the installed file to check both its mode and its runtime
            // name: the real Rust client chooses the app socket from argv[0].
            let content = Data("#!/bin/sh\nprintf '%s' \"${0##*/}\"\n".utf8)
            try content.write(to: resources.appendingPathComponent(resourceName))
            let bundle = try XCTUnwrap(Bundle(url: app))
            let source = try XCTUnwrap(CommandLineTool.bundledURL(in: bundle))
            XCTAssertEqual(source.lastPathComponent, resourceName)
            let copy = root.appendingPathComponent("\(identifier)/bin/termio-private-test")
            XCTAssertFalse(files.fileExists(atPath: copy.path))
            XCTAssertTrue(CommandLineTool.refreshSupportCopy(from: source, to: copy))
            XCTAssertEqual(try Data(contentsOf: copy), content)
            let process = Process()
            process.executableURL = copy
            let output = Pipe()
            process.standardOutput = output
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            XCTAssertEqual(String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8),
                           "termio-private-test")
            // A bare SwiftPM launch may keep an existing copy, but must not
            // report a missing or non-executable copy as usable.
            XCTAssertTrue(CommandLineTool.refreshSupportCopy(from: nil, to: copy))
            try files.setAttributes([.posixPermissions: 0o644], ofItemAtPath: copy.path)
            XCTAssertFalse(CommandLineTool.refreshSupportCopy(from: nil, to: copy))
            XCTAssertTrue(CommandLineTool.refreshSupportCopy(from: source, to: copy))
            try files.removeItem(at: copy)
            XCTAssertFalse(CommandLineTool.refreshSupportCopy(from: nil, to: copy))
        }
    }

    private func settings() -> AppSettings {
        let suite = "agent-launch-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(suite).json")
        return AppSettings(
            defaults: defaults,
            settingsStore: SettingsStore(defaults: defaults, fileURL: file, domainName: nil))
    }

    func testArgumentsFollowThePathAndPrecedeTheBypassFlag() {
        let settings = settings()
        settings.setArguments("--model opus", for: .claudeCode)
        settings.setBypassPermissions(.claudeCode, enabled: true)

        XCTAssertEqual(
            settings.command(for: .claudeCode),
            "claude --model opus --dangerously-skip-permissions")
    }

    func testAFlagTypedIntoTheArgumentsIsNotAddedTwice() {
        // The same rule the command path already had: the switch tops the line up
        // to the flag rather than appending it unconditionally, so a user who
        // reached for the field before finding the switch doesn't get both.
        let settings = settings()
        settings.setArguments("--dangerously-skip-permissions", for: .claudeCode)
        settings.setBypassPermissions(.claudeCode, enabled: true)

        XCTAssertEqual(settings.command(for: .claudeCode),
                       "claude --dangerously-skip-permissions")
    }

    func testArgumentsApplyToEveryMachineWhilePathsDoNot() {
        // The scope split this setting exists for: how you want the agent to run
        // travels with the agent, where it lives is a fact about a box.
        let settings = settings()
        let vps = KnownDevice(alias: "vps", deviceID: "h_1")
        settings.setCommandPath("/opt/bin/codex", for: .codex, on: vps)
        settings.setArguments("--sandbox danger-full-access", for: .codex)

        XCTAssertEqual(settings.command(for: .codex, on: vps),
                       "/opt/bin/codex --sandbox danger-full-access")
        XCTAssertEqual(settings.command(for: .codex),
                       "codex --sandbox danger-full-access")
    }

    func testAnEmptiedFieldLeavesNothingBehind() {
        // An emptied field must hand the agent back to its default rather than
        // storing "" — the rule that keeps a cleared preference out of the file.
        let settings = settings()
        settings.setArguments("--model opus", for: .claudeCode)
        settings.setArguments("   ", for: .claudeCode)

        XCTAssertNil(settings.arguments(for: .claudeCode))
        XCTAssertTrue(settings.agentArguments.isEmpty)
        XCTAssertEqual(settings.command(for: .claudeCode), "claude")
    }

    func testOpenCodeCanSkipItsPromptsFromTheSwitchAlone() {
        // The reason issue #577 was filed: OpenCode's manifest carried no bypass
        // flag, so the switch it needed was not on its pane at all.
        XCTAssertEqual(AgentPreset.opencode.permissionBypassFlag, "--auto")

        let settings = settings()
        settings.setBypassPermissions(.opencode, enabled: true)
        XCTAssertEqual(settings.command(for: .opencode), "opencode --auto")
    }

    func testASpawnPromptFollowsEverythingElseOnTheLine() {
        // After the resume arguments, and behind `--`, so a prompt that starts
        // with a dash is still the prompt and never a flag.
        XCTAssertEqual(
            TermioStore.launchCommand(
                "claude --session-id 1A2B", prompt: "-v fix it", argument: "-- {prompt}"),
            "claude --session-id 1A2B -- '-v fix it'")
    }

    func testASpawnPromptReachesTheAgentExactlyAsWritten() throws {
        // The prompt is the user's own words, so it carries everything a shell
        // reads specially. Run through a real zsh, the way `launchArgv` hands the
        // line over, the program must receive the words unchanged.
        let prompt = "It's $HOME, `date`, \"quoted\"; !! & | > *\nsecond line \\ end"
        let line = try XCTUnwrap(
            TermioStore.launchCommand("print -rn --", prompt: prompt, argument: "{prompt}"))
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shell.arguments = ["-f", "-c", line]
        let output = Pipe()
        shell.standardOutput = output
        try shell.run()
        shell.waitUntilExit()

        XCTAssertEqual(shell.terminationStatus, 0)
        XCTAssertEqual(String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8),
                       prompt)
    }

    func testALaunchWithoutAPromptOrAPlaceForItIsUnchanged() {
        XCTAssertEqual(TermioStore.launchCommand("codex", prompt: nil, argument: "-- {prompt}"),
                       "codex")
        XCTAssertEqual(TermioStore.launchCommand("aider", prompt: "fix it", argument: nil),
                       "aider")
        XCTAssertNil(TermioStore.launchCommand(nil, prompt: "fix it", argument: "-- {prompt}"))
    }

    func testClaudeAndCodexTakeTheirPromptOnTheCommandLine() {
        // Both were checked against the real CLIs: each holds a prompt passed this
        // way through its folder-trust question and submits it once answered.
        XCTAssertEqual(AgentPreset.claudeCode.promptArgument, "-- {prompt}")
        XCTAssertEqual(AgentPreset.codex.promptArgument, "-- {prompt}")
        XCTAssertNil(AgentPreset.terminal.promptArgument)
    }

    func testAPromptArgumentWithNowhereForThePromptIsSetAside() throws {
        // Set aside, not fatal: the daemon parses the same file and has no use for
        // the field, so a bad value must not make the agent vanish from one side.
        let directory = FileManager.default.temporaryDirectory
        let broken = try JSONDecoder().decode(AgentManifest.self, from: Data("""
            { "id": "custom", "name": "Custom", "command": "custom", "promptArgument": "-i" }
            """.utf8))
        XCTAssertNil(try broken.definition(
            directory: directory, resourceBundle: Bundle.termioResources).promptArgument)

        let working = try JSONDecoder().decode(AgentManifest.self, from: Data("""
            { "id": "custom", "name": "Custom", "command": "custom", "promptArgument": "-i {prompt}" }
            """.utf8))
        XCTAssertEqual(try working.definition(
            directory: directory, resourceBundle: Bundle.termioResources).promptArgument,
            "-i {prompt}")
    }
}
