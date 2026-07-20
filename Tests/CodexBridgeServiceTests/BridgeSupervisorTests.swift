@testable import CodexBridgeService
import CodexAppServerClient
import CodexBridgeDelivery
import CodexBridgeShared
import Darwin
import Foundation
import Testing

@Test func supervisorEmitsContentFreeDiagnosticLifecycleEvents() async throws {
    let successfulFixture = try SupervisorFixture()
    let successfulEvents = DiagnosticEventRecorder()
    let successfulSupervisor = try BridgeSupervisor(
        stateDirectory: successfulFixture.root,
        minimumFreeBytes: 1,
        availableBytes: { 1_024 },
        recovery: successfulFixture.recovery,
        processor: successfulFixture.processor,
        listener: successfulFixture.listener,
        diagnosticSink: { successfulEvents.record($0) }
    )
    try await successfulSupervisor.start()
    try await successfulSupervisor.pause()
    await successfulSupervisor.shutdown()

    let failedFixture = try SupervisorFixture(listenerShouldFail: true)
    let failedEvents = DiagnosticEventRecorder()
    let failedSupervisor = try BridgeSupervisor(
        stateDirectory: failedFixture.root,
        minimumFreeBytes: 1,
        availableBytes: { 1_024 },
        recovery: failedFixture.recovery,
        processor: failedFixture.processor,
        listener: failedFixture.listener,
        diagnosticSink: { failedEvents.record($0) }
    )
    await #expect(throws: BridgeSupervisorError.listenerFailed) {
        try await failedSupervisor.start()
    }

    #expect(successfulEvents.snapshot() == [
        .serviceStarting,
        .serviceRunning,
        .servicePaused,
        .serviceStopped,
    ])
    #expect(failedEvents.snapshot() == [.serviceStarting, .serviceFailed, .retryScheduled])
}

@Test func supervisorRecoversIntakeAndPendingWorkBeforeAcceptingConnections() async throws {
    let fixture = try SupervisorFixture()
    let supervisor = try BridgeSupervisor(
        stateDirectory: fixture.root,
        minimumFreeBytes: 1,
        availableBytes: { 1_024 },
        recovery: fixture.recovery,
        processor: fixture.processor,
        listener: fixture.listener
    )

    try await supervisor.start()

    #expect(await fixture.events.snapshot() == ["recover-intake", "recover-pending", "start-listener"])
    #expect(await supervisor.status().state == .running)
}

@Test func supervisorPausePersistsKillSwitchAndResumeAllowsAFreshStart() async throws {
    let fixture = try SupervisorFixture()
    let supervisor = try fixture.makeSupervisor()
    try await supervisor.start()
    try await supervisor.registerOwnedChild(fixture.ownedChild)

    try await supervisor.pause()

    #expect(await fixture.listener.stopCount == 1)
    #expect(await fixture.ownedChild.stopCount == 1)
    #expect(await supervisor.status().state == .paused)

    let reloaded = try fixture.makeSupervisor()
    await #expect(throws: BridgeSupervisorError.paused) {
        try await reloaded.start()
    }
    try await reloaded.resume()
    try await reloaded.start()
    #expect(await reloaded.status().state == .running)
}

@Test func supervisorRejectsDiskPressureBeforeRecoveryOrListenerStart() async throws {
    let fixture = try SupervisorFixture()
    let supervisor = try BridgeSupervisor(
        stateDirectory: fixture.root,
        minimumFreeBytes: 1_024,
        availableBytes: { 1_023 },
        recovery: fixture.recovery,
        processor: fixture.processor,
        listener: fixture.listener
    )

    await #expect(throws: BridgeSupervisorError.diskPressure) {
        try await supervisor.start()
    }

    #expect(await fixture.events.snapshot().isEmpty)
}

@Test func supervisorBacksOffReconnectsAndRedactsOperationalStatus() async throws {
    let fixture = try SupervisorFixture(listenerShouldFail: true)
    let supervisor = try fixture.makeSupervisor()

    await #expect(throws: BridgeSupervisorError.listenerFailed) {
        try await supervisor.start()
    }
    #expect(await supervisor.status().nextRetryDelaySeconds == 1)

    await #expect(throws: BridgeSupervisorError.listenerFailed) {
        try await supervisor.retry()
    }
    let status = await supervisor.status()
    #expect(status.nextRetryDelaySeconds == 2)
    #expect(!status.redactedDescription.contains(fixture.root.path))
    #expect(!status.redactedDescription.contains("pairing-token"))
}

@Test func supervisorAppliesBoundedJitterWithoutChangingExponentialBackoffProgression() async throws {
    let fixture = try SupervisorFixture(listenerShouldFail: true)
    let supervisor = try BridgeSupervisor(
        stateDirectory: fixture.root,
        minimumFreeBytes: 1,
        availableBytes: { 1_024 },
        recovery: fixture.recovery,
        processor: fixture.processor,
        listener: fixture.listener,
        retryJitterSeconds: { base in base }
    )

    await #expect(throws: BridgeSupervisorError.listenerFailed) {
        try await supervisor.start()
    }
    #expect(await supervisor.status().nextRetryDelaySeconds == 2)

    await #expect(throws: BridgeSupervisorError.listenerFailed) {
        try await supervisor.retry()
    }
    #expect(await supervisor.status().nextRetryDelaySeconds == 4)
}

@Test func supervisorLeaseMakesStatusLiveOnlyWhileAnOwnedRuntimeHoldsTheLock() async throws {
    let fixture = try SupervisorFixture()
    let supervisor = try fixture.makeSupervisor()
    #expect(try BridgeSupervisor.persistedStatus(stateDirectory: fixture.root).state == .stopped)
    try await supervisor.start()
    #expect(try BridgeSupervisor.persistedStatus(stateDirectory: fixture.root).state == .running)

    let contender = try fixture.makeSupervisor()
    await #expect(throws: BridgeSupervisorError.alreadyRunning) { try await contender.start() }
    await supervisor.shutdown()
    #expect(try BridgeSupervisor.persistedStatus(stateDirectory: fixture.root).state == .stopped)
}

@Test func readinessMarkerRejectsStaleStateAndExistsOnlyAfterListenerStart() async throws {
    let fixture = try SupervisorFixture()
    try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
    let marker = fixture.root.appending(path: "service.ready")
    try Data("stale".utf8).write(to: marker)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o644)], ofItemAtPath: marker.path
    )
    #expect(!BridgeSupervisor.isReady(stateDirectory: fixture.root))

    let supervisor = try fixture.makeSupervisor()
    try await supervisor.start()
    #expect(BridgeSupervisor.isReady(stateDirectory: fixture.root))
    await supervisor.shutdown()
    #expect(!BridgeSupervisor.isReady(stateDirectory: fixture.root))
    #expect(!FileManager.default.fileExists(atPath: marker.path))

    let failed = try SupervisorFixture(listenerShouldFail: true)
    let failedSupervisor = try failed.makeSupervisor()
    await #expect(throws: BridgeSupervisorError.listenerFailed) {
        try await failedSupervisor.start()
    }
    #expect(!BridgeSupervisor.isReady(stateDirectory: failed.root))
}

@Test func persistedStatusProbeNeverCreatesTheServiceLeaseFile() throws {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "bridge-status-read-only-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: NSNumber(value: 0o700)]
    )
    let lock = root.appending(path: "service.lock")

    #expect(try BridgeSupervisor.persistedStatus(stateDirectory: root).state == .stopped)
    #expect(!FileManager.default.fileExists(atPath: lock.path))
}

@Test func serviceLeaseRejectsSymlinkLockPath() throws {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "bridge-service-lease-symlink-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: NSNumber(value: 0o700)]
    )
    let target = root.appending(path: "replacement.lock")
    #expect(FileManager.default.createFile(
        atPath: target.path,
        contents: Data(),
        attributes: [.posixPermissions: NSNumber(value: 0o600)]
    ))
    try FileManager.default.createSymbolicLink(
        at: root.appending(path: "service.lock"),
        withDestinationURL: target
    )
    let lease = BridgeServiceLease(stateDirectory: root)

    #expect(throws: BridgeSupervisorError.statePersistenceFailed) {
        try lease.acquire()
    }
}

