import CodexBridgeShared
import CodexBridgeDelivery
import CryptoKit
import Foundation

public struct HTTPResponse: Equatable, Sendable {
    public let status: Int
    public let headers: [String: String]
    public let body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

public struct PairingRedemptionRequest: Codable, Equatable, Sendable {
    public let code: String

    public init(code: String) {
        self.code = code
    }
}

public struct PairingRedemptionResponse: Codable, Equatable, Sendable {
    public let token: String

    public init(token: String) {
        self.token = token
    }
}

public enum PreparedBridgeRequest: Sendable {
    case reject(HTTPResponse)
    case buffered(head: HTTPRequestHead, maximumBodyBytes: Int)
    case upload(AuthenticatedBridgeUpload)
}

public struct AuthenticatedBridgeUpload: Sendable {
    public let head: HTTPRequestHead
    public let intakeRequest: IntakeRequest

    init(head: HTTPRequestHead, intakeRequest: IntakeRequest) {
        self.head = head
        self.intakeRequest = intakeRequest
    }
}

public struct PreparedBridgeUpload: Sendable {
    public let head: HTTPRequestHead
    public let writer: StreamingIntakeWriter
    let capacityReservation: FinalDeliveryCapacityReservationLease?

    init(
        head: HTTPRequestHead,
        writer: StreamingIntakeWriter,
        capacityReservation: FinalDeliveryCapacityReservationLease?
    ) {
        self.head = head
        self.writer = writer
        self.capacityReservation = capacityReservation
    }
}

public enum BridgeUploadStart: Sendable {
    case ready(PreparedBridgeUpload)
    case reject(HTTPResponse)
}

private struct SlidingWindowRequestLimiter: Sendable {
    let maximumRequests: Int
    let window: TimeInterval
    private(set) var acceptedAt: [Date] = []

