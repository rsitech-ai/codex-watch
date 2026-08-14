@testable import CodexBridgeService
import Foundation
import Security
import Testing

extension TLSIdentitySecurityTests {
    @Test func systemTLSIdentityQueriesUseLoginKeychainWithoutInventingAccessGroup() throws {
        let generated = try X509CertificateBuilder().build()
        let label = TLSIdentityProvisioner.defaultLabel
        let queries = [
            SystemTLSIdentityKeychain.Query.keyAdd(privateKey: generated.privateKey, label: label),
            SystemTLSIdentityKeychain.Query.certificateAdd(
                certificate: generated.certificate,
                label: label
            ),
            SystemTLSIdentityKeychain.Query.identityLoad(label: label),
            SystemTLSIdentityKeychain.Query.keyMatch(label: label),
            SystemTLSIdentityKeychain.Query.certificateMatch(label: label),
        ]

        for query in queries {
            #expect(query[kSecUseDataProtectionKeychain] == nil)
            #expect(query[kSecAttrSynchronizable] as? Bool == false)
            #expect(query[kSecAttrAccessGroup] == nil)
        }
        #expect(
            SystemTLSIdentityKeychain.Query.keyAdd(
                privateKey: generated.privateKey,
                label: label
            )[kSecAttrAccessible] as? String
            == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        )
    }

    @Test func systemTLSIdentityPromotionUsesLoginKeychainQueriesForBothUpdates() {
        let queries = SystemTLSIdentityKeychain.Query.promotion(
            stagingLabel: "staged",
            activeLabel: TLSIdentityProvisioner.defaultLabel
        )

        #expect(queries.keyMatch[kSecUseDataProtectionKeychain] == nil)
        #expect(queries.certificateMatch[kSecUseDataProtectionKeychain] == nil)
        #expect(queries.keyMatch[kSecAttrSynchronizable] as? Bool == false)
        #expect(queries.certificateMatch[kSecAttrSynchronizable] as? Bool == false)
        #expect(queries.keyAttributes[kSecAttrApplicationTag] as? Data == Data(TLSIdentityProvisioner.defaultLabel.utf8))
        #expect(queries.certificateAttributes[kSecAttrLabel] as? String == TLSIdentityProvisioner.defaultLabel)
    }

    @Test func pkcs12CompatibilityImportIsMemoryOnly() {
        let options = PKCS12TLSIdentityProvider.importOptions(password: "fixture-only")

        #expect(options[kSecImportToMemoryOnly as String] as? Bool == true)
        #expect(options[kSecImportExportPassphrase as String] as? String == "fixture-only")
    }

    @Test func systemMutationLocksSerializeDistinctInstancesAtSameTemporaryPath() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "bridge-system-identity-lock-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        let lockURL = root
            .appending(path: "identity-lock", directoryHint: .isDirectory)
            .appending(path: "transaction.lock")
        let first = SystemTLSIdentityMutationLock(lockURL: lockURL, timeout: 2)
        let second = SystemTLSIdentityMutationLock(lockURL: lockURL, timeout: 2)
        let firstEntered = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let firstDone = DispatchSemaphore(value: 0)
        let secondEntered = DispatchSemaphore(value: 0)
        let secondDone = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            try? first.withLock {
                firstEntered.signal()
                _ = releaseFirst.wait(timeout: .now() + 2)
            }
            firstDone.signal()
        }
        #expect(firstEntered.wait(timeout: .now() + 2) == .success)
        DispatchQueue.global().async {
            _ = try? second.withLock { secondEntered.signal() }
            secondDone.signal()
        }

        #expect(secondEntered.wait(timeout: .now() + 0.1) == .timedOut)
        releaseFirst.signal()
        #expect(firstDone.wait(timeout: .now() + 2) == .success)
        #expect(secondEntered.wait(timeout: .now() + 2) == .success)
        #expect(secondDone.wait(timeout: .now() + 2) == .success)
    }

    @Test func systemRemovalStatusPreservesPartialFailureEvidence() {
        #expect(SystemTLSIdentityKeychain.removalError(
            certificateStatus: errSecSuccess,
            keyStatus: errSecItemNotFound
        ) == nil)
        #expect(SystemTLSIdentityKeychain.removalError(
            certificateStatus: errSecSuccess,
            keyStatus: errSecInteractionNotAllowed
        ) == .keychainRemovalFailed(
            certificateStatus: errSecSuccess,
            keyStatus: errSecInteractionNotAllowed
        ))
        #expect(SystemTLSIdentityKeychain.removalError(
            certificateStatus: errSecInteractionNotAllowed,
            keyStatus: errSecItemNotFound
        ) == .keychainRemovalFailed(
            certificateStatus: errSecInteractionNotAllowed,
            keyStatus: errSecItemNotFound
        ))
    }

    @Test func systemMutationLockRejectsSymlinkSwapImmediatelyBeforeOperation() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "bridge-system-lock-swap-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        let lockURL = root
            .appending(path: "identity-lock", directoryHint: .isDirectory)
            .appending(path: "transaction.lock")
        let replacement = root.appending(path: "replacement.lock")
        #expect(FileManager.default.createFile(
            atPath: replacement.path,
            contents: Data(),
            attributes: [.posixPermissions: NSNumber(value: 0o600)]
        ))
        var operationRan = false
        let mutationLock = SystemTLSIdentityMutationLock(
            lockURL: lockURL,
            timeout: 1,
            beforeFinalPathValidation: {
                try FileManager.default.removeItem(at: lockURL)
                try FileManager.default.createSymbolicLink(
                    at: lockURL,
                    withDestinationURL: replacement
                )
            }
        )

        #expect(throws: TLSIdentityProvisionerError.transactionUnavailable) {
            try mutationLock.withLock { operationRan = true }
        }
        #expect(!operationRan)
    }

    @Test func systemMutationLockContendsWithSeparateProcessOnSameTemporaryFile() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "bridge-system-lock-process-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appending(path: "identity-lock", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        let lockURL = directory.appending(path: "transaction.lock")
        let child = Process()
        let output = Pipe()
        let ready = DispatchSemaphore(value: 0)
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = [
            "-c",
            """
            import fcntl, os, sys, time
            descriptor = os.open(sys.argv[1], os.O_CREAT | os.O_RDWR, 0o600)
            os.fchmod(descriptor, 0o600)
            fcntl.flock(descriptor, fcntl.LOCK_EX)
            print("READY", flush=True)
            time.sleep(0.75)
            """,
            lockURL.path,
        ]
        child.standardOutput = output
        child.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { handle in
            if String(decoding: handle.availableData, as: UTF8.self).contains("READY") {
                ready.signal()
            }
        }
        try child.run()
        defer {
            output.fileHandleForReading.readabilityHandler = nil
            if child.isRunning { child.terminate() }
            child.waitUntilExit()
        }
        // Hosted runners can take several seconds to cold-start Python while the
        // rest of the Swift test process is under load. This wait bounds only the
        // fixture startup; the lock contention assertion retains its 100 ms bound.
        try #require(ready.wait(timeout: .now() + 10) == .success)
        let contender = SystemTLSIdentityMutationLock(lockURL: lockURL, timeout: 0.1)

        #expect(throws: TLSIdentityProvisionerError.transactionUnavailable) {
            try contender.withLock {}
        }
    }
}