@Test func serviceLeaseValidatesOwnerOnlyModeBeforeAcquisition() throws {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "bridge-service-lease-mode-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    let lock = root.appending(path: "service.lock")
    #expect(FileManager.default.createFile(
        atPath: lock.path,
        contents: Data(),
        attributes: [.posixPermissions: NSNumber(value: 0o644)]
    ))
    let lease = BridgeServiceLease(stateDirectory: root)

    try lease.acquire()
    defer { lease.release() }
    var metadata = stat()
    #expect(lstat(lock.path, &metadata) == 0)
    #expect(metadata.st_mode & 0o777 == 0o600)
}

@Test func serviceLeaseRejectsHardLinkedLockPath() throws {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "bridge-service-lease-hardlink-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    let lock = root.appending(path: "service.lock")
    let alias = root.appending(path: "service-alias.lock")
    #expect(FileManager.default.createFile(atPath: lock.path, contents: Data()))
    try FileManager.default.linkItem(at: lock, to: alias)
    let lease = BridgeServiceLease(stateDirectory: root)

    #expect(throws: BridgeSupervisorError.statePersistenceFailed) {
        try lease.acquire()
    }
}

@Test func serviceLeaseRejectsNonRegularLockPath() throws {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "bridge-service-lease-directory-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    try FileManager.default.createDirectory(
        at: root.appending(path: "service.lock"),
        withIntermediateDirectories: false
    )
    let lease = BridgeServiceLease(stateDirectory: root)

    #expect(throws: BridgeSupervisorError.statePersistenceFailed) {
        try lease.acquire()
    }
}

@Test func serviceLeaseRejectsRegularFilePathSwapImmediatelyBeforeAcquisition() throws {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "bridge-service-lease-swap-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: NSNumber(value: 0o700)]
    )
    let lock = root.appending(path: "service.lock")
    let replacement = root.appending(path: "replacement.lock")
    #expect(FileManager.default.createFile(
        atPath: replacement.path,
        contents: Data(),
        attributes: [.posixPermissions: NSNumber(value: 0o600)]
    ))
    let lease = BridgeServiceLease(
        stateDirectory: root,
        beforeFinalPathValidation: {
            try FileManager.default.removeItem(at: lock)
            try FileManager.default.moveItem(at: replacement, to: lock)
        }
    )

    #expect(throws: BridgeSupervisorError.statePersistenceFailed) {
        try lease.acquire()
    }
}

@Test func supervisorTimerObservationStopsTheRuntimeAfterPersistedPause() async throws {
    let fixture = try SupervisorFixture()
    let pauseObserver = ManualPauseObserverScheduler()
    let supervisor = try BridgeSupervisor(
        stateDirectory: fixture.root,
        minimumFreeBytes: 1,
        availableBytes: { 1_024 },
        recovery: fixture.recovery,
        processor: fixture.processor,
        listenerFactory: { fixture.listener },
        pauseObserverScheduler: pauseObserver
    )
    try await supervisor.start()
    #expect(pauseObserver.isRunning)

    try BridgeSupervisor.setPersistedPause(true, stateDirectory: fixture.root)
    pauseObserver.fire()
    await fixture.events.waitFor("stop-listener")

    #expect(await supervisor.status().state == .paused)
    #expect(!pauseObserver.isRunning)
    #expect(!BridgeServiceLease.isLive(stateDirectory: fixture.root))
}

@Test func persistedPauseEmitsOneDiagnosticWhenResidentRuntimeTransitions() async throws {
    let fixture = try SupervisorFixture()
    let pauseObserver = ManualPauseObserverScheduler()
    let diagnostics = DiagnosticEventRecorder()
    let supervisor = try BridgeSupervisor(
        stateDirectory: fixture.root,
        minimumFreeBytes: 1,
        availableBytes: { 1_024 },
        recovery: fixture.recovery,
        processor: fixture.processor,
        listenerFactory: { fixture.listener },
        pauseObserverScheduler: pauseObserver,
        diagnosticSink: { diagnostics.record($0) }
    )
    try await supervisor.start()
    try BridgeSupervisor.setPersistedPause(true, stateDirectory: fixture.root)
    pauseObserver.fire()
    await fixture.events.waitFor("stop-listener")
    pauseObserver.fire()
    try await supervisor.pause()

    #expect(diagnostics.snapshot().filter { $0 == .servicePaused }.count == 1)
}

@Test func reconnectBackoffIsInterruptibleByPersistedPauseUsingInjectedSleeper() async throws {
    let fixture = try SupervisorFixture(listenerShouldFail: true)
    let sleeps = SleepRecorder()
    let supervisor = try BridgeSupervisor(
        stateDirectory: fixture.root,
        minimumFreeBytes: 1,
        availableBytes: { 1_024 },
        recovery: fixture.recovery,
        processor: fixture.processor,
        listener: fixture.listener,
        sleepSeconds: { seconds in
            try? BridgeSupervisor.setPersistedPause(true, stateDirectory: fixture.root)
            await sleeps.record(seconds)
        }
    )

    let runtime = Task { try await supervisor.runWithReconnect() }
    await sleeps.waitForValue()
    await fixture.events.waitFor("stop-listener")
    #expect(await fixture.listener.stopCount == 1)
    #expect(try BridgeSupervisor.persistedStatus(stateDirectory: fixture.root).state == .paused)
    await supervisor.shutdown()
    try await runtime.value
    #expect(await sleeps.values.first == 1)
}

@Test func persistedPauseDuringStartupFailureAwaitsOwnedProcessorStopBeforePausedBackoff() async throws {
    let fixture = try SupervisorFixture()
    let processor = SuspendedStoppablePendingProcessor()
    let sleeps = SleepRecorder()
    let listener = PersistingFailListener(stateDirectory: fixture.root)
    let supervisor = try BridgeSupervisor(
        stateDirectory: fixture.root,
        minimumFreeBytes: 1,
        availableBytes: { 1_024 },
        recovery: fixture.recovery,
        processor: processor,
        listener: listener,
        sleepSeconds: { seconds in await sleeps.record(seconds) }
    )
    let runtime = Task { try await supervisor.runWithReconnect() }

    await listener.waitUntilStartFailed()
    let stopDeadline = ContinuousClock.now.advanced(by: .seconds(1))
    while ContinuousClock.now < stopDeadline {
        let stopStarted = await processor.hasStopStarted
        let didSleep = !(await sleeps.values.isEmpty)
        if stopStarted || didSleep { break }
        try await Task.sleep(for: .milliseconds(1))
    }
    let stopStarted = await processor.hasStopStarted
    #expect(stopStarted)
    #expect(await sleeps.values.isEmpty)
    #expect(await supervisor.status().state != .paused)
    await processor.releaseStop()
    if stopStarted {
        await processor.waitUntilStopFinished()
        await sleeps.waitForValue()
        #expect(await supervisor.status().state == .paused)
        #expect(await processor.stopCount == 1)
        await supervisor.shutdown()
    } else {
        await supervisor.shutdown()
        await processor.waitUntilStopFinished()
    }
    try await runtime.value
}

@Test func persistedPauseDrainIsJoinedByReentrantRunLoopAndShutdown() async throws {
    let fixture = try SupervisorFixture()
    let processor = SuspendedStoppablePendingProcessor()
    let listener = ScriptedListener()
    let pauseObserver = ManualPauseObserverScheduler()
    let supervisor = try BridgeSupervisor(
        stateDirectory: fixture.root,
        minimumFreeBytes: 1,
        availableBytes: { 1_024 },
        recovery: fixture.recovery,
        processor: processor,
        listenerFactory: { listener },
        pauseObserverScheduler: pauseObserver
    )
    let runtime = Task { try await supervisor.runWithReconnect() }
    await listener.waitUntilStarted()
    for _ in 0 ..< 100 where await supervisor.status().state != .running { await Task.yield() }
    try await supervisor.registerOwnedChild(fixture.ownedChild)
    try BridgeSupervisor.setPersistedPause(true, stateDirectory: fixture.root)
    pauseObserver.fire()
    await processor.waitUntilStopStarted()

    // Listener stop wakes the resident run loop, which re-enters the same
    // persisted-pause drain while the processor still owns live work.
    for _ in 0 ..< 100 { await Task.yield() }
    #expect(await supervisor.status().state == .running)

    let shutdownProbe = AsyncCallProbe()
    let shutdown = Task {
        await shutdownProbe.begin()
        await supervisor.shutdown()
        await shutdownProbe.complete()
    }
    await shutdownProbe.waitUntilBegan()
    for _ in 0 ..< 100 where !(await shutdownProbe.didComplete) { await Task.yield() }

    #expect(!(await shutdownProbe.didComplete))
    #expect(await listener.stopCount == 1)
    #expect(await processor.stopCount == 1)
    #expect(await fixture.ownedChild.stopCount == 0)
    #expect(BridgeServiceLease.isLive(stateDirectory: fixture.root))

    await processor.releaseStop()
    await shutdown.value
    try await runtime.value
    #expect(await shutdownProbe.didComplete)
    #expect(await supervisor.status().state == .stopped)
    #expect(await listener.stopCount == 1)
    #expect(await processor.stopCount == 1)
    #expect(await fixture.ownedChild.stopCount == 1)
    #expect(!BridgeServiceLease.isLive(stateDirectory: fixture.root))
}

