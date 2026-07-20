import CodexBridgeShared
import CryptoKit
import Foundation
import Network
import Security

public enum NetworkBridgeListenerError: Error, Equatable, Sendable {
    case invalidFingerprint
    case invalidHost
    case invalidTimeout
    case alreadyStarted
    case stopped
    case unavailable
}

public struct BridgeTLSIdentity: @unchecked Sendable {
    public let tlsOptions: NWProtocolTLS.Options
    public let publicKeySHA256: String

    public init(tlsOptions: NWProtocolTLS.Options, publicKeySHA256: String) throws {
        guard Self.isSHA256Hex(publicKeySHA256) else {
            throw NetworkBridgeListenerError.invalidFingerprint
        }
        self.tlsOptions = tlsOptions
        self.publicKeySHA256 = publicKeySHA256.lowercased()
    }

    public init(secIdentity: SecIdentity) throws {
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(secIdentity, &certificate) == errSecSuccess,
              let certificate,
              let publicKey = SecCertificateCopyKey(certificate),
              let publicBytes = SecKeyCopyExternalRepresentation(publicKey, nil) as Data?,
              let protocolIdentity = sec_identity_create(secIdentity)
        else { throw NetworkBridgeListenerError.unavailable }
        let options = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(options.securityProtocolOptions, protocolIdentity)
        try self.init(
            tlsOptions: options,
            publicKeySHA256: SHA256.hash(data: publicBytes)
                .map { String(format: "%02x", $0) }
                .joined()
        )
    }

    private static func isSHA256Hex(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (48 ... 57).contains(byte)
                || (65 ... 70).contains(byte)
                || (97 ... 102).contains(byte)
        }
    }
}

public protocol BridgeTLSIdentityProvider: Sendable {
    func loadIdentity() throws -> BridgeTLSIdentity
}

public struct BridgeBonjourAdvertisement: Equatable, Sendable {
    public static let requiredServiceType = "_voiceinbox._tcp"

    public let serviceName: String
    public let serviceType: String
    public let advertisedHost: String
    public let publicKeySHA256: String

    public init(serviceName: String, advertisedHost: String, publicKeySHA256: String) {
        self.serviceName = serviceName
        serviceType = Self.requiredServiceType
        self.advertisedHost = advertisedHost
        self.publicKeySHA256 = publicKeySHA256
    }

    public func txtRecord(port: UInt16) -> [String: String] {
        [
            "host": advertisedHost,
            "port": String(port),
            "protocol-version": String(BridgeProtocolVersion.current.major),
            "public-key-sha256": publicKeySHA256,
        ]
    }
}

public struct NetworkBridgeEndpoint: Equatable, Sendable {
    public let host: String
    public let port: UInt16
    public let isTLS: Bool

    public init(host: String, port: UInt16, isTLS: Bool) {
        self.host = host
        self.port = port
        self.isTLS = isTLS
    }
}

public struct BridgeListenerDeadlineCancellation: Sendable {
    private let cancelOperation: @Sendable () -> Void

    public init(_ cancelOperation: @escaping @Sendable () -> Void) {
        self.cancelOperation = cancelOperation
    }

    public func cancel() {
        cancelOperation()
    }
}

public struct BridgeListenerDeadlineScheduler: Sendable {
    private let scheduleOperation: @Sendable (
        TimeInterval,
        @escaping @Sendable () -> Void
    ) -> BridgeListenerDeadlineCancellation

    public init(
        _ scheduleOperation: @escaping @Sendable (
            TimeInterval,
            @escaping @Sendable () -> Void
        ) -> BridgeListenerDeadlineCancellation
    ) {
        self.scheduleOperation = scheduleOperation
    }

    public func schedule(
        after delay: TimeInterval,
        _ action: @escaping @Sendable () -> Void
    ) -> BridgeListenerDeadlineCancellation {
        scheduleOperation(delay, action)
    }

    static func dispatch(on queue: DispatchQueue) -> Self {
        Self { delay, action in
            let scheduled = BridgeListenerDispatchDeadline(action: action)
            queue.asyncAfter(deadline: .now() + delay, execute: scheduled.workItem)
            return BridgeListenerDeadlineCancellation { scheduled.cancel() }
        }
    }
}

