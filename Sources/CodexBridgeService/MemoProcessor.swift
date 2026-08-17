import CodexBridgeDelivery
import CodexBridgeShared
import Foundation

public struct InboxHistory: Equatable, Sendable {
    public let texts: [String]
    public let authoritative: Bool

    public init(texts: [String], authoritative: Bool) {
        self.texts = texts
        self.authoritative = authoritative
    }
}

public enum InboxSubmissionFailure: Error, Equatable, Sendable {
    case definitelyNotAccepted
    case acceptanceUnknown
}

public protocol InboxDeliveryClient: Sendable {
    func submit(memoID: MemoID, marker: String, text: String) async throws
    func history(containing marker: String) async throws -> InboxHistory
}

public struct MemoProcessingRequest: Equatable, Sendable {
    public let memoID: MemoID
    public let capturedAt: Date
    public let localeHint: String?
    public let committedAudio: CommittedAudioAsset

    public init(
        memoID: MemoID,
        capturedAt: Date,
        localeHint: String?,
        committedAudio: CommittedAudioAsset
    ) {
        self.memoID = memoID
        self.capturedAt = capturedAt
        self.localeHint = localeHint
        self.committedAudio = committedAudio
    }
}

public enum MemoProcessingOutcome: Equatable, Sendable {
    case delivered
    case retryable
    case needsAttention
}

public enum MemoProcessorError: Error, Equatable, Sendable {
    case invalidRequest
    case requestMismatch
    case journalFailure
}

public struct MemoProcessor: Sendable {
    private let journal: DeliveryJournal
    private let transcriber: any TranscriptionEngine
    private let inbox: any InboxDeliveryClient
    private let specImprover: (any SpecImproving)?
    private let specStore: MemoSpecStore?

    public init(
        journal: DeliveryJournal,
        transcriber: any TranscriptionEngine,
        inbox: any InboxDeliveryClient,
        specImprover: (any SpecImproving)? = nil,
        specStore: MemoSpecStore? = nil
    ) {
        self.journal = journal
        self.transcriber = transcriber
        self.inbox = inbox
        self.specImprover = specImprover
        self.specStore = specStore
    }

    public func process(_ request: MemoProcessingRequest) async throws -> MemoProcessingOutcome {
        guard request.capturedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw MemoProcessorError.invalidRequest
        }

        var record = try loadOrCreate(request)
        guard record.capturedAt == request.capturedAt,
              record.localeHint == request.localeHint,
              record.audioSHA256 == request.committedAudio.expectedSHA256
        else { throw MemoProcessorError.requestMismatch }