@Test func resumeAwaitsInFlightPauseDrainBeforeStartingFreshRuntime() async throws {
    let fixture = try SupervisorFixture()
    let processor = SuspendedStoppablePendingProcessor()
    let first = ScriptedListener()
    let second = ScriptedListener()
    let factory = ListenerFactorySequence([first, second])
    let supervisor = try BridgeSupervisor(
        stateDirectory: fixture.root,
        minimumFreeBytes: 1,
        availableBytes: { 1_024 },
        recovery: fixture.recovery,
        processor: processor,
        listenerFactory: { try factory.make() }
    )
    try await supervisor.start()
    let pause = Task { try await supervisor.pause() }
    await processor.waitUntilStopStarted()

    let restartProbe = AsyncCallProbe()
    let restart = Task {
        await restartProbe.begin()
        try await supervisor.resume()
        await restartProbe.complete()
        try await supervisor.start()
    }
    await restartProbe.waitUntilBegan()
    for _ in 0 ..< 100 where !(await restartProbe.didComplete) { await Task.yield() }

    #expect(!(await restartProbe.didComplete))
    #expect(factory.createdCount == 1)
    #expect(await processor.stopCount == 1)

    await processor.releaseStop()
    try await pause.value
    try await restart.value
    await second.waitUntilStarted()
    #expect(await restartProbe.didComplete)
    #expect(factory.createdCount == 2)
    #expect(await supervisor.status().state == .running)
    #expect(await processor.stopCount == 1)
    await supervisor.shutdown()
}

@Test func runningSupervisorObservesExternalPauseAndStopsAdmissionRuntime() async throws {
    let fixture = try SupervisorFixture()
    let pauseObserver = ManualPauseObserverScheduler()
    let supervisor = try BridgeSupervisor(
        stateDirectory: fixture.root,
        minimumFreeBytes: 1,
        availableBytes: { 1_024 },
        recovery: fixture.recovery,
        processor: fixture.processor,
        listenerFactory: { fixture.listener },
        pauseObserverScheduler: pauseObserver
    )
    try await supervisor.start()
    try BridgeSupervisor.setPersistedPause(true, stateDirectory: fixture.root)
    pauseObserver.fire()
    await fixture.events.waitFor("stop-listener")

    #expect(await supervisor.status().state == .paused)
    #expect(await fixture.listener.stopCount == 1)
}

@Test func terminationHandlingIsInstalledBeforeAnyRecoveryStarts() async throws {
    let fixture = try SupervisorFixture()
    let supervisor = try fixture.makeSupervisor()
    let runtime = Task {
        try await BridgeRuntimeBootstrap.start(supervisor: supervisor) {
            await fixture.events.record("install-signals")
        }
    }
    await fixture.events.waitFor("start-listener")
    await supervisor.shutdown()
    try await runtime.value
    let events = await fixture.events.snapshot()
    #expect(events.first == "install-signals")
    #expect(events.dropFirst().prefix(3) == ["recover-intake", "recover-pending", "start-listener"])
}

@Test func residentSupervisorCreatesFreshListenerAfterPostReadyFailureAndStopsOnShutdown() async throws {
    let fixture = try SupervisorFixture()
    let first = ScriptedListener()
    let second = ScriptedListener()
    let factory = ListenerFactorySequence([first, second])
    let supervisor = try BridgeSupervisor(
        stateDirectory: fixture.root,
        minimumFreeBytes: 1,
        availableBytes: { 1_024 },
        recovery: fixture.recovery,
        processor: fixture.processor,
        listenerFactory: { try factory.make() },
        sleepSeconds: { _ in await Task.yield() }
    )

    let runtime = Task { try await supervisor.runWithReconnect() }
    await first.waitUntilStarted()
    await first.failAfterReady()
    await second.waitUntilStarted()

    #expect(factory.createdCount == 2)
    #expect(await first.stopCount == 1)
    await supervisor.shutdown()
    try await runtime.value
    #expect(await second.stopCount == 1)
}

@Test func persistedExternalResumeRestartsTheExistingResidentDaemon() async throws {
    let fixture = try SupervisorFixture()
    let first = ScriptedListener()
    let second = ScriptedListener()
    let factory = ListenerFactorySequence([first, second])
    let supervisor = try BridgeSupervisor(
        stateDirectory: fixture.root,
        minimumFreeBytes: 1,
        availableBytes: { 1_024 },
        recovery: fixture.recovery,
        processor: fixture.processor,
        listenerFactory: { try factory.make() },
        sleepSeconds: { _ in await Task.yield() }
    )
    let runtime = Task { try await supervisor.runWithReconnect() }
    await first.waitUntilStarted()

    try BridgeSupervisor.setPersistedPause(true, stateDirectory: fixture.root)
    await first.waitUntilStoppedBySupervisor()
    #expect(await supervisor.status().state == .paused)
    try BridgeSupervisor.setPersistedPause(false, stateDirectory: fixture.root)
    await second.waitUntilStarted()

    #expect(factory.createdCount == 2)
    #expect(await supervisor.status().state == .running)
    await supervisor.shutdown()
    try await runtime.value
}

@Test func shutdownStopsOnlyExplicitlyOwnedChildren() async throws {
    let fixture = try SupervisorFixture()
    let supervisor = try fixture.makeSupervisor()
    let desktopOwnedChild = OwnedChildStub()
    try await supervisor.start()
    try await supervisor.registerOwnedChild(fixture.ownedChild)

    await supervisor.shutdown()

    #expect(await fixture.listener.stopCount == 1)
    #expect(await fixture.ownedChild.stopCount == 1)
    #expect(await desktopOwnedChild.stopCount == 0)
    #expect(await supervisor.status().state == .stopped)
}

@Test func concurrentShutdownCallersJoinOneOwnedChildDrainUntilItFinishes() async throws {
    let fixture = try SupervisorFixture()
    let supervisor = try fixture.makeSupervisor()
    let child = SuspendedOwnedChild()
    try await supervisor.start()
    try await supervisor.registerOwnedChild(child)

    async let firstShutdown: Void = supervisor.shutdown()
    await child.waitUntilStopStarted()
    async let secondShutdown: Void = supervisor.shutdown()
    for _ in 0 ..< 100 { await Task.yield() }

    #expect(await child.stopCount == 1)
    #expect(await supervisor.status().state == .running)

    await child.finishStop()
    _ = await (firstShutdown, secondShutdown)

    #expect(await child.stopCount == 1)
    #expect(await child.stopFinishCount == 1)
    #expect(await supervisor.status().state == .stopped)
}

@Test func concurrentSupervisorShutdownsAwaitOneRealBoundedTransportKill() async throws {
    let fixture = try SupervisorFixture()
    let processFixture = try SupervisorTransportFixture(deliverKill: true)
    defer { processFixture.cleanup() }
    let supervisor = try fixture.makeSupervisor()
    let child = TransportOwnedChild(transport: processFixture.transport)
    try await processFixture.transport.connect()
    try await processFixture.waitUntilReady()
    try await supervisor.start()
    try await supervisor.registerOwnedChild(child)

    let firstShutdown = Task { await supervisor.shutdown() }
    try await processFixture.waitUntilTerminate()
    let secondProbe = AsyncCallProbe()
    let secondShutdown = Task {
        await secondProbe.begin()
        await supervisor.shutdown()
        await secondProbe.complete()
    }
    await secondProbe.waitUntilBegan()
    for _ in 0 ..< 100 { await Task.yield() }

    #expect(!(await secondProbe.didComplete))

    await firstShutdown.value
    await secondShutdown.value

    let childPID = try #require(processFixture.childPID)
    #expect(await child.lastOutcome == .stopped)
    #expect(processFixture.signaling.terminatedPIDs == [childPID])
    #expect(processFixture.signaling.killedPIDs == [childPID])
    #expect(!processFixture.childIsRunning)
    #expect(processFixture.sentinel.isRunning)
    #expect(await supervisor.status().state == .stopped)
    #expect(await supervisor.status().ownedChildCount == 0)
}