private final class BridgeListenerDispatchDeadline: @unchecked Sendable {
    let workItem: DispatchWorkItem

    init(action: @escaping @Sendable () -> Void) {
        workItem = DispatchWorkItem(block: action)
    }

    func cancel() {
        workItem.cancel()
    }
}

public final class NetworkBridgeListener: @unchecked Sendable {
    public let advertisement: BridgeBonjourAdvertisement

    private let configuration: BridgeConfiguration
    private let router: BridgeRequestRouter
    private let listener: NWListener
    private let queue: DispatchQueue
    private let admissionGate: ConnectionAdmissionGate
    private let deadlineScheduler: BridgeListenerDeadlineScheduler
    private let bindHost: String
    private let usesTLS: Bool
    private let advertisesBonjour: Bool
    private let onAcceptedRequest: (@Sendable () -> Void)?
    private let lock = NSLock()
    private var didStart = false
    private var didStop = false
    private var startContinuation: CheckedContinuation<NetworkBridgeEndpoint, any Error>?
    private var lifetimeContinuation: CheckedContinuation<Void, any Error>?
    private var terminalResult: Result<Void, any Error>?
    private var stopTask: Task<Void, Never>?
    private var activeRequests: [UUID: OneRequestConnection] = [:]

    public init(
        configuration: BridgeConfiguration,
        router: BridgeRequestRouter,
        identityProvider: any BridgeTLSIdentityProvider,
        serviceName: String,
        bindHost: String,
        advertisedHost: String,
        onAcceptedRequest: (@Sendable () -> Void)? = nil
    ) throws {
        guard Self.isValidConcreteBindHost(bindHost),
              Self.isValidAdvertisedHost(advertisedHost)
        else {
            throw NetworkBridgeListenerError.invalidHost
        }
        try Self.validate(configuration)
        let identity = try identityProvider.loadIdentity()
        let parameters = NWParameters(tls: identity.tlsOptions, tcp: NWProtocolTCP.Options())
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(bindHost), port: .any)

