import CodexAppServerClient
import CodexAppServerProtocol
import CodexBridgeShared
import Darwin
import Foundation

public enum AppServerInboxError: Error, Equatable, Sendable {
    case invalidConfiguration
    case invalidResponse
    case duplicateInbox
    case invalidNeutralDirectory
    case targetMismatch
    case incompleteCatalog
    case unavailable
    case operationTimedOut
    case connectionLostAfterPossibleAcceptance
}

public protocol AppServerRequesting: Sendable {
    func initialize(clientName: String, title: String, version: String) async throws
    func call(_ method: AppServerMethod) async throws -> JSONValue
    func notifications() -> AsyncStream<JSONRPCNotification>
    func close() async
}

extension AppServerClient: AppServerRequesting {}

public actor AppServerInboxClient: InboxDeliveryClient {
    public static let exactThreadName = "Codex Voice Inbox"

    private typealias SessionFactory = @Sendable () throws -> any AppServerRequesting

    private let sessionFactory: SessionFactory
    private let neutralDirectory: URL
    private let completionTimeout: Duration

    public init(
        sessionFactory: @escaping @Sendable () throws -> any AppServerRequesting,
        neutralDirectory: URL,
        completionTimeout: Duration = .seconds(120)
    ) {
        self.sessionFactory = sessionFactory
        self.neutralDirectory = neutralDirectory.standardizedFileURL
        self.completionTimeout = completionTimeout
    }

    init(
        session: any AppServerRequesting,
        neutralDirectory: URL,
        completionTimeout: Duration = .seconds(120)
    ) {
        sessionFactory = { session }
        self.neutralDirectory = neutralDirectory.standardizedFileURL
        self.completionTimeout = completionTimeout
    }

    public init(
        codexExecutableURL: URL,
        neutralDirectory: URL,
        completionTimeout: Duration = .seconds(120)
    ) throws {
        let executable = codexExecutableURL.standardizedFileURL
        guard executable.isFileURL, executable.path.hasPrefix("/") else {
            throw AppServerInboxError.invalidConfiguration
        }
        sessionFactory = {
            let transport = StdioProcessTransport(
                executable: executable.path,
                arguments: ["app-server"]
            )
            return AppServerClient(transport: transport)
        }
        self.neutralDirectory = neutralDirectory.standardizedFileURL
        self.completionTimeout = completionTimeout
    }

    public func submit(memoID: MemoID, marker: String, text: String) async throws {
        guard !marker.isEmpty, text.contains(marker) else {
            throw InboxSubmissionFailure.definitelyNotAccepted
        }
        let session: any AppServerRequesting
        do {
            session = try sessionFactory()
        } catch {
            throw InboxSubmissionFailure.definitelyNotAccepted
        }
        var turnStartIssued = false
        do {
            try await initialize(session)
            let inboxID = try await resolveInbox(using: session)
            turnStartIssued = true
            let response = try await session.call(.captureOnlyTurnStart(
                threadID: inboxID,
                clientMessageID: memoID.rawValue,
                text: text
            ))
            guard case let .object(turn)? = response["turn"],
                  case let .string(turnID)? = turn["id"],
                  !turnID.isEmpty,
                  turnID.utf8.count <= 4096
            else { throw AppServerInboxError.invalidResponse }
            try await waitForCompletion(
                session: session,
                threadID: inboxID,
                turnID: turnID
            )
            await session.close()
        } catch {
            await session.close()
            throw turnStartIssued
                ? InboxSubmissionFailure.acceptanceUnknown
                : InboxSubmissionFailure.definitelyNotAccepted
        }
    }

    public func history(containing marker: String) async throws -> InboxHistory {
        guard !marker.isEmpty else { throw AppServerInboxError.invalidConfiguration }
        let session = try sessionFactory()
        do {
            try await initialize(session)
            let inboxID = try await resolveInbox(using: session)
            let response = try await session.call(.threadRead(threadID: inboxID, includeTurns: true))
            guard case let .object(thread)? = response["thread"],
                  case let .string(responseID)? = thread["id"],
                  responseID == inboxID,
                  case let .string(cwd)? = thread["cwd"],
                  URL(fileURLWithPath: cwd).standardizedFileURL == neutralDirectory
            else { throw AppServerInboxError.targetMismatch }
            let projection = Self.collectUserMessages(from: .object(thread))
            await session.close()
            return InboxHistory(texts: projection.texts, authoritative: projection.complete)
        } catch {
            await session.close()
            if let error = error as? AppServerInboxError { throw error }
            throw AppServerInboxError.unavailable
        }
    }

    private func initialize(_ session: any AppServerRequesting) async throws {
        try await session.initialize(
            clientName: "codex-watch-bridge",
            title: "RSI Voice Inbox",
            version: "0.1.0"
        )
    }

    private func resolveInbox(using session: any AppServerRequesting) async throws -> String {
        var cursor: String?
        var seenCursors = Set<String>()
        var matches: [InboxThread] = []
        var catalogComplete = false
        for _ in 0 ..< 64 {
            let response = try await session.call(.threadListPage(cursor: cursor, sourceKinds: nil))
            let page = try Self.decodePage(response)
            matches.append(contentsOf: page.matches)
            guard let next = page.nextCursor else {
                catalogComplete = true
                break
            }
            guard seenCursors.insert(next).inserted else {
                throw AppServerInboxError.invalidResponse
            }
            cursor = next
        }
        guard catalogComplete else { throw AppServerInboxError.incompleteCatalog }
        guard matches.count <= 1 else { throw AppServerInboxError.duplicateInbox }
        if let existing = matches.first {
            guard URL(fileURLWithPath: existing.cwd).standardizedFileURL == neutralDirectory else {
                throw AppServerInboxError.targetMismatch
            }
            _ = try Self.validateNeutralDirectory(neutralDirectory)
            return existing.id
        }

        let before = try Self.validateNeutralDirectory(neutralDirectory)
        let response = try await session.call(.threadStart(
            cwd: neutralDirectory.path,
            ephemeral: false
        ))
        let after = try Self.validateNeutralDirectory(neutralDirectory)
        guard before == after,
              case let .object(thread)? = response["thread"],
              case let .string(createdID)? = thread["id"],
              !createdID.isEmpty,
              createdID.utf8.count <= 4096,
              case let .string(cwd)? = thread["cwd"],
              URL(fileURLWithPath: cwd).standardizedFileURL == neutralDirectory
        else { throw AppServerInboxError.targetMismatch }
        _ = try await session.call(.threadSetName(
            threadID: createdID,
            name: Self.exactThreadName
        ))
        return createdID
    }

    private func waitForCompletion(
        session: any AppServerRequesting,
        threadID: String,
        turnID: String
    ) async throws {
        let stream = session.notifications()
        let timeout = completionTimeout
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for await notification in stream {
                    guard notification.method == "turn/completed",
                          case let .string(notificationThread)? = notification.params["threadId"],
                          notificationThread == threadID,
                          case let .object(turn)? = notification.params["turn"],
                          case let .string(notificationTurn)? = turn["id"],
                          notificationTurn == turnID
                    else { continue }
                    return
                }
                throw AppServerInboxError.connectionLostAfterPossibleAcceptance
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw AppServerInboxError.operationTimedOut
            }
            guard try await group.next() != nil else {
                throw AppServerInboxError.connectionLostAfterPossibleAcceptance
            }
            group.cancelAll()
        }
    }

    private static func decodePage(_ value: JSONValue) throws -> (
        matches: [InboxThread],
        nextCursor: String?
    ) {
        guard case let .object(fields) = value,
              case let .array(entries)? = fields["data"]
        else { throw AppServerInboxError.invalidResponse }

        let nextCursor: String?
        switch fields["nextCursor"] {
        case nil, .null?:
            nextCursor = nil
        case let .string(value)?:
            guard !value.isEmpty, value.utf8.count <= 4096 else {
                throw AppServerInboxError.invalidResponse
            }
            nextCursor = value
        default:
            throw AppServerInboxError.invalidResponse
        }

        var matches: [InboxThread] = []
        for entry in entries {
            guard case let .object(thread) = entry,
                  case let .string(id)? = thread["id"],
                  !id.isEmpty,
                  id.utf8.count <= 4096
            else { throw AppServerInboxError.invalidResponse }
            if case let .string(name)? = thread["name"], name == exactThreadName {
                guard case let .string(cwd)? = thread["cwd"], !cwd.isEmpty else {
                    throw AppServerInboxError.targetMismatch
                }
                matches.append(InboxThread(id: id, cwd: cwd))
            }
        }
        return (matches, nextCursor)
    }

    private static func validateNeutralDirectory(_ directory: URL) throws -> DirectoryIdentity {
        let descriptor = Darwin.open(
            directory.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else { throw AppServerInboxError.invalidNeutralDirectory }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard directory.isFileURL,
              fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == getuid(),
              metadata.st_mode & 0o077 == 0,
              (try? FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty) == true
        else { throw AppServerInboxError.invalidNeutralDirectory }
        return DirectoryIdentity(device: metadata.st_dev, inode: metadata.st_ino)
    }

    private static func collectUserMessages(
        from value: JSONValue
    ) -> (texts: [String], complete: Bool) {
        switch value {
        case let .array(values):
            return values.reduce(into: (texts: [String](), complete: true)) { result, item in
                let nested = collectUserMessages(from: item)
                result.texts.append(contentsOf: nested.texts)
                result.complete = result.complete && nested.complete
            }
        case let .object(fields):
            if case let .array(turns)? = fields["turns"] {
                return collectUserMessages(from: .array(turns))
            }
            if case let .array(items)? = fields["items"] {
                return collectUserMessages(from: .array(items))
            }
            guard case let .string(type)? = fields["type"] else { return ([], false) }
            guard ["userMessage", "user_message", "user"].contains(type) else {
                return ([], knownNonUserTypes.contains(type))
            }
            if case let .string(text)? = fields["text"] { return ([text], true) }
            guard case let .array(content)? = fields["content"] else { return ([], false) }
            var texts: [String] = []
            for part in content {
                guard case let .object(partFields) = part,
                      case let .string(partType)? = partFields["type"]
                else { return (texts, false) }
                if ["text", "input_text"].contains(partType) {
                    guard case let .string(text)? = partFields["text"] else {
                        return (texts, false)
                    }
                    texts.append(text)
                } else if !knownNonTextTypes.contains(partType) {
                    return (texts, false)
                }
            }
            return (texts, !texts.isEmpty)
        case .null, .bool, .number, .string:
            return ([], false)
        }
    }

    private static let knownNonTextTypes = Set(["image", "localImage", "skill", "mention"])
    private static let knownNonUserTypes = Set([
        "hookPrompt", "agentMessage", "assistantMessage", "plan", "reasoning",
        "commandExecution", "fileChange", "mcpToolCall", "dynamicToolCall",
        "collabAgentToolCall", "webSearch", "imageView", "imageGeneration",
        "enteredReviewMode", "exitedReviewMode", "contextCompaction", "toolMessage",
    ])
}

private struct InboxThread: Sendable {
    let id: String
    let cwd: String
}

private struct DirectoryIdentity: Equatable, Sendable {
    let device: dev_t
    let inode: ino_t
}