@Test func failedRealTransportKillRemainsRegisteredAndDiagnostic() async throws {
    let fixture = try SupervisorFixture()
    let processFixture = try SupervisorTransportFixture(deliverKill: false)
    defer { processFixture.cleanup() }
    let supervisor = try fixture.makeSupervisor()
    let child = TransportOwnedChild(transport: processFixture.transport)
    try await processFixture.transport.connect()
    try await processFixture.waitUntilReady()
    try await supervisor.start()
    try await supervisor.registerOwnedChild(child)

    await supervisor.shutdown()

    let childPID = try #require(processFixture.childPID)
    #expect(await child.lastOutcome == .stillRunning(pid: childPID, killResult: -1))
    #expect(processFixture.childIsRunning)
    #expect(processFixture.sentinel.isRunning)
    #expect(await supervisor.status().state == .shutdownBlocked)
    #expect(await supervisor.status().ownedChildCount == 1)
    #expect(await supervisor.status().ownedChildStopFailures == [
        BridgeOwnedChildStopFailure(pid: childPID, killResult: -1),
    ])
    #expect(await supervisor.status().redactedDescription.contains("owned-children=1"))
    #expect(BridgeServiceLease.isLive(stateDirectory: fixture.root))
    #expect(try BridgeSupervisor.persistedStatus(stateDirectory: fixture.root).state != .stopped)

    let contender = try fixture.makeSupervisor()
    await #expect(throws: BridgeSupervisorError.alreadyRunning) {
        try await contender.start()
    }
    if await contender.status().state == .running {
        await contender.shutdown()
    }

    processFixture.signaling.allowKill()
    await supervisor.shutdown()

    #expect(await child.lastOutcome == .stopped)
    #expect(!processFixture.childIsRunning)
    #expect(processFixture.sentinel.isRunning)
    #expect(await supervisor.status().state == .stopped)
    #expect(await supervisor.status().ownedChildCount == 0)
    #expect(await supervisor.status().ownedChildStopFailures.isEmpty)
    #expect(!BridgeServiceLease.isLive(stateDirectory: fixture.root))
    #expect(try BridgeSupervisor.persistedStatus(stateDirectory: fixture.root).state == .stopped)

    try await contender.start()
    #expect(await contender.status().state == .running)
    await contender.shutdown()
    #expect(try BridgeSupervisor.persistedStatus(stateDirectory: fixture.root).state == .stopped)
}

@Test func pendingIntakeRecoveryEnumeratesAndHandsEveryValidatedRecordToProcessor() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "bridge-pending-recovery-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    let store = try IntakeStore(rootURL: root)
    let memoID = try MemoID("77777777-7777-7777-7777-777777777777")
    let audio = Data("durable-local-audio".utf8)
    let capturedAt = Date(timeIntervalSince1970: 1_700_000_123)
    let request = try IntakeRequest(
        memoID: memoID,
        audioSHA256: AudioDigest.hex(audio),
        byteCount: audio.count,
        revision: 1,
        capturedAt: capturedAt,
        localeHint: "en-US"
    )
    let receivedAt = Date(timeIntervalSince1970: 1_700_000_000)
    _ = try await store.commit(request: request, body: audio, receivedAt: receivedAt)
    let processor = RecoveredMemoProcessorStub()

    try await IntakeStorePendingMemoProcessor(
        intakeStore: store,
        processor: processor,
        maximumRecords: 8
    ).recoverPendingMemos()

    let recovered = await processor.requests
    #expect(recovered.map(\.memoID) == [memoID])
    #expect(recovered[0].capturedAt == capturedAt)
    #expect(recovered[0].localeHint == "en-US")
    #expect(recovered[0].committedAudio.expectedSHA256 == AudioDigest.hex(audio))
}

@Test func boundedProcessorAcknowledgesAdmissionWithoutWaitingForProcessingAndRecoversDurableOverflow() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "bridge-bounded-processor-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    let store = try IntakeStore(rootURL: root)
    let firstID = try MemoID("88888888-8888-8888-8888-888888888888")
    let secondID = try MemoID("99999999-9999-9999-9999-999999999999")
    let first = try await commitRecord(id: firstID, store: store)
    let second = try await commitRecord(id: secondID, store: store)
    let processor = BlockingMemoProcessor()
    let worker = BoundedIntakeMemoProcessor(intakeStore: store, processor: processor, maximumQueuedRecords: 1)

    try await worker.recoverPendingMemos()
    await worker.admit(first)
    await worker.admit(second)

    await processor.waitForRequests(atLeast: 1)
    #expect(await processor.requests.map(\.memoID) == [firstID])
    #expect(await worker.status().queuedRecordCount <= 1)

    await processor.release()
    await processor.waitForRequests(atLeast: 2)
    #expect(Set(await processor.requests.map(\.memoID)) == Set([firstID, secondID]))
    await worker.stop()
}

@Test func boundedProcessorArchivesIntakeOnlyAfterVerifiedDelivery() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "bridge-processor-retention-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    let intake = root.appending(path: "intake", directoryHint: .isDirectory)
    let retained = root.appending(path: "retained", directoryHint: .isDirectory)
    let delivery = root.appending(path: "delivery", directoryHint: .isDirectory)
    let deliveredAt = Date(timeIntervalSince1970: 1_700_000_100)
    let memoID = try MemoID("89898989-8989-8989-8989-898989898989")
    let store = try IntakeStore(rootURL: intake, retentionRootURL: retained)
    _ = try await commitRecord(id: memoID, store: store)
    let journal = try DeliveryJournal(root: delivery, clock: { deliveredAt })
    try markDelivered(memoID: memoID, journal: journal)
    let retention = try BridgeDeliveredRetentionController(
        intakeStore: store,
        journal: journal
    )
    let processor = RecoveredMemoProcessorStub()
    let worker = BoundedIntakeMemoProcessor(
        intakeStore: store,
        processor: processor,
        onDelivered: { memoID in
            try await retention.retainDelivered(memoID)
        }
    )

    try await worker.recoverPendingMemos()
    let deadline = ContinuousClock.now.advanced(by: .seconds(1))
    while try await store.retainedRecord(for: memoID) == nil,
          ContinuousClock.now < deadline
    {
        await Task.yield()
    }

    #expect(try await store.committedRecord(for: memoID) == nil)
    #expect(try await store.retainedRecord(for: memoID)?.deliveredAt == deliveredAt)
    await worker.stop()
}

@Test func boundedProcessorDelaysRetryWithoutSpinningAndPublishesCompletionOnce() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "bridge-delayed-retry-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    let store = try IntakeStore(rootURL: root)
    let memoID = try MemoID("8a8a8a8a-8a8a-8a8a-8a8a-8a8a8a8a8a8a")
    _ = try await commitRecord(id: memoID, store: store)
    let processor = ScriptedOutcomeMemoProcessor(outcomes: [.retryable, .delivered])
    let sleeper = ManualRetrySleeper()
    let completions = CompletionRecorder()
    let worker = BoundedIntakeMemoProcessor(
        intakeStore: store,
        processor: processor,
        maximumQueuedRecords: 1,
        sample: { 1 },
        sleep: { delay in await sleeper.sleep(delay) },
        onDelivered: { memoID in await completions.record(memoID) }
    )

    try await worker.recoverPendingMemos()
    await processor.waitForRequests(atLeast: 1)
    await sleeper.waitForDelay()
    for _ in 0 ..< 100 { await Task.yield() }

    #expect(await sleeper.delays == [5])
    #expect(await processor.requests.count == 1)
    #expect(await completions.memoIDs.isEmpty)

    await sleeper.release()
    await processor.waitForRequests(atLeast: 2)
    await completions.waitForCount(1)
    for _ in 0 ..< 100 { await Task.yield() }

    #expect(await processor.requests.map(\.memoID) == [memoID, memoID])
    #expect(await completions.memoIDs == [memoID])
    await worker.stop()
}

