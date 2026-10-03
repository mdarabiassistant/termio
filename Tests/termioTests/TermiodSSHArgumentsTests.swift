import XCTest
import TermioShared
@testable import termio

/// The `-o` list the app puts on its own `ssh`, and the `ssh -G` reading that
/// decides which of them are ours to set. Two things are pinned here.
///
/// `BatchMode=yes` is unconditional. Nobody can answer a prompt on this
/// channel — its stdin is the framed protocol pipe, and ssh asks for a key
/// passphrase on a `/dev/tty` nobody is watching — so an unloaded key blocked
/// the attach instead of failing it. That is the bug this list exists to end,
/// and it comes back the moment the flag becomes conditional on anything.
///
/// Everything else defers to `~/.ssh/config`, because a command-line `-o`
/// outranks it. A user who chose `ControlMaster auto`, a `ControlPath`, or a
/// `ConnectTimeout` for a slow link keeps it.
final class TermiodSSHArgumentsTests: XCTestCase {
    /// Trimmed to the four lines that matter, in the spelling OpenSSH 10.2p1
    /// prints them: `controlmaster false` and `connecttimeout none` for unset,
    /// and no `controlpath` line at all.
    private let defaultsDump = """
        user alice
        hostname vps.example
        batchmode no
        controlmaster false
        connecttimeout none
        serveraliveinterval 0
        """

    private let controlPath = "/tmp/termio-ssh/2f1c8a90b3d4e5f6"

    func testUntouchedConfigGetsEveryOption() {
        let arguments = Termiod.sshArguments(
            options: Termiod.EffectiveSSHOptions(dump: defaultsDump),
            controlPath: controlPath)
        XCTAssertEqual(arguments, [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=\(Termiod.connectTimeoutSeconds)",
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(controlPath)",
            "-o", "ControlPersist=10m",
        ])
    }

    func testUserMultiplexingIsNotOverridden() {
        let dump = defaultsDump.replacingOccurrences(
            of: "controlmaster false", with: "controlmaster auto")
        let arguments = Termiod.sshArguments(
            options: Termiod.EffectiveSSHOptions(dump: dump), controlPath: controlPath)
        XCTAssertFalse(arguments.contains("ControlMaster=auto"))
        XCTAssertTrue(arguments.contains("BatchMode=yes"))
    }

    func testUserControlPathIsNotOverridden() {
        let dump = defaultsDump + "\ncontrolpath /Users/alice/.ssh/cm-%C"
        let arguments = Termiod.sshArguments(
            options: Termiod.EffectiveSSHOptions(dump: dump), controlPath: controlPath)
        XCTAssertFalse(arguments.contains(where: { $0.hasPrefix("ControlPath=") }))
    }

    func testUserConnectTimeoutIsNotOverridden() {
        let dump = defaultsDump.replacingOccurrences(
            of: "connecttimeout none", with: "connecttimeout 60")
        let arguments = Termiod.sshArguments(
            options: Termiod.EffectiveSSHOptions(dump: dump), controlPath: controlPath)
        XCTAssertFalse(arguments.contains(where: { $0.hasPrefix("ConnectTimeout=") }))
        XCTAssertTrue(arguments.contains("ControlMaster=auto"))
    }

    /// An OpenSSH old enough not to print the line is unreadable, not permissive:
    /// the same restraint `controlmaster`'s missing line already gets.
    func testAbsentConnectTimeoutLineLeavesTheConfigAlone() {
        let dump = defaultsDump.replacingOccurrences(of: "connecttimeout none\n", with: "")
        let arguments = Termiod.sshArguments(
            options: Termiod.EffectiveSSHOptions(dump: dump), controlPath: controlPath)
        XCTAssertFalse(arguments.contains(where: { $0.hasPrefix("ConnectTimeout=") }))
    }

    /// An unreadable probe keeps only the flag that cannot override anything:
    /// `BatchMode`'s default is `no`, and a pipe nobody can type into never
    /// wants the other answer.
    func testUnreadableProbeStillRefusesToPrompt() {
        XCTAssertEqual(
            Termiod.sshArguments(options: nil, controlPath: controlPath),
            ["-o", "BatchMode=yes"])
    }

    /// A control socket path over the 104-byte cap makes ssh fail outright, so
    /// it costs multiplexing — never the flags that keep the session honest.
    func testMissingControlPathCostsOnlyMultiplexing() {
        let arguments = Termiod.sshArguments(
            options: Termiod.EffectiveSSHOptions(dump: defaultsDump), controlPath: nil)
        XCTAssertEqual(arguments, [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=\(Termiod.connectTimeoutSeconds)",
        ])
    }

    func testLongPreviewControlPathCostsOnlyMultiplexing() {
        let path = "/var/folders/aa/" + String(repeating: "b", count: 26)
            + "/T/termio-ssh-sidebar-preview/2f1c8a90b3d4e5f6"
        let arguments = Termiod.sshArguments(
            options: Termiod.EffectiveSSHOptions(dump: defaultsDump), controlPath: path)
        XCTAssertEqual(arguments, [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=\(Termiod.connectTimeoutSeconds)",
        ])
    }

    func testControlPathReservesSpaceForOpenSSHTemporarySuffixAndTerminator() {
        for (length, usesMultiplexing) in [(86, true), (87, false)] {
            let path = "/" + String(repeating: "a", count: length - 1)
            let arguments = Termiod.sshArguments(
                options: Termiod.EffectiveSSHOptions(dump: defaultsDump), controlPath: path)
            XCTAssertEqual(arguments.contains("ControlMaster=auto"), usesMultiplexing,
                           "ControlPath is \(length) bytes before OpenSSH adds its temporary suffix")
        }
    }

    func testControlPathLimitCountsUTF8Bytes() {
        let path = "/" + String(repeating: "é", count: 43)
        let arguments = Termiod.sshArguments(
            options: Termiod.EffectiveSSHOptions(dump: defaultsDump), controlPath: path)
        XCTAssertEqual(arguments, [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=\(Termiod.connectTimeoutSeconds)",
        ])
    }
}