        self.configuration = configuration
        self.router = router
        listener = try NWListener(using: parameters)
        let listenerQueue = DispatchQueue(label: "ai.rsitech.voiceinbox.bridge-listener")
        queue = listenerQueue
        deadlineScheduler = .dispatch(on: listenerQueue)
        admissionGate = try ConnectionAdmissionGate(
            maximumConnections: configuration.maximumConnections,
            maximumUploads: configuration.maximumUploads
        )
        self.bindHost = bindHost
        usesTLS = true
        advertisesBonjour = true
        self.onAcceptedRequest = onAcceptedRequest
        advertisement = BridgeBonjourAdvertisement(
            serviceName: serviceName,
            advertisedHost: advertisedHost,
            publicKeySHA256: identity.publicKeySHA256
        )
        installHandlers()
    }

    public init(
        testingLoopbackPlaintextWithConfiguration configuration: BridgeConfiguration,
        router: BridgeRequestRouter,
        deadlineScheduler: BridgeListenerDeadlineScheduler? = nil,
        onAcceptedRequest: (@Sendable () -> Void)? = nil
    ) throws {
        try Self.validate(configuration)
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)

        self.configuration = configuration
        self.router = router
        listener = try NWListener(using: parameters)
        let listenerQueue = DispatchQueue(label: "ai.rsitech.voiceinbox.bridge-listener.test")
        queue = listenerQueue
        self.deadlineScheduler = deadlineScheduler ?? .dispatch(on: listenerQueue)
        admissionGate = try ConnectionAdmissionGate(
            maximumConnections: configuration.maximumConnections,
            maximumUploads: configuration.maximumUploads
        )
        bindHost = "127.0.0.1"
        usesTLS = false
        advertisesBonjour = false
        self.onAcceptedRequest = onAcceptedRequest
        advertisement = BridgeBonjourAdvertisement(
            serviceName: "",
            advertisedHost: "127.0.0.1",
            publicKeySHA256: String(repeating: "0", count: 64)
        )
        installHandlers()
    }

    public func start() async throws -> NetworkBridgeEndpoint {
        let canStart = lock.withLock { () -> Bool in
            guard !didStart, !didStop else { return false }
            didStart = true
            return true
        }
        guard canStart else { throw NetworkBridgeListenerError.alreadyStarted }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock { startContinuation = continuation }
                listener.start(queue: queue)
            }
        } onCancel: {
            Task { await self.stop() }
        }
    }

    public func waitUntilStopped() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let completed = lock.withLock { () -> Result<Void, any Error>? in
                    if let terminalResult { return terminalResult }
                    lifetimeContinuation = continuation
                    return nil
                }
                if let completed { continuation.resume(with: completed) }
            }
        } onCancel: {
            Task { await self.stop() }
        }
    }

    public func stop() async {
        let task = lock.withLock { () -> Task<Void, Never> in
            if let stopTask { return stopTask }
            didStop = true
            defer { startContinuation = nil }
            if terminalResult == nil { terminalResult = .success(()) }
            defer { lifetimeContinuation = nil }
            let active = Array(activeRequests.values)
            activeRequests.removeAll()
            let start = startContinuation
            let lifetime = lifetimeContinuation
            let listener = self.listener
            let task = Task {
                listener.cancel()
                start?.resume(throwing: NetworkBridgeListenerError.stopped)
                lifetime?.resume()
                await withTaskGroup(of: Void.self) { group in
                    for request in active {
                        group.addTask { await request.cancelForShutdown() }
                    }
                }
            }
            stopTask = task
            return task
        }
        await task.value
    }

    var activeRequestCountForTesting: Int { lock.withLock { activeRequests.count } }

    private func installHandlers() {
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            self?.listenerStateChanged(state)
        }
    }

    private func listenerStateChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            guard let rawPort = listener.port?.rawValue else {
                failStart()
                return
            }
            if advertisesBonjour {
                let txtRecord = NWTXTRecord(advertisement.txtRecord(port: rawPort))
                listener.service = NWListener.Service(
                    name: advertisement.serviceName,
                    type: advertisement.serviceType,
                    domain: nil,
                    txtRecord: txtRecord
                )
            }
            resumeStart(
                with: .success(
                    NetworkBridgeEndpoint(host: bindHost, port: rawPort, isTLS: usesTLS)
                )
            )
        case .failed:
            if lock.withLock({ startContinuation != nil }) {
                failStart()
            } else {
                failLifetime()
            }
        case .cancelled:
            let cancellationState = lock.withLock { (starting: startContinuation != nil, expected: didStop) }
            if cancellationState.starting {
                resumeStart(with: .failure(NetworkBridgeListenerError.stopped))
            } else if !cancellationState.expected {
                failLifetime()
            }
        default:
            break
        }
    }

    private func failStart() {
        resumeStart(with: .failure(NetworkBridgeListenerError.unavailable))
        listener.cancel()
    }

    private func failLifetime() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, any Error>? in
            guard terminalResult == nil else { return nil }
            terminalResult = .failure(NetworkBridgeListenerError.unavailable)
            defer { lifetimeContinuation = nil }
            return lifetimeContinuation
        }
        continuation?.resume(throwing: NetworkBridgeListenerError.unavailable)
        Task { await self.stop() }
    }

    private func resumeStart(with result: Result<NetworkBridgeEndpoint, any Error>) {
        let continuation = lock.withLock { () -> CheckedContinuation<NetworkBridgeEndpoint, any Error>? in
            defer { startContinuation = nil }
            return startContinuation
        }
        continuation?.resume(with: result)
    }

    private func accept(_ connection: NWConnection) {
        let mayAccept = lock.withLock { !didStop }
        guard mayAccept else {
            connection.cancel()
            return
        }
        Task { [weak self] in
            guard let self,
                  let connectionToken = await admissionGate.acquireConnection()
            else {
                connection.cancel()
                return
            }
            queue.async { [weak self] in
                self?.register(connection, connectionToken: connectionToken)
            }
        }
    }

    private func register(_ connection: NWConnection, connectionToken: UUID) {
        let requestID = UUID()
        guard let parser = try? HTTPRequestHeadParser(maxHeaderBytes: configuration.maximumHeaderBytes) else {
            connection.cancel()
            Task { _ = await admissionGate.releaseConnection(connectionToken) }
            return
        }
        let request = OneRequestConnection(
            connection: connection,
            router: router,
            configuration: configuration,
            headParser: parser,
            queue: queue,
            deadlineScheduler: deadlineScheduler,
            admissionGate: admissionGate,
            connectionToken: connectionToken,
            onFinish: { [weak self] in
                _ = self?.lock.withLock { self?.activeRequests.removeValue(forKey: requestID) }
            }
        )
        let accepted = lock.withLock { () -> Bool in
            guard !didStop else { return false }
            activeRequests[requestID] = request
            return true
        }
        guard accepted else {
            Task { await request.cancelForShutdown() }
            return
        }
        onAcceptedRequest?()
        request.start()
    }

    private static func validate(_ configuration: BridgeConfiguration) throws {
        _ = try HTTPRequestHeadParser(maxHeaderBytes: configuration.maximumHeaderBytes)
    }

    public static func isValidWatchReachableBindHost(_ value: String) -> Bool {
        guard isValidConcreteBindHost(value) else { return false }
        switch NWEndpoint.Host(value) {
        case let .ipv4(address):
            return !isIPv4Loopback(address)
        case let .ipv6(address):
            return address != .loopback
        case .name:
            return false
        @unknown default:
            return false
        }
    }

    public static func isValidWatchReachableAdvertisedHost(_ value: String) -> Bool {
        guard isValidAdvertisedHost(value) else { return false }
        switch NWEndpoint.Host(value) {
        case let .ipv4(address):
            return !isIPv4Loopback(address)
        case let .ipv6(address):
            return address != .loopback
        case let .name(name, _):
            var normalized = name.lowercased()
            while normalized.hasSuffix(".") { normalized.removeLast() }
            return normalized != "localhost" && !normalized.hasSuffix(".localhost")
        @unknown default:
            return false
        }
    }

    private static func isIPv4Loopback(_ address: IPv4Address) -> Bool {
        address.rawValue.first == 127
    }

    private static func isValidConcreteBindHost(_ value: String) -> Bool {
        guard isSyntacticallySafeHost(value) else { return false }
        switch NWEndpoint.Host(value) {
        case let .ipv4(address):
            return address != .any
        case let .ipv6(address):
            return address != .any
        case .name:
            return false
        @unknown default:
            return false
        }
    }

    private static func isValidAdvertisedHost(_ value: String) -> Bool {
        isSyntacticallySafeHost(value)
            && !["0.0.0.0", "::", "[::]", "*"].contains(value.lowercased())
    }

    private static func isSyntacticallySafeHost(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 255
            && value.utf8.allSatisfy { byte in byte >= 0x21 && byte <= 0x7E }
    }
}