@Test func boundedProcessorParksNeedsAttentionWithoutSchedulingRetry() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "bridge-attention-parked-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    let store = try IntakeStore(rootURL: root)
    let memoID = try MemoID("8b8b8b8b-8b8b-8b8b-8b8b-8b8b8b8b8b8b")
    _ = try await commitRecord(id: memoID, store: store)
    let processor = ScriptedOutcomeMemoProcessor(outcomes: [.needsAttention, .delivered])
    let sleeper = ManualRetrySleeper()
    let worker = BoundedIntakeMemoProcessor(
        intakeStore: store,
        processor: processor,
        sample: { 1 },
        sleep: { delay in await sleeper.sleep(delay) }
    )

    try await worker.recoverPendingMemos()
    await processor.waitForRequests(atLeast: 1)
    for _ in 0 ..< 100 { await Task.yield() }

    #expect(await processor.requests.count == 1)
    #expect(await sleeper.delays.isEmpty)
    await worker.stop()
}

@Test func boundedProcessorPublishesConcurrentDeliveredOutcomeOnlyOnce() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "bridge-concurrent-delivery-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    let store = try IntakeStore(rootURL: root)
    let memoID = try MemoID("8c8c8c8c-8c8c-8c8c-8c8c-8c8c8c8c8c8c")
    _ = try await commitRecord(id: memoID, store: store)
    let processor = DeliveredRetryProcessor()
    let completions = SuspendingCompletionRecorder()
    let worker = BoundedIntakeMemoProcessor(
        intakeStore: store,
        processor: processor,
        onDelivered: { memoID in await completions.recordAndSuspendFirst(memoID) }
    )

    let first = Task { try await worker.retryCommitted(memoID) }
    await completions.waitForCount(1)
    let second = Task { try await worker.retryCommitted(memoID) }
    for _ in 0 ..< 100 { await Task.yield() }

    #expect(await completions.memoIDs == [memoID])

    await completions.releaseFirst()
    try await first.value
    try await second.value
    #expect(await completions.memoIDs == [memoID])
}

@Test func boundedProcessorDoesNotSuppressRetryAfterCompletionPublicationFailure() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "bridge-completion-retry-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    let store = try IntakeStore(rootURL: root)
    let memoID = try MemoID("8f8f8f8f-8f8f-8f8f-8f8f-8f8f8f8f8f8f")
    _ = try await commitRecord(id: memoID, store: store)
    let processor = DeliveredRetryProcessor()
    let completions = FailingOnceCompletionPublisher()
    let worker = BoundedIntakeMemoProcessor(
        intakeStore: store,
        processor: processor,
        onDelivered: { memoID in try await completions.publish(memoID) }
    )

    await #expect(throws: CompletionFixtureError.self) {
        try await worker.retryCommitted(memoID)
    }
    try await worker.retryCommitted(memoID)

    #expect(await completions.memoIDs == [memoID, memoID])
}

@Test func boundedProcessorResetsBackoffAfterRetryEpisodeParksInAttention() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "bridge-retry-episode-reset-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    let store = try IntakeStore(rootURL: root)
    let firstID = try MemoID("8d8d8d8d-8d8d-8d8d-8d8d-8d8d8d8d8d8d")
    let secondID = try MemoID("8e8e8e8e-8e8e-8e8e-8e8e-8e8e8e8e8e8e")
    _ = try await commitRecord(id: firstID, store: store)
    let processor = ScriptedOutcomeMemoProcessor(
        outcomes: [.retryable, .needsAttention, .retryable, .needsAttention]
    )
    let sleeper = SequencedRetrySleeper()
    let worker = BoundedIntakeMemoProcessor(
        intakeStore: store,
        processor: processor,
        maximumQueuedRecords: 1,
        sample: { 1 },
        sleep: { delay in await sleeper.sleep(delay) }
    )

    try await worker.recoverPendingMemos()
    await sleeper.waitForDelays(atLeast: 1)
    #expect(await sleeper.delays == [5])
    await sleeper.releaseNext()
    await processor.waitForRequests(atLeast: 2)
    for _ in 0 ..< 100 where await worker.status().running { await Task.yield() }
    #expect(!(await worker.status().running))

    let second = try await commitRecord(id: secondID, store: store)
    await worker.admit(second)
    await sleeper.waitForDelays(atLeast: 2)

    #expect(await sleeper.delays == [5, 5])

    await sleeper.releaseNext()
    await processor.waitForRequests(atLeast: 4)
    for _ in 0 ..< 100 where await worker.status().running { await Task.yield() }
    await worker.stop()
}

@Test func boundedProcessorResetsBackoffAfterStopAndRecover() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "bridge-retry-stop-recover-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try IntakeStore(rootURL: root)
    let firstID = try MemoID("91919191-9191-9191-9191-919191919191")
    let secondID = try MemoID("92929292-9292-9292-9292-929292929292")
    _ = try await commitRecord(id: firstID, store: store)
    let processor = ScriptedOutcomeMemoProcessor(
        outcomes: [.retryable, .retryable, .retryable, .needsAttention]
    )
    let sleeper = SequencedRetrySleeper()
    let worker = BoundedIntakeMemoProcessor(
        intakeStore: store,
        processor: processor,
        maximumQueuedRecords: 1,
        sample: { 1 },
        sleep: { delay in await sleeper.sleep(delay) }
    )

    try await worker.recoverPendingMemos()
    await sleeper.waitForDelays(atLeast: 1)
    #expect(await sleeper.delays == [5])
    await sleeper.releaseNext()
    await sleeper.waitForDelays(atLeast: 2)
    #expect(await sleeper.delays == [5, 10])
    await worker.stop()

    _ = try await commitRecord(id: secondID, store: store)
    try await worker.recoverPendingMemos()
    await sleeper.waitForDelays(atLeast: 3)
    // Stop/recover must not inherit the prior episode's elevated attempt.
    #expect(await sleeper.delays == [5, 10, 5])
    await sleeper.releaseNext()
    await processor.waitForRequests(atLeast: 4)
    for _ in 0 ..< 100 where await worker.status().running { await Task.yield() }
    await worker.stop()
}

@Test func boundedProcessorRescansFromBeginningWhenLiveOverflowSortsBeforeCursor() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "bridge-overflow-cursor-\(UUID().uuidString)", directoryHint: .isDirectory)
    let store = try IntakeStore(rootURL: root)
    let initialID = try MemoID("90000000-0000-0000-0000-000000000000")
    let queuedID = try MemoID("a0000000-0000-0000-0000-000000000000")
    let lowerLiveID = try MemoID("10000000-0000-0000-0000-000000000000")
    let initial = try await commitRecord(id: initialID, store: store)
    let processor = BlockingMemoProcessor()
    let worker = BoundedIntakeMemoProcessor(intakeStore: store, processor: processor, maximumQueuedRecords: 1)

    // Recover only the first durable page, then force one queued live ID and
    // one lower-sorting overflow while the first request is still blocked.
    try await worker.recoverPendingMemos()
    await processor.waitForRequests(atLeast: 1)
    let queued = try await commitRecord(id: queuedID, store: store)
    await worker.admit(queued)
    let lowerLive = try await commitRecord(id: lowerLiveID, store: store)
    await worker.admit(lowerLive)
    await processor.release()
    await processor.waitForRequests(atLeast: 3)

    #expect(Set(await processor.requests.map(\.memoID)) == Set([initial.memoID, queuedID, lowerLiveID]))
    await worker.stop()
}

@Test func boundedProcessorDiscardsStaleRefillAfterReentrantLiveOverflowReset() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "bridge-refill-race-\(UUID().uuidString)", directoryHint: .isDirectory)
    let store = try IntakeStore(rootURL: root)
    let lowerID = try MemoID("10000000-0000-0000-0000-000000000000")
    let cursorID = try MemoID("90000000-0000-0000-0000-000000000000")
    let upperID = try MemoID("a0000000-0000-0000-0000-000000000000")
    let lower = try await commitRecord(id: lowerID, store: store)
    let cursor = try await commitRecord(id: cursorID, store: store)
    let upper = try await commitRecord(id: upperID, store: store)
    let source = SuspendingIntakeRecordSource(
        backing: store,
        initialCursorRecord: cursor,
        suspendedUpperRecord: upper
    )
    let processor = BlockingMemoProcessor()
    let worker = BoundedIntakeMemoProcessor(intakeStore: source, processor: processor, maximumQueuedRecords: 1)

    try await worker.recoverPendingMemos()
    await processor.waitForRequests(atLeast: 1)
    await processor.release()
    await source.waitUntilUpperPageRequested()
    await worker.admit(lower)
    await worker.admit(upper)
    await source.releaseUpperPage()
    await source.waitUntilRecoveryUpperPageRequested()
    await processor.waitForRequests(atLeast: 3)

    let processedIDs = Set(await processor.requests.map(\.memoID))
    #expect(processedIDs == Set([lowerID, cursorID, upperID]))
    await worker.stop()
}

