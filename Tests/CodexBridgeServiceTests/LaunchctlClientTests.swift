@testable import CodexBridgeService
import Foundation
import Testing

@Suite(.serialized)
struct LaunchctlClientTests {
    @Test func clientUsesExactBootstrapBootoutAndPrintArgumentsWithoutAShell() async throws {
        let fixture = try LaunchctlFixture(body: """
        printf '%s\\n' "$@" >> '\(LaunchctlFixture.shellQuotedPlaceholder)'
        if [ "$1" = print ]; then printf loaded; fi
        """)
        let client = LaunchctlClient(
            executable: fixture.executable,
            timeout: .seconds(1),
            outputLimit: 64 * 1024
        )
        let plist = fixture.root.appending(path: "agent.plist")

        try await client.bootstrap(domain: "gui/501", plist: plist)
        try await client.bootout(domain: "gui/501", label: "ai.rsitech.voiceinbox.bridge")
        #expect(try await client.printService(
            domain: "gui/501",
            label: "ai.rsitech.voiceinbox.bridge"
        ) == "loaded")

        #expect(try String(contentsOf: fixture.capture, encoding: .utf8)
            .split(separator: "\n").map(String.init) == [
            "bootstrap", "gui/501", plist.path,
            "bootout", "gui/501/ai.rsitech.voiceinbox.bridge",
            "print", "gui/501/ai.rsitech.voiceinbox.bridge",
        ])
    }

    @Test func printCapsCapturedStandardOutputAtExactlySixtyFourKiB() async throws {
        let fixture = try LaunchctlFixture(body: """
        i=0
        while [ "$i" -lt 70000 ]; do
          printf x
          i=$((i + 1))
        done
        """)
        let client = LaunchctlClient(
            executable: fixture.executable,
            timeout: .seconds(2),
            outputLimit: 64 * 1024
        )

        let output = try await client.printService(domain: "gui/501", label: "fixture")

        #expect(output.utf8.count == 64 * 1024)
    }

    @Test func timeoutIsBoundedAndReportedWithoutEnumeratingOrKillingByName() async throws {
        let fixture = try LaunchctlFixture(body: "while :; do :; done")
        let client = LaunchctlClient(
            executable: fixture.executable,
            timeout: .milliseconds(40),
            outputLimit: 64 * 1024
        )
        let started = ContinuousClock.now

        await #expect(throws: LaunchctlClientError.timedOut) {
            _ = try await client.printService(domain: "gui/501", label: "fixture")
        }
        #expect(ContinuousClock.now - started < .seconds(1))
    }

    @Test func timeoutReportsAnExactChildThatSurvivesTheShutdownDeadline() async throws {
        let fixture = try LaunchctlFixture(body: "while :; do :; done")
        let survivor = LockedPID()
        let client = LaunchctlClient(
            executable: fixture.executable,
            timeout: .milliseconds(30),
            outputLimit: 64 * 1024,
            shutdown: { process in
                let pid = process.processIdentifier
                survivor.store(pid)
                return .stillRunning(pid: pid, killResult: EPERM)
            }
        )

        do {
            _ = try await client.printService(domain: "gui/501", label: "fixture")
            Issue.record("expected exact survivor diagnostic")
        } catch let LaunchctlClientError.childStillRunning(pid, killResult) {
            #expect(pid == survivor.value)
            #expect(killResult == EPERM)
        }
        let pid = try #require(survivor.value)
        _ = kill(pid, SIGKILL)
    }

    @Test func printMapsOnlyTheDocumentedMissingServiceExitToNotLoaded() async throws {
        let fixture = try LaunchctlFixture(body: "exit 113")
        let client = LaunchctlClient(
            executable: fixture.executable,
            timeout: .seconds(1),
            outputLimit: 64 * 1024
        )

        await #expect(throws: LaunchctlClientError.serviceNotLoaded) {
            _ = try await client.printService(domain: "gui/501", label: "missing")
        }
    }

    @Test func bootoutMapsTheDocumentedMissingServiceExitToNotLoaded() async throws {
        let fixture = try LaunchctlFixture(body: "exit 113")
        let client = LaunchctlClient(
            executable: fixture.executable,
            timeout: .seconds(1),
            outputLimit: 64 * 1024
        )

        await #expect(throws: LaunchctlClientError.serviceNotLoaded) {
            try await client.bootout(domain: "gui/501", label: "missing")
        }
    }

    @Test func successfulExactChildDoesNotWaitForDescendantRetainedPipes() async throws {
        let fixture = try LaunchctlFixture(
            body: "exec /usr/bin/perl -e 'if (fork) { exit 0; } sleep 2;'"
        )
        let client = LaunchctlClient(
            executable: fixture.executable,
            timeout: .seconds(1),
            outputLimit: 64 * 1024
        )
        let started = ContinuousClock.now

        _ = try await client.printService(domain: "gui/501", label: "fixture")

        #expect(ContinuousClock.now - started < .seconds(1))
    }

    @Test func strictCodeSignVerificationTimeoutUsesTheSameBoundedExactChildShutdown() async throws {
        let fixture = try LaunchctlFixture(body: "while :; do :; done")
        let verifier = CodeSignBridgeBundleSignatureVerifier(
            executable: fixture.executable,
            timeout: .milliseconds(40)
        )
        let started = ContinuousClock.now

        await #expect(throws: BridgeServiceInstallerError.signatureInvalid) {
            try await verifier.verifyStrictDeepSignature(of: fixture.root)
        }
        #expect(ContinuousClock.now - started < .seconds(1))
    }

    @Test func codeSignReportsAnExactChildThatSurvivesTheShutdownDeadline() async throws {
        let fixture = try LaunchctlFixture(body: "while :; do :; done")
        let survivor = LockedPID()
        let verifier = CodeSignBridgeBundleSignatureVerifier(
            executable: fixture.executable,
            timeout: .milliseconds(30),
            shutdown: { process in
                let pid = process.processIdentifier
                survivor.store(pid)
                return .stillRunning(pid: pid, killResult: EPERM)
            }
        )

        do {
            try await verifier.verifyStrictDeepSignature(of: fixture.root)
            Issue.record("expected exact survivor diagnostic")
        } catch let BridgeServiceInstallerError.childStillRunning(pid, killResult) {
            #expect(pid == survivor.value)
            #expect(killResult == EPERM)
        }
        if let pid = survivor.value { _ = kill(pid, SIGKILL) }
    }
}

private final class LaunchctlFixture {
    static let shellQuotedPlaceholder = "__CAPTURE__"
    let root: URL
    let executable: URL
    let capture: URL

    init(body: String) throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "launchctl-client-tests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        executable = root.appending(path: "fake-launchctl")
        capture = root.appending(path: "arguments")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let script = "#!/bin/sh\n" + body.replacingOccurrences(
            of: Self.shellQuotedPlaceholder,
            with: capture.path.replacingOccurrences(of: "'", with: "'\\''")
        ) + "\n"
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: executable.path
        )
    }

    deinit { try? FileManager.default.removeItem(at: root) }
}

private final class LockedPID: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: pid_t?
    func store(_ value: pid_t) { lock.withLock { stored = value } }
    var value: pid_t? { lock.withLock { stored } }
}