private final class OneRequestConnection: @unchecked Sendable {
    private enum State: Equatable {
        case readingHead
        case preparing
        case readingBufferedBody
        case streamingUpload
        case responding
    }

    private let connection: NWConnection
    private let router: BridgeRequestRouter
    private let configuration: BridgeConfiguration
    private let queue: DispatchQueue
    private let deadlineScheduler: BridgeListenerDeadlineScheduler
    private let admissionGate: ConnectionAdmissionGate
    private let connectionToken: UUID
    private var headParser: HTTPRequestHeadParser
    private var state = State.readingHead
    private var bufferedHead: HTTPRequestHead?
    private var bufferedBody = Data()
    private var maximumBufferedBodyBytes = 0
    private var preparedUpload: PreparedBridgeUpload?
    private var receivedUploadBytes = 0
    private var uploadToken: UUID?
    private var headerDeadline: BridgeListenerDeadlineCancellation?
    private var idleBodyDeadline: BridgeListenerDeadlineCancellation?
    private var totalDeadline: BridgeListenerDeadlineCancellation?
    private var headerDeadlineGeneration: UInt64 = 0
    private var idleBodyDeadlineGeneration: UInt64 = 0
    private var totalDeadlineGeneration: UInt64 = 0
    private var finished = false
    private var responseStarted = false
    private var retainedUntilFinished: OneRequestConnection?
    private var routeTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private let onFinish: @Sendable () -> Void