@Test func boundedProcessorStopCancelsAndAwaitsItsOwnedWorker() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "bridge-worker-drain-\(UUID().uuidString)", directoryHint: .isDirectory)
    let store = try IntakeStore(rootURL: root)
    _ = try await commitRecord(id: MemoID("20000000-0000-0000-0000-000000000000"), store: store)
    let processor = CancellationTrackingMemoProcessor()
    let worker = BoundedIntakeMemoProcessor(intakeStore: store, processor: processor, maximumQueuedRecords: 1)

    try await worker.recoverPendingMemos()
    await processor.waitUntilStarted()
    await worker.stop()

    #expect(await processor.didFinishCancellation)
    #expect(await worker.status().running == false)
}

@Test func runtimePathsKeepSupervisorStateAndEmptyCodexInboxSeparateFromDurableData() throws {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "bridge-runtime-paths-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    let paths = try BridgeRuntimePaths(root: root)

    #expect(paths.service.path == root.appending(path: "service", directoryHint: .isDirectory).path)
    #expect(paths.codexInbox.path == root.appending(path: "codex-inbox", directoryHint: .isDirectory).path)
    #expect(paths.retained.path == root.appending(path: "retained", directoryHint: .isDirectory).path)
    #expect(paths.codexInbox != paths.intake)
    #expect(paths.codexInbox != paths.delivery)
    #expect(paths.retained != paths.intake)
    #expect(paths.retained != paths.delivery)
    try paths.prepareRoot()
    #expect(FileManager.default.fileExists(atPath: paths.root.path))
    try paths.prepareCodexInbox()
    #expect(try FileManager.default.contentsOfDirectory(atPath: paths.codexInbox.path).isEmpty)
}

@Test func runtimePathsRejectCodexInboxThatIsNotAnEmptyPrivateOwnedDirectory() throws {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "bridge-runtime-inbox-rejection-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    let paths = try BridgeRuntimePaths(root: root)
    try paths.prepareRoot()
    try FileManager.default.createDirectory(at: paths.codexInbox, withIntermediateDirectories: false)
    try Data("unexpected".utf8).write(to: paths.codexInbox.appending(path: "leftover"))

    #expect(throws: BridgeSupervisorError.statePersistenceFailed) {
        try paths.prepareCodexInbox()
    }

    try FileManager.default.removeItem(at: paths.codexInbox)
    try FileManager.default.createSymbolicLink(atPath: paths.codexInbox.path, withDestinationPath: root.path)
    #expect(throws: BridgeSupervisorError.statePersistenceFailed) {
        try paths.prepareCodexInbox()
    }
}

@Test func secureLocalFileRejectsSymlinkDirectoryAndWorldReadableCredentials() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "bridge-secure-file-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let privateFile = root.appending(path: "credential")
    try Data("secret".utf8).write(to: privateFile)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: privateFile.path)
    #expect(try SecureLocalFile.readUTF8PrivateFile(at: privateFile) == "secret")

    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: privateFile.path)
    #expect(throws: SecureLocalFileError.invalidFile) { try SecureLocalFile.readPrivateData(at: privateFile) }

    let link = root.appending(path: "credential-link")
    try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: privateFile.path)
    #expect(throws: SecureLocalFileError.invalidFile) { try SecureLocalFile.readPrivateData(at: link) }
    #expect(throws: SecureLocalFileError.invalidFile) { try SecureLocalFile.readPrivateData(at: root) }
}

private final class SupervisorFixture: @unchecked Sendable {
    let root: URL
    let events = EventRecorder()
    let recovery: RecoveryStub
    let processor: ProcessorStub
    let listener: ListenerStub
    let ownedChild = OwnedChildStub()

    init(listenerShouldFail: Bool = false) throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "bridge-supervisor-tests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        recovery = RecoveryStub(events: events)
        processor = ProcessorStub(events: events)
        listener = ListenerStub(events: events, shouldFail: listenerShouldFail)
    }

    func makeSupervisor() throws -> BridgeSupervisor {
        try BridgeSupervisor(
            stateDirectory: root,
            minimumFreeBytes: 1,
            availableBytes: { 1_024 },
            recovery: recovery,
            processor: processor,
            listener: listener,
            retryJitterSeconds: { _ in 0 }
        )
    }
}

private actor EventRecorder {
    private var values: [String] = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func record(_ value: String) {
        values.append(value)
        let pending = waiters.removeValue(forKey: value) ?? []
        for continuation in pending { continuation.resume() }
    }
    func snapshot() -> [String] { values }
    func waitFor(_ value: String) async {
        guard !values.contains(value) else { return }
        await withCheckedContinuation { waiters[value, default: []].append($0) }
    }
}

private final class DiagnosticEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [BridgeDiagnosticEvent] = []

    func record(_ event: BridgeDiagnosticEvent) {
        lock.withLock { values.append(event) }
    }

    func snapshot() -> [BridgeDiagnosticEvent] {
        lock.withLock { values }
    }
}

private actor SleepRecorder {
    private(set) var values: [Int] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func record(_ seconds: Int) {
        values.append(seconds)
        let pending = waiters
        waiters.removeAll()
        for continuation in pending { continuation.resume() }
    }
    func waitForValue() async {
        guard values.isEmpty else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private final class ManualPauseObserverScheduler: BridgePauseObservationScheduling, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable () -> Void)?

    var isRunning: Bool { lock.withLock { handler != nil } }

    func start(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock { self.handler = handler }
    }

    func stop() {
        lock.withLock { handler = nil }
    }

    func fire() {
        let current = lock.withLock { handler }
        current?()
    }
}

private actor AsyncCallProbe {
    private var began = false
    private(set) var didComplete = false
    private var beginWaiters: [CheckedContinuation<Void, Never>] = []

    func begin() {
        began = true
        let pending = beginWaiters
        beginWaiters.removeAll()
        for continuation in pending { continuation.resume() }
    }

    func complete() { didComplete = true }

    func waitUntilBegan() async {
        guard !began else { return }
        await withCheckedContinuation { beginWaiters.append($0) }
    }
}

private actor RecoveryStub: BridgeIntakeRecovering {
    let events: EventRecorder

    init(events: EventRecorder) { self.events = events }
    func recoverIntake() async throws { await events.record("recover-intake") }
}

private actor ProcessorStub: BridgePendingMemoProcessing {
    let events: EventRecorder

    init(events: EventRecorder) { self.events = events }
    func recoverPendingMemos() async throws { await events.record("recover-pending") }
}

