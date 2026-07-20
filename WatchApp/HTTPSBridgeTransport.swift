import CodexBridgeShared
import CodexWatchCore
import CryptoKit
import Darwin
import Foundation
import Security

enum WatchBridgeClientError: Error, Sendable {
    case invalidPairingCode
    case certificateMismatch
    case invalidResponse
    case unavailable
}

private enum BoundedBridgeResponseError: Error {
    case responseTooLarge
}

enum WatchFileUploadLeaseError: Error, Equatable, Sendable {
    case invalidFile
    case identityDrift
}

final class ValidatedFileUploadLease: @unchecked Sendable {
    let fileURL: URL
    let contentLength: Int

    private let descriptor: Int32
    private let device: dev_t
    private let inode: ino_t
    private let owner: uid_t
    private let byteCount: off_t

    init(fileURL: URL, expectedByteCount: Int64) throws {
        guard fileURL.isFileURL,
              expectedByteCount > 0,
              expectedByteCount <= Int64(Int.max)
        else { throw WatchFileUploadLeaseError.invalidFile }

        var pathMetadata = stat()
        guard lstat(fileURL.path, &pathMetadata) == 0,
              Self.isPrivateRegularFile(pathMetadata, expectedByteCount: expectedByteCount)
        else { throw WatchFileUploadLeaseError.invalidFile }

        let openedDescriptor = Darwin.open(fileURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard openedDescriptor >= 0 else { throw WatchFileUploadLeaseError.invalidFile }
        var openedMetadata = stat()
        guard fstat(openedDescriptor, &openedMetadata) == 0,
              Self.isPrivateRegularFile(openedMetadata, expectedByteCount: expectedByteCount),
              openedMetadata.st_dev == pathMetadata.st_dev,
              openedMetadata.st_ino == pathMetadata.st_ino
        else {
            Darwin.close(openedDescriptor)
            throw WatchFileUploadLeaseError.invalidFile
        }

        self.fileURL = fileURL
        contentLength = Int(expectedByteCount)
        descriptor = openedDescriptor
        device = openedMetadata.st_dev
        inode = openedMetadata.st_ino
        owner = openedMetadata.st_uid
        byteCount = openedMetadata.st_size
    }

    deinit {
        Darwin.close(descriptor)
    }

    func withRevalidatedFileURL<T>(_ operation: (URL) throws -> T) throws -> T {
        var leasedMetadata = stat()
        guard fstat(descriptor, &leasedMetadata) == 0,
              matchesLease(leasedMetadata)
        else { throw WatchFileUploadLeaseError.identityDrift }

        var pathMetadata = stat()
        guard lstat(fileURL.path, &pathMetadata) == 0,
              matchesLease(pathMetadata)
        else { throw WatchFileUploadLeaseError.identityDrift }

        let verificationDescriptor = Darwin.open(
            fileURL.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard verificationDescriptor >= 0 else { throw WatchFileUploadLeaseError.identityDrift }
        defer { Darwin.close(verificationDescriptor) }
        var verificationMetadata = stat()
        guard fstat(verificationDescriptor, &verificationMetadata) == 0,
              matchesLease(verificationMetadata)
        else { throw WatchFileUploadLeaseError.identityDrift }

        // The Watch store rejects cooperative app-local deletion while a memo is uploading.
        // The retained descriptor pins the validated inode through task completion, and the
        // path is revalidated at task creation. Namespace mutation outside the cooperative
        // app-local boundary cannot be prevented by a POSIX descriptor.
        return try operation(fileURL)
    }

    private func matchesLease(_ metadata: stat) -> Bool {
        (metadata.st_mode & S_IFMT) == S_IFREG
            && metadata.st_uid == owner
            && metadata.st_nlink == 1
            && metadata.st_mode & 0o777 == 0o600
            && metadata.st_size == byteCount
            && metadata.st_dev == device
            && metadata.st_ino == inode
    }

    private static func isPrivateRegularFile(
        _ metadata: stat,
        expectedByteCount: Int64
    ) -> Bool {
        (metadata.st_mode & S_IFMT) == S_IFREG
            && metadata.st_uid == geteuid()
            && metadata.st_nlink == 1
            && metadata.st_mode & 0o777 == 0o600
            && metadata.st_size == expectedByteCount
    }
}

actor HTTPSBridgeTransport: WatchBridgeTransport {
    private let credentialStore: any WatchBridgeCredentialStore
    private let fileUploader: any WatchFileUploadPerforming

    init(
        credentialStore: any WatchBridgeCredentialStore,
        fileUploader: (any WatchFileUploadPerforming)? = nil
    ) {
        self.credentialStore = credentialStore
        self.fileUploader = fileUploader ?? URLSessionWatchFileUploader(
            configuration: Self.sessionConfiguration
        )
    }

    func upload(
        memo: VoiceMemoMetadata,
        audioURL: URL,
        expectedRevision: UInt64
    ) async throws -> BridgeReceipt {
        guard let credential = try await credentialStore.load() else {
            throw WatchBridgeTransportFailure.authentication
        }

        let lease: ValidatedFileUploadLease
        do {
            lease = try ValidatedFileUploadLease(
                fileURL: audioURL,
                expectedByteCount: memo.byteCount
            )
        } catch {
            throw WatchBridgeTransportFailure.permanent
        }

        let signed: SignedBridgeUploadRequest
        do {
            signed = try BridgeUploadRequestBuilder.make(
                memo: memo,
                contentLength: lease.contentLength,
                token: credential.token,
                timestamp: Int64(Date().timeIntervalSince1970),
                nonce: UUID().uuidString.lowercased()
            )
        } catch {
            throw WatchBridgeTransportFailure.permanent
        }

        guard expectedRevision == memo.stateRevision + 1,
              let url = Self.endpoint(baseURL: credential.baseURL, path: signed.path)
        else {
            throw WatchBridgeTransportFailure.permanent
        }

        var request = URLRequest(url: url)
        request.httpMethod = signed.method
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        for (name, value) in signed.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }

        do {
            let (responseBody, response) = try await fileUploader.upload(
                request: request,
                lease: lease,
                expectedPin: credential.certificatePin,
                maximumResponseBytes: 64 * 1_024
            )
            guard let response = response as? HTTPURLResponse else {
                throw WatchBridgeTransportFailure.transient
            }
            return try BridgeUploadResponseDecoder.receipt(
                statusCode: response.statusCode,
                body: responseBody
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as WatchBridgeTransportFailure {
            if failure == .authentication {
                try? await credentialStore.remove()
            }
            throw failure
        } catch {
            throw WatchBridgeTransportFailure.transient
        }
    }

    func recoverAbsentStatus(memo: VoiceMemoMetadata, audioURL: URL) async throws {
        guard let credential = try await credentialStore.load() else {
            throw WatchBridgeTransportFailure.authentication
        }
        let lease: ValidatedFileUploadLease
        do {
            lease = try ValidatedFileUploadLease(
                fileURL: audioURL,
                expectedByteCount: memo.byteCount
            )
        } catch {
            throw WatchBridgeTransportFailure.permanent
        }
        let signed: SignedBridgeUploadRequest
        do {
            signed = try BridgeRecoveryUploadRequestBuilder.make(
                memo: memo,
                contentLength: lease.contentLength,
                token: credential.token,
                timestamp: Int64(Date().timeIntervalSince1970),
                nonce: UUID().uuidString.lowercased()
            )
        } catch {
            throw WatchBridgeTransportFailure.permanent
        }
        guard let url = Self.endpoint(baseURL: credential.baseURL, path: signed.path) else {
            throw WatchBridgeTransportFailure.permanent
        }
        var request = URLRequest(url: url)
        request.httpMethod = signed.method
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        for (name, value) in signed.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        do {
            let (responseBody, response) = try await fileUploader.upload(
                request: request,
                lease: lease,
                expectedPin: credential.certificatePin,
                maximumResponseBytes: 64 * 1_024
            )
            guard let response = response as? HTTPURLResponse else {
                throw WatchBridgeTransportFailure.transient
            }
            let receipt = try BridgeUploadResponseDecoder.receipt(
                statusCode: response.statusCode,
                body: responseBody
            )
            guard receipt.memoID == memo.memoID,
                  receipt.audioSHA256 == memo.audioSHA256.lowercased(),
                  receipt.capturedAt == memo.capturedAt,
                  receipt.localeHint == memo.localeHint,
                  receipt.acknowledgedRevision == memo.stateRevision
            else { throw WatchBridgeTransportFailure.permanent }
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as WatchBridgeTransportFailure {
            if failure == .authentication {
                try? await credentialStore.remove()
            }
            throw failure
        } catch {
            throw WatchBridgeTransportFailure.transient
        }
    }

    func status(for memo: VoiceMemoMetadata) async throws -> BridgeMemoStatus {
        guard let credential = try await credentialStore.load() else {
            throw WatchBridgeTransportFailure.authentication
        }
        let signed: SignedBridgeStatusRequest
        do {
            signed = try BridgeStatusRequestBuilder.make(
                memo: memo,
                token: credential.token,
                timestamp: Int64(Date().timeIntervalSince1970),
                nonce: UUID().uuidString.lowercased()
            )
        } catch {
            throw WatchBridgeTransportFailure.permanent
        }
        guard let url = Self.endpoint(baseURL: credential.baseURL, path: signed.path) else {
            throw WatchBridgeTransportFailure.permanent
        }
        var request = URLRequest(url: url)
        request.httpMethod = signed.method
        request.httpBody = nil
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        for (name, value) in signed.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }

        let delegate = PinnedBridgeSessionDelegate(expectedPin: credential.certificatePin)
        let session = URLSession(configuration: Self.sessionConfiguration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (responseBody, response) = try await Self.boundedResponse(
                session: session,
                request: request,
                maximumBytes: 64 * 1_024
            )
            guard let response = response as? HTTPURLResponse else {
                throw WatchBridgeTransportFailure.transient
            }
            return try BridgeStatusResponseDecoder.status(
                statusCode: response.statusCode,
                body: responseBody
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as WatchBridgeTransportFailure {
            if failure == .authentication {
                try? await credentialStore.remove()
            }
            throw failure
        } catch {
            if delegate.rejectedCertificate {
                try? await credentialStore.remove()
                throw WatchBridgeTransportFailure.authentication
            }
            throw WatchBridgeTransportFailure.transient
        }
    }

    func acknowledgeDelivery(_ acknowledgement: FinalDeliveryAcknowledgement) async throws {
        guard let credential = try await credentialStore.load() else {
            throw WatchBridgeTransportFailure.authentication
        }
        let signed: SignedBridgeFinalAcknowledgementRequest
        do {
            signed = try BridgeFinalAcknowledgementRequestBuilder.make(
                acknowledgement: acknowledgement,
                token: credential.token,
                timestamp: Int64(Date().timeIntervalSince1970),
                nonce: UUID().uuidString.lowercased()
            )
        } catch {
            throw WatchBridgeTransportFailure.permanent
        }
        guard let url = Self.endpoint(baseURL: credential.baseURL, path: signed.path) else {
            throw WatchBridgeTransportFailure.permanent
        }
        var request = URLRequest(url: url)
        request.httpMethod = signed.method
        request.httpBody = nil
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        for (name, value) in signed.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }

        let delegate = PinnedBridgeSessionDelegate(expectedPin: credential.certificatePin)
        let session = URLSession(configuration: Self.sessionConfiguration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (responseBody, response) = try await Self.boundedResponse(
                session: session,
                request: request,
                maximumBytes: 4_096
            )
            guard let response = response as? HTTPURLResponse else {
                throw WatchBridgeTransportFailure.transient
            }
            _ = try BridgeFinalAcknowledgementResponseDecoder.acknowledged(
                statusCode: response.statusCode,
                body: responseBody
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as WatchBridgeTransportFailure {
            if failure == .authentication {
                try? await credentialStore.remove()
            }
            throw failure
        } catch {
            if delegate.rejectedCertificate {
                try? await credentialStore.remove()
                throw WatchBridgeTransportFailure.authentication
            }
            throw WatchBridgeTransportFailure.transient
        }
    }

    fileprivate static var sessionConfiguration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return configuration
    }

    fileprivate static func endpoint(baseURL: URL, path: String) -> URL? {
        guard path.hasPrefix("/"), !path.contains("//") else { return nil }
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.path = path
        return components?.url
    }

    fileprivate static func boundedResponse(
        session: URLSession,
        request: URLRequest,
        maximumBytes: Int
    ) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        guard maximumBytes > 0,
              response.expectedContentLength < 0
                || response.expectedContentLength <= Int64(maximumBytes)
        else { throw BoundedBridgeResponseError.responseTooLarge }
        var body = Data()
        body.reserveCapacity(min(maximumBytes, max(0, Int(response.expectedContentLength))))
        for try await byte in bytes {
            guard body.count < maximumBytes else {
                throw BoundedBridgeResponseError.responseTooLarge
            }
            body.append(byte)
        }
        return (body, response)
    }
}

protocol WatchFileUploadPerforming: Sendable {
    func upload(
        request: URLRequest,
        lease: ValidatedFileUploadLease,
        expectedPin: CertificatePin,
        maximumResponseBytes: Int
    ) async throws -> (Data, URLResponse)
}

protocol URLSessionUploadTaskCreating: Sendable {
    func makeUploadTask(
        session: URLSession,
        request: URLRequest,
        fileURL: URL
    ) throws -> URLSessionUploadTask
}

private struct FoundationURLSessionUploadTaskFactory: URLSessionUploadTaskCreating {
    func makeUploadTask(
        session: URLSession,
        request: URLRequest,
        fileURL: URL
    ) throws -> URLSessionUploadTask {
        session.uploadTask(with: request, fromFile: fileURL)
    }
}

struct URLSessionWatchFileUploader: WatchFileUploadPerforming, @unchecked Sendable {
    let configuration: URLSessionConfiguration
    let taskFactory: any URLSessionUploadTaskCreating

    init(
        configuration: URLSessionConfiguration,
        taskFactory: any URLSessionUploadTaskCreating = FoundationURLSessionUploadTaskFactory()
    ) {
        self.configuration = configuration
        self.taskFactory = taskFactory
    }

    func upload(
        request: URLRequest,
        lease: ValidatedFileUploadLease,
        expectedPin: CertificatePin,
        maximumResponseBytes: Int
    ) async throws -> (Data, URLResponse) {
        defer { withExtendedLifetime(lease) {} }
        let delegate = PinnedBridgeSessionDelegate(expectedPin: expectedPin)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        do {
            let task = try lease.withRevalidatedFileURL { fileURL in
                try taskFactory.makeUploadTask(
                    session: session,
                    request: request,
                    fileURL: fileURL
                )
            }
            return try await delegate.response(for: task, maximumBytes: maximumResponseBytes)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if delegate.rejectedCertificate {
                throw WatchBridgeTransportFailure.authentication
            }
            throw error
        }
    }
}

actor BridgePairingClient {
    private struct PairingRequest: Encodable {
        let code: String
    }

    private struct PairingResponse: Decodable {
        let token: String
    }

    private let credentialStore: any WatchBridgeCredentialStore

    init(credentialStore: any WatchBridgeCredentialStore) {
        self.credentialStore = credentialStore
    }

    func pair(
        bridge: DiscoveredBridge,
        confirmedPin: ConfirmedCertificatePin,
        code: String
    ) async throws -> WatchBridgeCredential {
        guard let pairingCode = PairingCode(rawValue: code) else {
            throw WatchBridgeClientError.invalidPairingCode
        }
        guard CertificatePinTrust.evaluate(
            candidate: bridge.certificatePin,
            confirmed: confirmedPin
        ) == .accept else {
            throw WatchBridgeClientError.certificateMismatch
        }
        guard let url = HTTPSBridgeTransport.endpoint(baseURL: bridge.baseURL, path: "/v1/pair") else {
            throw WatchBridgeClientError.unavailable
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(PairingRequest(code: pairingCode.rawValue))
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(String(request.httpBody?.count ?? 0), forHTTPHeaderField: "content-length")
        request.setValue(String(BridgeProtocolVersion.current.major), forHTTPHeaderField: "x-codex-version")
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let delegate = PinnedBridgeSessionDelegate(expectedPin: confirmedPin.pin)
        let session = URLSession(
            configuration: HTTPSBridgeTransport.sessionConfiguration,
            delegate: delegate,
            delegateQueue: nil
        )
        defer { session.finishTasksAndInvalidate() }

        do {
            let (body, response) = try await HTTPSBridgeTransport.boundedResponse(
                session: session,
                request: request,
                maximumBytes: 4_096
            )
            guard let response = response as? HTTPURLResponse,
                  response.statusCode == 200,
                  let pairing = try? JSONDecoder().decode(PairingResponse.self, from: body)
            else {
                throw WatchBridgeClientError.invalidResponse
            }
            let credential = try WatchBridgeCredential(
                bridgeName: bridge.name,
                baseURL: bridge.baseURL,
                certificatePin: confirmedPin.pin,
                tokenHex: pairing.token
            )
            try await credentialStore.save(credential)
            return credential
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as WatchBridgeClientError {
            throw error
        } catch {
            if delegate.rejectedCertificate {
                throw WatchBridgeClientError.certificateMismatch
            }
            throw WatchBridgeClientError.unavailable
        }
    }
}

protocol BridgeUploadTask: Sendable {
    var taskIdentifier: Int { get }
    func resume()
    func cancel()
}

struct BridgeUploadStartBoundary: Sendable {
    private let operation: @Sendable () -> Void

    init(_ operation: @escaping @Sendable () -> Void = {}) {
        self.operation = operation
    }

    func arrive() {
        operation()
    }
}

private final class URLSessionBridgeUploadTask: BridgeUploadTask, @unchecked Sendable {
    private let task: URLSessionUploadTask

    init(_ task: URLSessionUploadTask) {
        self.task = task
    }

    var taskIdentifier: Int { task.taskIdentifier }
    func resume() { task.resume() }
    func cancel() { task.cancel() }
}

final class BoundedUploadResponseCollector: @unchecked Sendable {
    private enum Lifecycle: Equatable {
        case registered
        case started
    }

    private struct ResponseState {
        let taskIdentifier: Int
        let maximumBytes: Int
        let task: any BridgeUploadTask
        let continuation: CheckedContinuation<(Data, URLResponse), any Error>
        var lifecycle: Lifecycle
        var response: URLResponse?
        var body = Data()
    }

    private let lock = NSLock()
    private let startBoundary: BridgeUploadStartBoundary
    private var responseState: ResponseState?

    init(startBoundary: BridgeUploadStartBoundary = BridgeUploadStartBoundary()) {
        self.startBoundary = startBoundary
    }

    func response(
        for task: any BridgeUploadTask,
        maximumBytes: Int
    ) async throws -> (Data, URLResponse) {
        guard maximumBytes > 0 else { throw BoundedBridgeResponseError.responseTooLarge }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let registered = lock.withLock { () -> Bool in
                    guard responseState == nil else { return false }
                    responseState = ResponseState(
                        taskIdentifier: task.taskIdentifier,
                        maximumBytes: maximumBytes,
                        task: task,
                        continuation: continuation,
                        lifecycle: .registered
                    )
                    return true
                }
                guard registered else {
                    continuation.resume(throwing: WatchBridgeTransportFailure.transient)
                    return
                }
                guard !Task.isCancelled else {
                    self.cancelResponse(taskIdentifier: task.taskIdentifier)
                    return
                }
                startBoundary.arrive()
                self.startResponse(taskIdentifier: task.taskIdentifier)
            }
        } onCancel: {
            self.cancelResponse(taskIdentifier: task.taskIdentifier)
        }
    }

    private func startResponse(taskIdentifier: Int) {
        lock.withLock {
            guard var state = responseState,
                  state.taskIdentifier == taskIdentifier,
                  state.lifecycle == .registered
            else { return }
            state.lifecycle = .started
            responseState = state
            state.task.resume()
        }
    }

    private func cancelResponse(taskIdentifier: Int) {
        let cancelled = lock.withLock { () -> (
            task: any BridgeUploadTask,
            continuation: CheckedContinuation<(Data, URLResponse), any Error>
        )? in
            guard let state = responseState,
                  state.taskIdentifier == taskIdentifier
            else { return nil }
            responseState = nil
            return (state.task, state.continuation)
        }
        cancelled?.task.cancel()
        cancelled?.continuation.resume(throwing: CancellationError())
    }

    @discardableResult
    func receive(response: URLResponse, taskIdentifier: Int) -> Bool {
        let rejectedTask = lock.withLock { () -> (any BridgeUploadTask)? in
            guard var state = responseState,
                  state.taskIdentifier == taskIdentifier
            else { return nil }
            guard response.expectedContentLength < 0
                    || response.expectedContentLength <= Int64(state.maximumBytes)
            else { return state.task }
            state.response = response
            responseState = state
            return nil
        }
        if let rejectedTask {
            rejectedTask.cancel()
            finishResponse(
                taskIdentifier: taskIdentifier,
                result: .failure(BoundedBridgeResponseError.responseTooLarge)
            )
            return false
        }
        return lock.withLock {
            responseState?.taskIdentifier == taskIdentifier
                && responseState?.response != nil
        }
    }

    func receive(data: Data, taskIdentifier: Int) {
        let overflowTask = lock.withLock { () -> (any BridgeUploadTask)? in
            guard var state = responseState,
                  state.taskIdentifier == taskIdentifier
            else { return nil }
            guard data.count <= state.maximumBytes - state.body.count else {
                return state.task
            }
            state.body.append(data)
            responseState = state
            return nil
        }
        if let overflowTask {
            overflowTask.cancel()
            finishResponse(
                taskIdentifier: taskIdentifier,
                result: .failure(BoundedBridgeResponseError.responseTooLarge)
            )
        }
    }

    func complete(taskIdentifier: Int, error: (any Error)?) {
        if let error {
            finishResponse(taskIdentifier: taskIdentifier, result: .failure(error))
            return
        }
        let result = lock.withLock { () -> Result<(Data, URLResponse), any Error>? in
            guard let state = responseState,
                  state.taskIdentifier == taskIdentifier
            else { return nil }
            guard let response = state.response else {
                return .failure(WatchBridgeTransportFailure.transient)
            }
            return .success((state.body, response))
        }
        if let result { finishResponse(taskIdentifier: taskIdentifier, result: result) }
    }

    private func finishResponse(
        taskIdentifier: Int,
        result: Result<(Data, URLResponse), any Error>
    ) {
        let continuation = lock.withLock { () -> CheckedContinuation<(Data, URLResponse), any Error>? in
            guard let state = responseState,
                  state.taskIdentifier == taskIdentifier
            else { return nil }
            responseState = nil
            return state.continuation
        }
        continuation?.resume(with: result)
    }
}

final class PinnedBridgeSessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let expectedPin: CertificatePin
    private let lock = NSLock()
    private let responseCollector = BoundedUploadResponseCollector()
    private var didRejectCertificate = false

    init(expectedPin: CertificatePin) {
        self.expectedPin = expectedPin
    }

    var rejectedCertificate: Bool {
        lock.withLock { didRejectCertificate }
    }

    func response(
        for task: URLSessionUploadTask,
        maximumBytes: Int
    ) async throws -> (Data, URLResponse) {
        try await responseCollector.response(
            for: URLSessionBridgeUploadTask(task),
            maximumBytes: maximumBytes
        )
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first,
              let key = SecCertificateCopyKey(leaf),
              let representation = SecKeyCopyExternalRepresentation(key, nil) as Data?,
              let actualPin = try? CertificatePin(Self.digest(representation)),
              actualPin == expectedPin,
              SecTrustSetAnchorCertificates(trust, [leaf] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
              SecTrustEvaluateWithError(trust, nil)
        else {
            lock.withLock { didRejectCertificate = true }
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        urlSession(session, didReceive: challenge, completionHandler: completionHandler)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        let accepted = responseCollector.receive(
            response: response,
            taskIdentifier: dataTask.taskIdentifier
        )
        guard accepted else {
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        responseCollector.receive(data: data, taskIdentifier: dataTask.taskIdentifier)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        responseCollector.complete(taskIdentifier: task.taskIdentifier, error: error)
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