    init(
        connection: NWConnection,
        router: BridgeRequestRouter,
        configuration: BridgeConfiguration,
        headParser: HTTPRequestHeadParser,
        queue: DispatchQueue,
        deadlineScheduler: BridgeListenerDeadlineScheduler,
        admissionGate: ConnectionAdmissionGate,
        connectionToken: UUID,
        onFinish: @escaping @Sendable () -> Void
    ) {
        self.connection = connection
        self.router = router
        self.configuration = configuration
        self.headParser = headParser
        self.queue = queue
        self.deadlineScheduler = deadlineScheduler
        self.admissionGate = admissionGate
        self.connectionToken = connectionToken
        self.onFinish = onFinish
    }

    func start() {
        retainedUntilFinished = self
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.finish(cancelRouteTask: true)
            default:
                break
            }
        }
        headerDeadlineGeneration &+= 1
        let headerGeneration = headerDeadlineGeneration
        headerDeadline = scheduleDeadline(after: configuration.headerTimeout) { [weak self] in
            guard let self,
                  headerDeadlineGeneration == headerGeneration,
                  state == .readingHead
            else { return }
            send(HTTPResponse(status: 408))
        }
        totalDeadlineGeneration &+= 1
        let totalGeneration = totalDeadlineGeneration
        totalDeadline = scheduleDeadline(after: configuration.totalRequestTimeout) { [weak self] in
            guard let self, totalDeadlineGeneration == totalGeneration else { return }
            send(HTTPResponse(status: 408))
        }
        connection.start(queue: queue)
        receive()
    }

    private func receive() {
        guard !finished,
              state == .readingHead || state == .readingBufferedBody || state == .streamingUpload
        else { return }
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 64 * 1_024
        ) { [weak self] data, _, isComplete, error in
            guard let self, !finished else { return }
            if error != nil {
                finish(cancelRouteTask: true)
                return
            }
            if let data, !data.isEmpty {
                handle(data)
                return
            }
            isComplete ? finish(cancelRouteTask: true) : receive()
        }
    }

    private func handle(_ data: Data) {
        switch state {
        case .readingHead:
            do {
                guard let parsed = try headParser.append(data) else {
                    receive()
                    return
                }
                cancelHeaderDeadline()
                state = .preparing
                prepare(parsed)
            } catch let error as HTTPParserError {
                send(HTTPResponse(status: error == .headersTooLarge ? 413 : 400))
            } catch {
                send(HTTPResponse(status: 400))
            }
        case .readingBufferedBody:
            appendBuffered(data)
        case .streamingUpload:
            appendStreaming(data)
        case .preparing, .responding:
            break
        }
    }

    private func prepare(_ parsed: ParsedRequestHead) {
        let task = Task { [weak self, router, admissionGate] in
            let prepared = await router.prepare(parsed.head)
            guard !Task.isCancelled else { return }
            switch prepared {
            case let .reject(response):
                self?.queue.async { [weak self] in self?.send(response) }
            case let .buffered(head, maximumBodyBytes):
                self?.queue.async { [weak self] in
                    self?.beginBuffered(
                        head: head,
                        maximumBodyBytes: maximumBodyBytes,
                        initialBodyBytes: parsed.initialBodyBytes
                    )
                }
            case let .upload(authenticated):
                guard let token = await admissionGate.acquireUpload() else {
                    let response = HTTPResponse(
                        status: 503,
                        headers: ["content-type": "application/json"],
                        body: Data("{\"error\":\"upload_capacity\"}".utf8)
                    )
                    self?.queue.async { [weak self] in self?.send(response) }
                    return
                }
                let start = await router.beginUpload(authenticated)
                if Task.isCancelled {
                    if case let .ready(upload) = start { await router.cancelUpload(upload) }
                    _ = await admissionGate.releaseUpload(token)
                    return
                }
                self?.queue.async { [weak self] in
                    self?.beginUpload(
                        start,
                        token: token,
                        initialBodyBytes: parsed.initialBodyBytes
                    )
                }
            }
        }
        routeTask = task
    }

    private func beginBuffered(
        head: HTTPRequestHead,
        maximumBodyBytes: Int,
        initialBodyBytes: Data
    ) {
        guard !finished,
              head.contentLength <= maximumBodyBytes,
              head.contentLength <= configuration.maximumBodyBytes,
              initialBodyBytes.count <= head.contentLength
        else {
            send(HTTPResponse(status: 413))
            return
        }
        bufferedHead = head
        maximumBufferedBodyBytes = maximumBodyBytes
        bufferedBody.removeAll(keepingCapacity: false)
        state = .readingBufferedBody
        if head.contentLength == 0 {
            completeBuffered()
        } else {
            refreshIdleBodyDeadline()
            initialBodyBytes.isEmpty ? receive() : appendBuffered(initialBodyBytes)
        }
    }

    private func appendBuffered(_ data: Data) {
        guard let head = bufferedHead,
              data.count <= head.contentLength - bufferedBody.count,
              bufferedBody.count + data.count <= maximumBufferedBodyBytes
        else {
            send(HTTPResponse(status: 400))
            return
        }
        bufferedBody.append(data)
        refreshIdleBodyDeadline()
        bufferedBody.count == head.contentLength ? completeBuffered() : receive()
    }

    private func completeBuffered() {
        guard let head = bufferedHead else {
            send(HTTPResponse(status: 500))
            return
        }
        state = .preparing
        cancelIdleBodyDeadline()
        let body = bufferedBody
        let task = Task { [weak self, router] in
            let response = await router.completeBuffered(head, body: body)
            guard !Task.isCancelled else { return }
            self?.queue.async { [weak self] in self?.send(response) }
        }
        routeTask = task
    }

    private func beginUpload(
        _ start: BridgeUploadStart,
        token: UUID,
        initialBodyBytes: Data
    ) {
        guard !finished else {
            Task {
                if case let .ready(upload) = start { await router.cancelUpload(upload) }
                _ = await admissionGate.releaseUpload(token)
            }
            return
        }
        switch start {
        case let .reject(response):
            Task { _ = await admissionGate.releaseUpload(token) }
            send(response)
        case let .ready(upload):
            guard initialBodyBytes.count <= upload.head.contentLength else {
                Task {
                    await router.cancelUpload(upload)
                    _ = await admissionGate.releaseUpload(token)
                }
                send(HTTPResponse(status: 400))
                return
            }
            preparedUpload = upload
            receivedUploadBytes = 0
            uploadToken = token
            state = .streamingUpload
            refreshIdleBodyDeadline()
            initialBodyBytes.isEmpty ? receive() : appendStreaming(initialBodyBytes)
        }
    }

    private func appendStreaming(_ data: Data) {
        guard let upload = preparedUpload,
              data.count <= upload.head.contentLength - receivedUploadBytes
        else {
            send(HTTPResponse(status: 400))
            return
        }
        receivedUploadBytes += data.count
        refreshIdleBodyDeadline()
        let isComplete = receivedUploadBytes == upload.head.contentLength
        if isComplete {
            cancelIdleBodyDeadline()
            state = .preparing
            let token = uploadToken
            uploadToken = nil
            preparedUpload = nil
            let task = Task { [weak self, router, admissionGate] in
                do {
                    try await upload.writer.append(data)
                    let response = await router.completeUpload(upload, receivedAt: Date())
                    if let token { _ = await admissionGate.releaseUpload(token) }
                    guard !Task.isCancelled else { return }
                    self?.queue.async { [weak self] in self?.send(response) }
                } catch {
                    await router.cancelUpload(upload)
                    if let token { _ = await admissionGate.releaseUpload(token) }
                    guard !Task.isCancelled else { return }
                    self?.queue.async { [weak self] in self?.send(HTTPResponse(status: 500)) }
                }
            }
            routeTask = task
        } else {
            let task = Task { [weak self, router] in
                do {
                    try await upload.writer.append(data)
                    guard !Task.isCancelled else { return }
                    self?.queue.async { [weak self] in self?.receive() }
                } catch {
                    await router.cancelUpload(upload)
                    guard !Task.isCancelled else { return }
                    self?.queue.async { [weak self] in self?.send(HTTPResponse(status: 500)) }
                }
            }
            routeTask = task
        }
    }

    private func refreshIdleBodyDeadline() {
        cancelIdleBodyDeadline()
        idleBodyDeadlineGeneration &+= 1
        let generation = idleBodyDeadlineGeneration
        idleBodyDeadline = scheduleDeadline(after: configuration.idleBodyTimeout) { [weak self] in
            guard let self,
                  idleBodyDeadlineGeneration == generation,
                  state == .readingBufferedBody || state == .streamingUpload
            else { return }
            send(HTTPResponse(status: 408))
        }
    }

    private func scheduleDeadline(
        after delay: TimeInterval,
        action: @escaping @Sendable () -> Void
    ) -> BridgeListenerDeadlineCancellation {
        deadlineScheduler.schedule(after: delay) { [weak self] in
            self?.queue.async(execute: action)
        }
    }

    private func send(_ response: HTTPResponse) {
        guard !finished, !responseStarted else { return }
        responseStarted = true
        state = .responding
        cancelDeadlines()
        let wireResponse = Self.serialize(
            Self.isBounded(response, configuration: configuration)
                ? response
                : HTTPResponse(status: 500, body: Data())
        )
        connection.send(
            content: wireResponse,
            contentContext: .finalMessage,
            isComplete: true,
            completion: .contentProcessed { [weak self] _ in
                self?.finish(cancelRouteTask: false)
            }
        )
    }

    private func finish(cancelRouteTask: Bool) {
        guard !finished else { return }
        finished = true
        cancelDeadlines()
        connection.cancel()
        let task = routeTask
        routeTask = nil
        if cancelRouteTask { task?.cancel() }
        let upload = preparedUpload
        preparedUpload = nil
        let token = uploadToken
        uploadToken = nil
        let cleanup = Task { [weak self, router, admissionGate, connectionToken, queue, onFinish] in
            if let upload { await router.cancelUpload(upload) }
            if let token { _ = await admissionGate.releaseUpload(token) }
            await task?.value
            _ = await admissionGate.releaseConnection(connectionToken)
            queue.async { [weak self] in
                self?.retainedUntilFinished = nil
                onFinish()
            }
        }
        cleanupTask = cleanup
    }

    func cancelForShutdown() async {
        let task = await withCheckedContinuation { continuation in
            queue.async { [self] in
                finish(cancelRouteTask: true)
                continuation.resume(returning: cleanupTask)
            }
        }
        await task?.value
    }

    private func cancelDeadlines() {
        cancelHeaderDeadline()
        cancelIdleBodyDeadline()
        totalDeadlineGeneration &+= 1
        totalDeadline?.cancel()
        totalDeadline = nil
    }

    private func cancelHeaderDeadline() {
        headerDeadlineGeneration &+= 1
        headerDeadline?.cancel()
        headerDeadline = nil
    }

    private func cancelIdleBodyDeadline() {
        idleBodyDeadlineGeneration &+= 1
        idleBodyDeadline?.cancel()
        idleBodyDeadline = nil
    }

    private static func isBounded(
        _ response: HTTPResponse,
        configuration: BridgeConfiguration
    ) -> Bool {
        response.body.count <= configuration.maximumBodyBytes
            && response.headers.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count + 4 }
                <= configuration.maximumHeaderBytes
    }

    private static func serialize(_ response: HTTPResponse) -> Data {
        var headers = response.headers.reduce(into: [String: String]()) { result, element in
            result[element.key.lowercased()] = element.value
        }
        headers["connection"] = "close"
        headers["content-length"] = String(response.body.count)
        headers["cache-control"] = "no-store"

        var head = "HTTP/1.1 \(response.status) \(reasonPhrase(for: response.status))\r\n"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            guard name.utf8.allSatisfy(Self.isHeaderNameByte),
                  value.utf8.allSatisfy({ $0 == 9 || ($0 >= 0x20 && $0 <= 0x7E) })
            else {
                continue
            }
            head += "\(name): \(value)\r\n"
        }
        head += "\r\n"
        return Data(head.utf8) + response.body
    }

    private static func isHeaderNameByte(_ byte: UInt8) -> Bool {
        (48 ... 57).contains(byte)
            || (65 ... 90).contains(byte)
            || (97 ... 122).contains(byte)
            || byte == 45
    }

    private static func reasonPhrase(for status: Int) -> String {
        switch status {
        case 200: "OK"
        case 201: "Created"
        case 204: "No Content"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 408: "Request Timeout"
        case 409: "Conflict"
        case 413: "Content Too Large"
        case 422: "Unprocessable Content"
        case 429: "Too Many Requests"
        case 503: "Service Unavailable"
        default: "Internal Server Error"
        }
    }
}