private actor SuspendedStoppablePendingProcessor: BridgePendingMemoProcessing, BridgePendingMemoStopping {
    private var stopStarted = false
    private var stopFinished = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var stopCount = 0
    var hasStopStarted: Bool { stopStarted }

    func recoverPendingMemos() async throws {}

    func stopPendingMemos() async {
        stopCount += 1
        stopStarted = true
        let started = startWaiters
        startWaiters.removeAll()
        for continuation in started { continuation.resume() }
        if !released {
            await withCheckedContinuation { releaseWaiters.append($0) }
        }
        stopFinished = true
        let finished = finishWaiters
        finishWaiters.removeAll()
        for continuation in finished { continuation.resume() }
    }

    func waitUntilStopStarted() async {
        guard !stopStarted else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func releaseStop() {
        released = true
        let pending = releaseWaiters
        releaseWaiters.removeAll()
        for continuation in pending { continuation.resume() }
    }

    func waitUntilStopFinished() async {
        guard !stopFinished else { return }
        await withCheckedContinuation { finishWaiters.append($0) }
    }
}

private actor ListenerStub: BridgeListenerControlling {
    let events: EventRecorder
    let shouldFail: Bool
    private(set) var stopCount = 0

    init(events: EventRecorder, shouldFail: Bool) {
        self.events = events
        self.shouldFail = shouldFail
    }

    func start() async throws {
        await events.record("start-listener")
        if shouldFail { throw ListenerFailure.failed }
    }

    private var stopped = false
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilStopped() async throws {
        guard !stopped else { return }
        await withCheckedContinuation { stopWaiters.append($0) }
    }

    func stop() async {
        stopCount += 1
        stopped = true
        let pending = stopWaiters
        stopWaiters.removeAll()
        for continuation in pending { continuation.resume() }
        await events.record("stop-listener")
    }
}

private actor PersistingFailListener: BridgeListenerControlling {
    let stateDirectory: URL
    private var startFailed = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    init(stateDirectory: URL) { self.stateDirectory = stateDirectory }

    func start() async throws {
        try BridgeSupervisor.setPersistedPause(true, stateDirectory: stateDirectory)
        startFailed = true
        let pending = startWaiters
        startWaiters.removeAll()
        for continuation in pending { continuation.resume() }
        throw ListenerFailure.failed
    }

    func waitUntilStopped() async throws {}
    func stop() async {}

    func waitUntilStartFailed() async {
        guard !startFailed else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }
}

private final class ListenerFactorySequence: @unchecked Sendable {
    private let lock = NSLock()
    private var listeners: [ScriptedListener]
    private var count = 0

    init(_ listeners: [ScriptedListener]) { self.listeners = listeners }

    var createdCount: Int { lock.withLock { count } }

    func make() throws -> any BridgeListenerControlling {
        try lock.withLock {
            guard !listeners.isEmpty else { throw ListenerFailure.failed }
            count += 1
            return listeners.removeFirst()
        }
    }
}

private actor ScriptedListener: BridgeListenerControlling {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var terminalResult: Result<Void, any Error>?
    private var terminalWaiters: [CheckedContinuation<Void, any Error>] = []
    private var supervisorStopWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var stopCount = 0

    func start() async throws {
        started = true
        let pending = startWaiters
        startWaiters.removeAll()
        for continuation in pending { continuation.resume() }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func waitUntilStopped() async throws {
        if let terminalResult { return try terminalResult.get() }
        try await withCheckedThrowingContinuation { terminalWaiters.append($0) }
    }

    func failAfterReady() {
        finish(.failure(ListenerFailure.failed))
    }

    func stop() async {
        stopCount += 1
        finish(.success(()))
        let pending = supervisorStopWaiters
        supervisorStopWaiters.removeAll()
        for continuation in pending { continuation.resume() }
    }

    func waitUntilStoppedBySupervisor() async {
        guard stopCount == 0 else { return }
        await withCheckedContinuation { supervisorStopWaiters.append($0) }
    }

    private func finish(_ result: Result<Void, any Error>) {
        guard terminalResult == nil else { return }
        terminalResult = result
        let pending = terminalWaiters
        terminalWaiters.removeAll()
        for continuation in pending { continuation.resume(with: result) }
    }
}

private actor OwnedChildStub: BridgeOwnedChild {
    private(set) var stopCount = 0
    func stop() async -> BridgeOwnedChildStopOutcome {
        stopCount += 1
        return .stopped
    }
}

private actor SuspendedOwnedChild: BridgeOwnedChild {
    private(set) var stopCount = 0
    private(set) var stopFinishCount = 0
    private var didStart = false
    private var didFinish = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []

    func stop() async -> BridgeOwnedChildStopOutcome {
        stopCount += 1
        didStart = true
        let pendingStarts = startWaiters
        startWaiters.removeAll()
        for continuation in pendingStarts { continuation.resume() }

        if !didFinish {
            await withCheckedContinuation { finishWaiters.append($0) }
        }
        stopFinishCount += 1
        return .stopped
    }

    func waitUntilStopStarted() async {
        guard !didStart else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func finishStop() {
        didFinish = true
        let pendingFinishes = finishWaiters
        finishWaiters.removeAll()
        for continuation in pendingFinishes { continuation.resume() }
    }
}

private actor TransportOwnedChild: BridgeOwnedChild {
    let transport: StdioProcessTransport
    private(set) var lastOutcome: BridgeOwnedChildStopOutcome?

    init(transport: StdioProcessTransport) {
        self.transport = transport
    }

    func stop() async -> BridgeOwnedChildStopOutcome {
        let outcome: BridgeOwnedChildStopOutcome
        switch await transport.closeWithOutcome() {
        case .alreadyExited, .graceful, .terminated, .killed:
            outcome = .stopped
        case let .stillRunning(pid, killResult):
            outcome = .stillRunning(pid: pid, killResult: killResult)
        }
        lastOutcome = outcome
        return outcome
    }
}

private final class SupervisorTransportFixture: @unchecked Sendable {
    let recorder = SupervisorProcessRecorder()
    let signaling: SupervisorTransportSignaling
    let sentinel = Process()
    let transport: StdioProcessTransport

    var childPID: pid_t? { recorder.process?.processIdentifier }
    var childIsRunning: Bool { recorder.process?.isRunning ?? false }

    init(deliverKill: Bool) throws {
        signaling = SupervisorTransportSignaling(deliverKill: deliverKill)
        transport = StdioProcessTransport(
            executable: "/bin/sh",
            arguments: ["-c", "trap '' TERM; printf 'READY\\n'; while :; do :; done"],
            processFactory: recorder.makeProcess,
            shutdown: OwnedChildShutdown(
                policy: OwnedChildShutdownPolicy(
                    gracefulTimeout: .milliseconds(80),
                    terminateTimeout: .milliseconds(80),
                    killTimeout: .milliseconds(500)
                ),
                signaling: signaling
            )
        )

        sentinel.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sentinel.arguments = ["60"]
        sentinel.standardInput = FileHandle.nullDevice
        sentinel.standardOutput = FileHandle.nullDevice
        sentinel.standardError = FileHandle.nullDevice
        try sentinel.run()
    }

    func waitUntilReady() async throws {
        var frames = transport.frames().makeAsyncIterator()
        #expect(try await frames.next() == Data("READY".utf8))
    }

    func waitUntilTerminate() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while signaling.terminatedPIDs.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(!signaling.terminatedPIDs.isEmpty)
    }

    func cleanup() {
        if let process = recorder.process, process.isRunning {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
        }
        if sentinel.isRunning {
            _ = Darwin.kill(sentinel.processIdentifier, SIGKILL)
        }
    }
}

private final class SupervisorProcessRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedProcess: Process?

    var process: Process? { lock.withLock { recordedProcess } }

    func makeProcess() -> Process {
        let process = Process()
        lock.withLock { recordedProcess = process }
        return process
    }
}

private final class SupervisorTransportSignaling: OwnedProcessSignaling, @unchecked Sendable {
    private let lock = NSLock()
    private var shouldDeliverKill: Bool
    private var terminations: [pid_t] = []
    private var kills: [pid_t] = []

    init(deliverKill: Bool) {
        shouldDeliverKill = deliverKill
    }

    var terminatedPIDs: [pid_t] { lock.withLock { terminations } }
    var killedPIDs: [pid_t] { lock.withLock { kills } }

    func allowKill() {
        lock.withLock { shouldDeliverKill = true }
    }

    func terminate(_ process: Process) {
        lock.withLock { terminations.append(process.processIdentifier) }
        process.terminate()
    }

    func kill(pid: pid_t) -> Int32 {
        let deliverKill = lock.withLock {
            kills.append(pid)
            return shouldDeliverKill
        }
        guard deliverKill else { return -1 }
        return Darwin.kill(pid, SIGKILL)
    }
}

private actor RecoveredMemoProcessorStub: BridgeMemoProcessing {
    private(set) var requests: [MemoProcessingRequest] = []

    func process(_ request: MemoProcessingRequest) async throws -> MemoProcessingOutcome {
        requests.append(request)
        return .delivered
    }
}

private actor ScriptedOutcomeMemoProcessor: BridgeMemoProcessing {
    private var outcomes: [MemoProcessingOutcome]
    private(set) var requests: [MemoProcessingRequest] = []
    private var requestWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    init(outcomes: [MemoProcessingOutcome]) {
        self.outcomes = outcomes
    }

    func process(_ request: MemoProcessingRequest) async throws -> MemoProcessingOutcome {
        requests.append(request)
        let ready = requestWaiters.filter { $0.0 <= requests.count }
        requestWaiters.removeAll { $0.0 <= requests.count }
        for (_, continuation) in ready { continuation.resume() }
        return outcomes.isEmpty ? .needsAttention : outcomes.removeFirst()
    }

    func waitForRequests(atLeast count: Int) async {
        guard requests.count < count else { return }
        await withCheckedContinuation { continuation in
            requestWaiters.append((count, continuation))
        }
    }
}

private actor DeliveredRetryProcessor: BridgeMemoProcessing, BridgeMemoRetrying {
    func process(_ request: MemoProcessingRequest) async throws -> MemoProcessingOutcome {
        _ = request
        return .delivered
    }

    func retry(_ request: MemoProcessingRequest) async throws -> MemoProcessingOutcome {
        _ = request
        return .delivered
    }
}

private actor ManualRetrySleeper {
    private(set) var delays: [TimeInterval] = []
    private var delayWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var released = false

    func sleep(_ delay: TimeInterval) async {
        delays.append(delay)
        let pending = delayWaiters
        delayWaiters.removeAll()
        for continuation in pending { continuation.resume() }
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitForDelay() async {
        guard delays.isEmpty else { return }
        await withCheckedContinuation { delayWaiters.append($0) }
    }

    func release() {
        released = true
        let pending = releaseWaiters
        releaseWaiters.removeAll()
        for continuation in pending { continuation.resume() }
    }
}

private actor CompletionRecorder {
    private(set) var memoIDs: [MemoID] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func record(_ memoID: MemoID) {
        memoIDs.append(memoID)
        let ready = waiters.filter { $0.0 <= memoIDs.count }
        waiters.removeAll { $0.0 <= memoIDs.count }
        for (_, continuation) in ready { continuation.resume() }
    }

    func waitForCount(_ count: Int) async {
        guard memoIDs.count < count else { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }
}

private actor SuspendingCompletionRecorder {
    private(set) var memoIDs: [MemoID] = []
    private var countWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var firstReleaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstReleased = false

    func recordAndSuspendFirst(_ memoID: MemoID) async {
        memoIDs.append(memoID)
        let ready = countWaiters.filter { $0.0 <= memoIDs.count }
        countWaiters.removeAll { $0.0 <= memoIDs.count }
        for (_, continuation) in ready { continuation.resume() }
        guard memoIDs.count == 1, !firstReleased else { return }
        await withCheckedContinuation { firstReleaseWaiters.append($0) }
    }

    func waitForCount(_ count: Int) async {
        guard memoIDs.count < count else { return }
        await withCheckedContinuation { countWaiters.append((count, $0)) }
    }

    func releaseFirst() {
        firstReleased = true
        let pending = firstReleaseWaiters
        firstReleaseWaiters.removeAll()
        for continuation in pending { continuation.resume() }
    }
}

private enum CompletionFixtureError: Error {
    case unavailable
}

private actor FailingOnceCompletionPublisher {
    private(set) var memoIDs: [MemoID] = []

    func publish(_ memoID: MemoID) throws {
        memoIDs.append(memoID)
        if memoIDs.count == 1 { throw CompletionFixtureError.unavailable }
    }
}

private actor SequencedRetrySleeper {
    private(set) var delays: [TimeInterval] = []
    private var delayWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var sleepWaiters: [CheckedContinuation<Void, Never>] = []

    func sleep(_ delay: TimeInterval) async {
        delays.append(delay)
        let ready = delayWaiters.filter { $0.0 <= delays.count }
        delayWaiters.removeAll { $0.0 <= delays.count }
        for (_, continuation) in ready { continuation.resume() }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if Task.isCancelled {
                    continuation.resume()
                    return
                }
                sleepWaiters.append(continuation)
            }
        } onCancel: {
            Task { await self.resumeCancelledWaiter() }
        }
    }

    func waitForDelays(atLeast count: Int) async {
        guard delays.count < count else { return }
        await withCheckedContinuation { delayWaiters.append((count, $0)) }
    }

    func releaseNext() {
        guard !sleepWaiters.isEmpty else { return }
        sleepWaiters.removeFirst().resume()
    }

    private func resumeCancelledWaiter() {
        guard !sleepWaiters.isEmpty else { return }
        sleepWaiters.removeFirst().resume()
    }
}

private actor BlockingMemoProcessor: BridgeMemoProcessing {
    private(set) var requests: [MemoProcessingRequest] = []
    private var isReleased = false
    private var requestWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func process(_ request: MemoProcessingRequest) async throws -> MemoProcessingOutcome {
        requests.append(request)
        let ready = requestWaiters.filter { $0.count <= requests.count }
        requestWaiters.removeAll { $0.count <= requests.count }
        for waiter in ready { waiter.continuation.resume() }
        while !isReleased { await Task.yield() }
        return .delivered
    }

    func release() { isReleased = true }

    func waitForRequests(atLeast count: Int) async {
        guard requests.count < count else { return }
        await withCheckedContinuation { continuation in
            requestWaiters.append((count, continuation))
        }
    }
}

private actor CancellationTrackingMemoProcessor: BridgeMemoProcessing {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var didFinishCancellation = false

    func process(_ request: MemoProcessingRequest) async throws -> MemoProcessingOutcome {
        _ = request
        started = true
        let pending = startWaiters
        startWaiters.removeAll()
        for continuation in pending { continuation.resume() }
        do {
            try await Task.sleep(for: .seconds(60))
            return .delivered
        } catch is CancellationError {
            didFinishCancellation = true
            throw CancellationError()
        }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }
}

private actor SuspendingIntakeRecordSource: BridgeIntakeRecordSource {
    private let backing: IntakeStore
    private let initialCursorRecord: CommittedIntakeRecord
    private let suspendedUpperRecord: CommittedIntakeRecord
    private var initialPageServed = false
    private var upperPageRequested = false
    private var upperPageReleased = false
    private var recoveryUpperPageRequested = false
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []
    private var recoveryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        backing: IntakeStore,
        initialCursorRecord: CommittedIntakeRecord,
        suspendedUpperRecord: CommittedIntakeRecord
    ) {
        self.backing = backing
        self.initialCursorRecord = initialCursorRecord
        self.suspendedUpperRecord = suspendedUpperRecord
    }

    func committedRecord(for memoID: MemoID) async throws -> CommittedIntakeRecord? {
        try await backing.committedRecord(for: memoID)
    }

    func committedRecordPage(
        maximumEntries: Int,
        afterMemoID: MemoID?
    ) async throws -> CommittedIntakePage {
        if !initialPageServed {
            initialPageServed = true
            return CommittedIntakePage(records: [initialCursorRecord], hasMore: true)
        }
        if afterMemoID == initialCursorRecord.memoID, !upperPageRequested {
            upperPageRequested = true
            let pending = requestWaiters
            requestWaiters.removeAll()
            for continuation in pending { continuation.resume() }
            if !upperPageReleased {
                await withCheckedContinuation { releaseWaiters.append($0) }
            }
            return CommittedIntakePage(records: [suspendedUpperRecord], hasMore: false)
        }
        if afterMemoID == initialCursorRecord.memoID {
            recoveryUpperPageRequested = true
            let pending = recoveryWaiters
            recoveryWaiters.removeAll()
            for continuation in pending { continuation.resume() }
        }
        return try await backing.committedRecordPage(
            maximumEntries: maximumEntries,
            afterMemoID: afterMemoID
        )
    }

    func waitUntilUpperPageRequested() async {
        guard !upperPageRequested else { return }
        await withCheckedContinuation { requestWaiters.append($0) }
    }

    func releaseUpperPage() {
        upperPageReleased = true
        let pending = releaseWaiters
        releaseWaiters.removeAll()
        for continuation in pending { continuation.resume() }
    }

    func waitUntilRecoveryUpperPageRequested() async {
        guard !recoveryUpperPageRequested else { return }
        await withCheckedContinuation { recoveryWaiters.append($0) }
    }
}