    mutating func consume(at now: Date) -> Bool {
        guard now.timeIntervalSinceReferenceDate.isFinite else { return false }
        let cutoff = now.addingTimeInterval(-window)
        acceptedAt.removeAll { $0 <= cutoff }
        guard acceptedAt.count < maximumRequests else { return false }
        acceptedAt.append(now)
        return true
    }
}

public actor BridgeRequestRouter {
    private let pairingStore: PairingStore
    private let intakeStore: IntakeStore
    private let deliveryJournal: DeliveryJournal?
    private let finalStatusStore: FinalDeliveryStatusStore?
    private let verifier: AuthenticatedRequestVerifier
    private let onCommitted: (@Sendable (CommittedIntakeRecord) async -> Void)?
    private let minimumAvailableBytes: Int64
    private let availableBytes: @Sendable () -> Int64
    private let clock: @Sendable () -> Date
    private let rateLimitRetryAfterSeconds: Int
    private var pairingRateLimiter: SlidingWindowRequestLimiter
    private var uploadRateLimiter: SlidingWindowRequestLimiter

    public init(
        pairingStore: PairingStore,
        intakeStore: IntakeStore,
        deliveryJournal: DeliveryJournal? = nil,
        finalStatusStore: FinalDeliveryStatusStore? = nil,
        allowedClockSkew: TimeInterval,
        replayRetention: TimeInterval,
        clock: @escaping @Sendable () -> Date = Date.init,
        replayStore: any ReplayNonceStore,
        onCommitted: (@Sendable (CommittedIntakeRecord) async -> Void)? = nil,
        minimumAvailableBytes: Int64 = 0,
        availableBytes: @escaping @Sendable () -> Int64 = { Int64.max },
        pairingAttemptLimit: Int = 5,
        uploadRequestLimit: Int = 120,
        rateLimitWindow: TimeInterval = 60
    ) throws {
        guard minimumAvailableBytes >= 0,
              (1 ... 10_000).contains(pairingAttemptLimit),
              (1 ... 10_000).contains(uploadRequestLimit),
              rateLimitWindow.isFinite,
              rateLimitWindow > 0,
              rateLimitWindow <= 3_600
        else { throw BridgeSupervisorError.invalidConfiguration }
        self.pairingStore = pairingStore
        self.intakeStore = intakeStore
        self.deliveryJournal = deliveryJournal
        self.finalStatusStore = finalStatusStore
        verifier = try AuthenticatedRequestVerifier(
            allowedClockSkew: allowedClockSkew,
            replayRetention: replayRetention,
            clock: clock,
            replayStore: replayStore
        )
        self.onCommitted = onCommitted
        self.minimumAvailableBytes = minimumAvailableBytes
        self.availableBytes = availableBytes
        self.clock = clock
        rateLimitRetryAfterSeconds = max(1, Int(ceil(rateLimitWindow)))
        pairingRateLimiter = SlidingWindowRequestLimiter(
            maximumRequests: pairingAttemptLimit,
            window: rateLimitWindow
        )
        uploadRateLimiter = SlidingWindowRequestLimiter(
            maximumRequests: uploadRequestLimit,
            window: rateLimitWindow
        )
    }

    public func prepare(_ head: HTTPRequestHead) async -> PreparedBridgeRequest {
        if head.path == "/v1/pair" {
            guard head.method == "POST",
                  head.headers["content-type"] == "application/json",
                  head.headers["x-codex-version"] == String(BridgeProtocolVersion.current.major),
                  head.contentLength <= 4 * 1_024
            else { return .reject(Self.error(status: 400, code: "invalid_request")) }
            return .buffered(head: head, maximumBodyBytes: 4 * 1_024)
        }

        if head.method == "GET", head.path.hasSuffix("/status") {
            guard head.contentLength == 0 else {
                return .reject(Self.error(status: 400, code: "invalid_request"))
            }
            return .buffered(head: head, maximumBodyBytes: 0)
        }

        if head.method == "POST", head.path.hasSuffix("/final-ack") {
            guard head.contentLength == 0 else {
                return .reject(Self.error(status: 400, code: "invalid_request"))
            }
            return .buffered(head: head, maximumBodyBytes: 0)
        }

        guard head.method == "POST",
              head.headers["x-codex-version"] == String(BridgeProtocolVersion.current.major),
              head.headers["content-type"] == "audio/mp4",
              let rawMemoID = head.headers["x-codex-memo-id"],
              let memoID = try? MemoID(rawMemoID),
              head.path == "/v1/memos/\(memoID.rawValue)",
              head.contentLength > 0,
              head.contentLength <= BridgeConfiguration.defaultMaximumBodyBytes,
              let digest = head.headers["x-codex-body-sha256"],
              AudioDigest.isValidHex(digest),
              let rawRevision = head.headers["x-codex-revision"],
              let revision = UInt64(rawRevision),
              let rawCapturedAt = head.headers["x-codex-captured-at"],
              let capturedAtBits = UInt64(rawCapturedAt, radix: 16),
              Double(bitPattern: capturedAtBits).isFinite,
              let rawTimestamp = head.headers["x-codex-timestamp"],
              let timestamp = Int64(rawTimestamp),
              let nonce = head.headers["x-codex-nonce"],
              let signature = head.headers["x-codex-signature"]
        else { return .reject(Self.error(status: 400, code: "invalid_request")) }

        guard let authorization = head.headers["authorization"],
              authorization.hasPrefix("Bearer "),
              authorization.dropFirst(7).count == 64,
              let secret = try? await pairingStore.secret(
                  matchingBearerToken: String(authorization.dropFirst(7))
              )
        else { return .reject(Self.error(status: 401, code: "unauthorized")) }

        guard uploadRateLimiter.consume(at: clock()) else {
            return .reject(rateLimited(code: "rate_limited"))
        }

        do {
            let canonical = try CanonicalBridgeRequest(
                method: head.method,
                path: head.path,
                timestamp: timestamp,
                nonce: nonce,
                memoID: memoID,
                bodySHA256: digest,
                revision: revision,
                capturedAtBits: capturedAtBits,
                localeHint: head.headers["x-codex-locale"]
            )
            try await verifier.verify(
                signatureHex: signature,
                request: canonical,
                key: SymmetricKey(data: secret)
            )
        } catch RequestAuthenticationError.replayStoreUnavailable {
            return .reject(Self.error(status: 503, code: "auth_unavailable"))
        } catch {
            return .reject(Self.error(status: 401, code: "unauthorized"))
        }

        guard availableBytes() >= minimumAvailableBytes else {
            return .reject(Self.error(status: 503, code: "disk_pressure"))
        }

        do {
            let intakeRequest = try IntakeRequest(
                memoID: memoID,
                audioSHA256: digest,
                byteCount: head.contentLength,
                revision: revision,
                capturedAt: Date(timeIntervalSinceReferenceDate: Double(bitPattern: capturedAtBits)),
                localeHint: head.headers["x-codex-locale"]
            )
            return .upload(AuthenticatedBridgeUpload(head: head, intakeRequest: intakeRequest))
        } catch {
            return .reject(Self.error(status: 400, code: "invalid_request"))
        }
    }

    public func beginUpload(_ upload: AuthenticatedBridgeUpload) async -> BridgeUploadStart {
        let reservation: FinalDeliveryCapacityReservationLease?
        do {
            reservation = try await finalStatusStore?.reserveCapacity(
                memoID: upload.intakeRequest.memoID,
                audioSHA256: upload.intakeRequest.audioSHA256
            )
        } catch FinalDeliveryStatusStoreError.capacityExceeded {
            return .reject(Self.error(status: 503, code: "terminal_capacity"))
        } catch FinalDeliveryStatusStoreError.identityConflict {
            return .reject(Self.error(status: 409, code: "identity_conflict"))
        } catch {
            return .reject(Self.error(status: 500, code: "status_unavailable"))
        }
        do {
            return .ready(PreparedBridgeUpload(
                head: upload.head,
                writer: try await intakeStore.beginStreamingCommit(request: upload.intakeRequest),
                capacityReservation: reservation
            ))
        } catch IntakeStoreError.identityConflict {
            if let reservation {
                try? await finalStatusStore?.cancelCapacityReservation(reservation)
            }
            return .reject(Self.error(status: 409, code: "identity_conflict"))
        } catch {
            if let reservation {
                try? await finalStatusStore?.cancelCapacityReservation(reservation)
            }
            return .reject(Self.error(status: 500, code: "intake_unavailable"))
        }
    }

    public func cancelUpload(_ upload: PreparedBridgeUpload) async {
        await upload.writer.cancel()
        if let reservation = upload.capacityReservation {
            try? await finalStatusStore?.cancelCapacityReservation(reservation)
        }
    }

    public func completeBuffered(_ head: HTTPRequestHead, body: Data) async -> HTTPResponse {
        guard body.count == head.contentLength else {
            return Self.error(status: 400, code: "invalid_request")
        }
        return await routeLegacy(HTTPRequest(
            method: head.method,
            path: head.path,
            headers: head.headers,
            body: body
        ))
    }

    public func completeUpload(_ upload: PreparedBridgeUpload, receivedAt: Date) async -> HTTPResponse {
        do {
            let result = try await upload.writer.finish(receivedAt: receivedAt)
            if let reservation = upload.capacityReservation {
                do {
                    try await finalStatusStore?.commitCapacityReservation(reservation)
                } catch {
                    // Intake is already durable. Preserve its slot for startup
                    // reconciliation, arrange owned processing, and return a
                    // retryable response.
                    try? await scheduleCommittedIntake(memoID: result.receipt.memoID)
                    return Self.error(status: 500, code: "status_unavailable")
                }
            }
            return await response(for: result)
        } catch IntakeStoreError.identityConflict {
            await cancelUpload(upload)
            return Self.error(status: 409, code: "identity_conflict")
        } catch IntakeStoreError.lengthMismatch {
            await cancelUpload(upload)
            return Self.error(status: 422, code: "length_mismatch")
        } catch IntakeStoreError.digestMismatch {
            await cancelUpload(upload)
            return Self.error(status: 422, code: "digest_mismatch")
        } catch {
            await cancelUpload(upload)
            return Self.error(status: 500, code: "intake_unavailable")
        }
    }

    public func route(_ request: HTTPRequest) async -> HTTPResponse {
        guard let contentLength = Int(request.headers["content-length"] ?? ""),
              contentLength == request.body.count
        else { return Self.error(status: 400, code: "invalid_request") }
        let head = HTTPRequestHead(
            method: request.method,
            path: request.path,
            headers: request.headers,
            contentLength: contentLength
        )
        switch await prepare(head) {
        case let .reject(response):
            return response
        case let .buffered(bufferedHead, maximumBodyBytes):
            guard request.body.count <= maximumBodyBytes else {
                return Self.error(status: 413, code: "request_too_large")
            }
            return await completeBuffered(bufferedHead, body: request.body)
        case let .upload(authenticated):
            switch await beginUpload(authenticated) {
            case let .reject(response):
                return response
            case let .ready(upload):
                do {
                    try await upload.writer.append(request.body)
                } catch IntakeStoreError.lengthMismatch {
                    await cancelUpload(upload)
                    return Self.error(status: 422, code: "length_mismatch")
                } catch {
                    await cancelUpload(upload)
                    return Self.error(status: 500, code: "intake_unavailable")
                }
                return await completeUpload(upload, receivedAt: clock())
            }
        }
    }

    private func routeLegacy(_ request: HTTPRequest) async -> HTTPResponse {
        if request.path == "/v1/pair" {
            return await redeemPairing(request)
        }

        if request.method == "GET", request.path.hasSuffix("/status") {
            return await memoStatus(request)
        }

        if request.method == "POST", request.path.hasSuffix("/final-ack") {
            return await finalAcknowledgement(request)
        }

        guard request.method == "POST",
              request.headers["x-codex-version"] == String(BridgeProtocolVersion.current.major),
              request.headers["content-type"] == "audio/mp4",
              let rawMemoID = request.headers["x-codex-memo-id"],
              let memoID = try? MemoID(rawMemoID),
              request.path == "/v1/memos/\(memoID.rawValue)",
              let rawLength = request.headers["content-length"],
              let contentLength = Int(rawLength),
              contentLength == request.body.count,
              let digest = request.headers["x-codex-body-sha256"],
              let rawRevision = request.headers["x-codex-revision"],
              let revision = UInt64(rawRevision),
              let rawCapturedAt = request.headers["x-codex-captured-at"],
              let capturedAtBits = UInt64(rawCapturedAt, radix: 16),
              Double(bitPattern: capturedAtBits).isFinite,
              let rawTimestamp = request.headers["x-codex-timestamp"],
              let timestamp = Int64(rawTimestamp),
              let nonce = request.headers["x-codex-nonce"],
              let signature = request.headers["x-codex-signature"]
        else {
            return Self.error(status: 400, code: "invalid_request")
        }

        guard let authorization = request.headers["authorization"],
              authorization.hasPrefix("Bearer "),
              authorization.dropFirst(7).count == 64,
              let secret = try? await pairingStore.secret(
                  matchingBearerToken: String(authorization.dropFirst(7))
              )
        else {
            return Self.error(status: 401, code: "unauthorized")
        }

        guard uploadRateLimiter.consume(at: clock()) else {
            return rateLimited(code: "rate_limited")
        }

        guard AudioDigest.isValidHex(digest), AudioDigest.hex(request.body) == digest.lowercased() else {
            return Self.error(status: 422, code: "digest_mismatch")
        }

        do {
            let canonical = try CanonicalBridgeRequest(
                method: request.method,
                path: request.path,
                timestamp: timestamp,
                nonce: nonce,
                memoID: memoID,
                bodySHA256: digest,
                revision: revision,
                capturedAtBits: capturedAtBits,
                localeHint: request.headers["x-codex-locale"]
            )
            try await verifier.verify(
                signatureHex: signature,
                request: canonical,
                key: SymmetricKey(data: secret)
            )
        } catch RequestAuthenticationError.replayStoreUnavailable {
            return Self.error(status: 503, code: "auth_unavailable")
        } catch {
            return Self.error(status: 401, code: "unauthorized")
        }

        do {
            guard availableBytes() >= minimumAvailableBytes else {
                return Self.error(status: 503, code: "disk_pressure")
            }
            let intakeRequest = try IntakeRequest(
                memoID: memoID,
                audioSHA256: digest,
                byteCount: contentLength,
                revision: revision,
                capturedAt: Date(timeIntervalSinceReferenceDate: Double(bitPattern: capturedAtBits)),
                localeHint: request.headers["x-codex-locale"]
            )
            let result = try await intakeStore.commit(request: intakeRequest, body: request.body)
            try await scheduleCommittedIntake(memoID: memoID)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let body = try encoder.encode(BridgeEnvelope(payload: result.receipt))
            return HTTPResponse(
                status: result.disposition == .created ? 201 : 200,
                headers: ["content-type": "application/json", "content-length": String(body.count)],
                body: body
            )
        } catch IntakeStoreError.identityConflict {
            return Self.error(status: 409, code: "identity_conflict")
        } catch IntakeStoreError.lengthMismatch {
            return Self.error(status: 422, code: "length_mismatch")
        } catch IntakeStoreError.digestMismatch {
            return Self.error(status: 422, code: "digest_mismatch")
        } catch {
            return Self.error(status: 500, code: "intake_unavailable")
        }
    }

    private func memoStatus(_ request: HTTPRequest) async -> HTTPResponse {
        let components = request.path.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count == 4,
              components[0] == "v1",
              components[1] == "memos",
              components[3] == "status",
              let memoID = try? MemoID(String(components[2])),
              request.path == "/v1/memos/\(memoID.rawValue)/status",
              request.body.isEmpty,
              request.headers["content-length"] == "0",
              request.headers["x-codex-version"] == String(BridgeProtocolVersion.current.major),
              request.headers["x-codex-memo-id"] == memoID.rawValue,
              request.headers["x-codex-body-sha256"] == AudioDigest.hex(Data()),
              let rawRevision = request.headers["x-codex-revision"],
              let callerRevision = UInt64(rawRevision), callerRevision > 0,
              let rawTimestamp = request.headers["x-codex-timestamp"],
              let timestamp = Int64(rawTimestamp),
              let nonce = request.headers["x-codex-nonce"],
              let signature = request.headers["x-codex-signature"]
        else { return Self.error(status: 400, code: "invalid_request") }

        guard let authorization = request.headers["authorization"],
              authorization.hasPrefix("Bearer "),
              authorization.dropFirst(7).count == 64,
              let secret = try? await pairingStore.secret(
                  matchingBearerToken: String(authorization.dropFirst(7))
              )
        else { return Self.error(status: 401, code: "unauthorized") }

        do {
            let canonical = try CanonicalBridgeRequest(
                method: "GET",
                path: request.path,
                timestamp: timestamp,
                nonce: nonce,
                memoID: memoID,
                bodySHA256: AudioDigest.hex(Data()),
                revision: callerRevision
            )
            try await verifier.verify(
                signatureHex: signature,
                request: canonical,
                key: SymmetricKey(data: secret)
            )
        } catch RequestAuthenticationError.replayStoreUnavailable {
            return Self.error(status: 503, code: "auth_unavailable")
        } catch {
            return Self.error(status: 401, code: "unauthorized")
        }

        guard deliveryJournal != nil || finalStatusStore != nil else {
            return Self.error(status: 503, code: "status_unavailable")
        }
        do {
            if let status = try await authoritativeStatus(
                memoID: memoID,
                callerRevision: callerRevision
            ) {
                return try Self.json(status)
            }
            return Self.error(status: 404, code: "status_absent")
        } catch MemoStatusLookupError.revisionConflict {
            return Self.error(status: 409, code: "revision_conflict")
        } catch {
            return Self.error(status: 503, code: "status_unavailable")
        }
    }

    private func authoritativeStatus(
        memoID: MemoID,
        callerRevision: UInt64
    ) async throws -> BridgeMemoStatus? {
        let receipt = try await intakeStore.receipt(for: memoID)
        let record: DeliveryRecord?
        if let deliveryJournal {
            do {
                record = try deliveryJournal.load(memoID: memoID)
            } catch DeliveryJournalError.notFound {
                record = nil
            }
        } else {
            record = nil
        }
        let finalReceipt = try await finalStatusStore?.receipt(for: memoID)

        let activeStatus: BridgeMemoStatus?
        if let receipt, let record {
            guard record.memoID == receipt.memoID,
                  record.audioSHA256 == receipt.audioSHA256,
                  record.revision <= UInt64.max - receipt.acknowledgedRevision
            else { throw MemoStatusLookupError.unavailable }
            activeStatus = try BridgeMemoStatus(
                memoID: memoID,
                audioSHA256: receipt.audioSHA256,
                state: record.state,
                stateRevision: receipt.acknowledgedRevision + record.revision,
                updatedAt: record.updatedAt
            )
        } else {
            activeStatus = nil
        }

        if let finalReceipt {
            let finalStatus = try finalReceipt.bridgeMemoStatus
            if let activeStatus {
                guard activeStatus.memoID == finalStatus.memoID,
                      activeStatus.audioSHA256 == finalStatus.audioSHA256,
                      activeStatus.state == finalStatus.state,
                      activeStatus.stateRevision == finalStatus.stateRevision,
                      activeStatus.updatedAt == finalStatus.updatedAt
                else { throw MemoStatusLookupError.unavailable }
            }
            guard callerRevision <= finalStatus.stateRevision else {
                throw MemoStatusLookupError.revisionConflict
            }
            return finalStatus
        }
        if let activeStatus {
            guard callerRevision <= activeStatus.stateRevision else {
                throw MemoStatusLookupError.revisionConflict
            }
            return activeStatus
        }
        if receipt != nil || record != nil {
            throw MemoStatusLookupError.unavailable
        }
        return nil
    }

    private func finalAcknowledgement(_ request: HTTPRequest) async -> HTTPResponse {
        let components = request.path.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count == 4,
              components[0] == "v1",
              components[1] == "memos",
              components[3] == "final-ack",
              let memoID = try? MemoID(String(components[2])),
              request.path == "/v1/memos/\(memoID.rawValue)/final-ack",
              request.body.isEmpty,
              request.headers["content-length"] == "0",
              request.headers["x-codex-version"] == String(BridgeProtocolVersion.current.major),
              request.headers["x-codex-memo-id"] == memoID.rawValue,
              let digest = request.headers["x-codex-body-sha256"],
              AudioDigest.isValidHex(digest),
              let rawRevision = request.headers["x-codex-revision"],
              let revision = UInt64(rawRevision), revision > 0,
              let rawTimestamp = request.headers["x-codex-timestamp"],
              let timestamp = Int64(rawTimestamp),
              let nonce = request.headers["x-codex-nonce"],
              let signature = request.headers["x-codex-signature"]
        else { return Self.error(status: 400, code: "invalid_request") }

        guard let authorization = request.headers["authorization"],
              authorization.hasPrefix("Bearer "),
              authorization.dropFirst(7).count == 64,
              let secret = try? await pairingStore.secret(
                  matchingBearerToken: String(authorization.dropFirst(7))
              )
        else { return Self.error(status: 401, code: "unauthorized") }

        do {
            let canonical = try CanonicalBridgeRequest(
                method: "POST",
                path: request.path,
                timestamp: timestamp,
                nonce: nonce,
                memoID: memoID,
                bodySHA256: digest,
                revision: revision
            )
            try await verifier.verify(
                signatureHex: signature,
                request: canonical,
                key: SymmetricKey(data: secret)
            )
        } catch RequestAuthenticationError.replayStoreUnavailable {
            return Self.error(status: 503, code: "auth_unavailable")
        } catch {
            return Self.error(status: 401, code: "unauthorized")
        }

        guard let finalStatusStore else {
            return Self.error(status: 503, code: "status_unavailable")
        }
        do {
            guard try await finalStatusStore.acknowledge(
                memoID: memoID,
                audioSHA256: digest,
                stateRevision: revision
            ) else {
                return Self.error(status: 409, code: "identity_conflict")
            }
            return HTTPResponse(status: 204)
        } catch {
            return Self.error(status: 500, code: "status_unavailable")
        }
    }

    private func redeemPairing(_ request: HTTPRequest) async -> HTTPResponse {
        guard request.method == "POST",
              request.headers["x-codex-version"] == String(BridgeProtocolVersion.current.major),
              request.headers["content-type"] == "application/json",
              let rawLength = request.headers["content-length"],
              let contentLength = Int(rawLength),
              contentLength == request.body.count,
              contentLength <= 4_096,
              let redemption = try? JSONDecoder().decode(PairingRedemptionRequest.self, from: request.body),
              redemption.code.utf8.count == 6,
              redemption.code.utf8.allSatisfy({ (48 ... 57).contains($0) })
        else {
            return Self.error(status: 400, code: "invalid_request")
        }

        guard pairingRateLimiter.consume(at: clock()) else {
            return rateLimited(code: "pairing_failed")
        }

        do {
            let credential = try await pairingStore.redeem(code: redemption.code)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let body = try encoder.encode(PairingRedemptionResponse(token: credential.tokenHex))
            return HTTPResponse(
                status: 200,
                headers: ["content-type": "application/json", "content-length": String(body.count)],
                body: body
            )
        } catch PairingError.noActiveCode, PairingError.invalidCode, PairingError.expired {
            return Self.error(status: 401, code: "pairing_failed")
        } catch {
            return Self.error(status: 500, code: "pairing_unavailable")
        }
    }

    private func response(for result: IntakeCommitResult) async -> HTTPResponse {
        do {
            try await scheduleCommittedIntake(memoID: result.receipt.memoID)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let body = try encoder.encode(BridgeEnvelope(payload: result.receipt))
            return HTTPResponse(
                status: result.disposition == .created ? 201 : 200,
                headers: ["content-type": "application/json", "content-length": String(body.count)],
                body: body
            )
        } catch {
            return Self.error(status: 500, code: "intake_unavailable")
        }
    }

    private func scheduleCommittedIntake(memoID: MemoID) async throws {
        guard let record = try await intakeStore.committedRecord(for: memoID),
              let onCommitted
        else { return }
        Task { await onCommitted(record) }
    }

    private static func error(status: Int, code: String) -> HTTPResponse {
        let body = Data("{\"error\":\"\(code)\"}".utf8)
        return HTTPResponse(
            status: status,
            headers: ["content-type": "application/json", "content-length": String(body.count)],
            body: body
        )
    }

    private static func json(_ status: BridgeMemoStatus) throws -> HTTPResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let body = try encoder.encode(BridgeEnvelope(payload: status))
        return HTTPResponse(
            status: 200,
            headers: ["content-type": "application/json", "content-length": String(body.count)],
            body: body
        )
    }

    private func rateLimited(code: String) -> HTTPResponse {
        let body = Data("{\"error\":\"\(code)\"}".utf8)
        return HTTPResponse(
            status: 429,
            headers: [
                "content-type": "application/json",
                "content-length": String(body.count),
                "retry-after": String(rateLimitRetryAfterSeconds),
            ],
            body: body
        )
    }
}

private enum MemoStatusLookupError: Error {
    case revisionConflict
    case unavailable
}