        switch record.state {
        case .received:
            record = try transition(request.memoID, to: .transcribing)
            fallthrough
        case .transcribing:
            do {
                let transcript = try await transcriber.transcribe(
                    committedAudio: request.committedAudio,
                    localeHint: request.localeHint
                )
                record = try transition(
                    request.memoID,
                    to: .readyForCodex,
                    transcript: transcript
                )
                await persistSpec(
                    memoID: request.memoID,
                    transcript: transcript,
                    capturedAt: record.capturedAt
                )
            } catch {
                _ = try transition(request.memoID, to: .needsAttention)
                return .needsAttention
            }
            fallthrough
        case .readyForCodex:
            guard let transcript = record.transcript else {
                throw MemoProcessorError.journalFailure
            }
            await persistSpec(
                memoID: request.memoID,
                transcript: transcript,
                capturedAt: record.capturedAt
            )
            record = try transition(request.memoID, to: .inserting)
            let marker = Self.marker(for: request.memoID)
            let spec = specStore?.load(memoID: request.memoID)
            do {
                try await inbox.submit(
                    memoID: request.memoID,
                    marker: marker,
                    text: Self.captureText(
                        marker: marker,
                        transcript: transcript,
                        spec: spec,
                        capturedAt: record.capturedAt,
                        localeHint: record.localeHint
                    )
                )
            } catch let failure as InboxSubmissionFailure {
                switch failure {
                case .definitelyNotAccepted:
                    _ = try reopenForSafeRetry(
                        request.memoID,
                        boundary: .definitelyNotAccepted
                    )
                    return .retryable
                case .acceptanceUnknown:
                    _ = try transition(request.memoID, to: .reconciling)
                    return .retryable
                }
            } catch {
                // An untyped delivery implementation cannot prove rejection.
                // Preserve ambiguity and reconcile on a later pass.
                _ = try transition(request.memoID, to: .reconciling)
                return .retryable
            }
            record = try transition(request.memoID, to: .reconciling)
            return try await reconcile(record: record)
        case .inserting:
            record = try transition(request.memoID, to: .reconciling)
            return try await reconcile(record: record)
        case .reconciling:
            return try await reconcile(record: record)
        case .delivered:
            return .delivered
        case .needsAttention:
            return .needsAttention
        case .saved, .uploading:
            throw MemoProcessorError.journalFailure
        }
    }

    public func retry(_ request: MemoProcessingRequest) async throws -> MemoProcessingOutcome {
        if let existing = try? journal.load(memoID: request.memoID),
           existing.state == .readyForCodex,
           existing.transcript != nil
        {
            return try await process(request)
        }
        do {
            _ = try journal.retry(memoID: request.memoID)
        } catch {
            throw MemoProcessorError.journalFailure
        }
        return try await process(request)
    }

    public static func marker(for memoID: MemoID) -> String {
        "[codex-voice-memo:\(memoID.rawValue)]"
    }

    private func loadOrCreate(_ request: MemoProcessingRequest) throws -> DeliveryRecord {
        do {
            return try journal.load(memoID: request.memoID)
        } catch DeliveryJournalError.notFound {
            do {
                try journal.create(.received(
                    memoID: request.memoID,
                    capturedAt: request.capturedAt,
                    localeHint: request.localeHint,
                    audioSHA256: request.committedAudio.expectedSHA256
                ))
                return try journal.load(memoID: request.memoID)
            } catch {
                throw MemoProcessorError.journalFailure
            }
        } catch {
            throw MemoProcessorError.journalFailure
        }
    }

    private func transition(
        _ memoID: MemoID,
        to state: MemoState,
        transcript: String? = nil
    ) throws -> DeliveryRecord {
        do {
            return try journal.transition(memoID: memoID, to: state, transcript: transcript)
        } catch {
            throw MemoProcessorError.journalFailure
        }
    }

    private func reconcile(record: DeliveryRecord) async throws -> MemoProcessingOutcome {
        let marker = Self.marker(for: record.memoID)
        let history: InboxHistory
        do {
            history = try await inbox.history(containing: marker)
        } catch {
            // Keep the durable ambiguity state. A later run may establish a
            // fresh App Server connection and reconcile, but must not resubmit.
            return .retryable
        }

        switch MarkerReconciler.evaluate(
            marker: marker,
            historyTexts: history.texts,
            authoritative: history.authoritative
        ) {
        case .delivered:
            _ = try transition(record.memoID, to: .delivered)
            return .delivered
        case .inconclusive:
            _ = try transition(record.memoID, to: .needsAttention)
            return .needsAttention
        case .absent:
            _ = try reopenForSafeRetry(
                record.memoID,
                boundary: .authoritativelyAbsent
            )
            return .retryable
        case .duplicate:
            _ = try transition(record.memoID, to: .needsAttention)
            return .needsAttention
        }
    }

    private func reopenForSafeRetry(
        _ memoID: MemoID,
        boundary: DeliverySafeRetryBoundary
    ) throws -> DeliveryRecord {
        do {
            return try journal.reopenForSafeRetry(memoID: memoID, boundary: boundary)
        } catch {
            throw MemoProcessorError.journalFailure
        }
    }

    private func persistSpec(
        memoID: MemoID,
        transcript: String,
        capturedAt: Date
    ) async {
        guard let specStore else { return }
        if specStore.load(memoID: memoID) != nil {
            return
        }
        var spec = MemoSpecDocument.localFallback(
            transcript: transcript,
            capturedAt: capturedAt,
            memoID: memoID
        )
        if let specImprover {
            do {
                let markdown = try await specImprover.improveSpec(
                    memoID: memoID,
                    transcript: transcript
                )
                if let improved = MemoSpecDocument.acceptAppServerMarkdown(markdown) {
                    spec = improved
                }
            } catch {
                // ponytail: App Server improvement is best-effort; local wrapper stays downloadable.
            }
        }
        try? specStore.save(spec, memoID: memoID)
    }

    private static func captureText(
        marker: String,
        transcript: String,
        spec: MemoSpec?,
        capturedAt: Date,
        localeHint: String?
    ) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let body: String
        if let spec, spec.provenance == .appServer {
            body = """
            Spec (Codex App Server):
            \(spec.markdown)
            """
        } else {
            body = """
            Voice idea:
            \(transcript)
            """
        }
        return """
        \(marker)
        Captured at: \(formatter.string(from: capturedAt))
        Locale: \(localeHint ?? "unspecified")
        \(body)

        Capture this idea in Codex Watch. Do not execute the idea, inspect files, use the network, or request approval.
        """
    }
}