private func commitRecord(id: MemoID, store: IntakeStore) async throws -> CommittedIntakeRecord {
    let audio = Data("audio-\(id.rawValue)".utf8)
    let request = try IntakeRequest(
        memoID: id,
        audioSHA256: AudioDigest.hex(audio),
        byteCount: audio.count,
        revision: 1,
        capturedAt: Date(timeIntervalSince1970: 1_700_000_001)
    )
    _ = try await store.commit(request: request, body: audio)
    return try #require(await store.committedRecord(for: id))
}

private func markDelivered(memoID: MemoID, journal: DeliveryJournal) throws {
    let audio = Data("audio-\(memoID.rawValue)".utf8)
    try journal.create(.received(
        memoID: memoID,
        capturedAt: Date(timeIntervalSince1970: 1_700_000_001),
        localeHint: nil,
        audioSHA256: AudioDigest.hex(audio)
    ))
    _ = try journal.transition(memoID: memoID, to: .transcribing)
    _ = try journal.transition(memoID: memoID, to: .readyForCodex, transcript: "Delivered idea")
    _ = try journal.transition(memoID: memoID, to: .inserting)
    _ = try journal.transition(memoID: memoID, to: .reconciling)
    _ = try journal.transition(memoID: memoID, to: .delivered)
}

private enum ListenerFailure: Error { case failed }
