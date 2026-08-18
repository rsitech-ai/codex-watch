import CodexBridgeShared
import Foundation

public enum MemoSpecProvenance: String, Equatable, Sendable {
    case foundationModels = "foundation-models"
    case appServer = "app-server"
    case localFallback = "local-fallback"
}

public enum FoundationModelsAvailability: Equatable, Sendable {
    case available
    case unavailable(String)

    public var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    public var detail: String {
        switch self {
        case .available:
            "On-device Foundation Models can improve transcripts into specs."
        case let .unavailable(reason):
            reason
        }
    }

    public static func current() -> Self {
        FoundationModelsSpecImprover.availability()
    }
}

public struct MemoSpecImprover: Sendable {
    private let foundationModels: (any SpecImproving)?
    private let appServer: (any SpecImproving)?

    public init(
        foundationModels: (any SpecImproving)? = nil,
        appServer: (any SpecImproving)? = nil
    ) {
        self.foundationModels = foundationModels
        self.appServer = appServer
    }

    public func improve(
        transcript: String,
        capturedAt: Date,
        memoID: MemoID
    ) async -> MemoSpec {
        if let foundationModels {
            do {
                let markdown = try await foundationModels.improveSpec(
                    memoID: memoID,
                    transcript: transcript
                )
                if let improved = MemoSpecDocument.acceptFoundationModelsMarkdown(markdown) {
                    return improved
                }
            } catch {
                // ponytail: FM is best-effort; App Server then local wrapper stay downloadable.
            }
        }
        if let appServer {
            do {
                let markdown = try await appServer.improveSpec(
                    memoID: memoID,
                    transcript: transcript
                )
                if let improved = MemoSpecDocument.acceptAppServerMarkdown(markdown) {
                    return improved
                }
            } catch {
                // ponytail: App Server improvement is best-effort; local wrapper stays downloadable.
            }
        }
        return MemoSpecDocument.localFallback(
            transcript: transcript,
            capturedAt: capturedAt,
            memoID: memoID
        )
    }
}

public struct MemoSpec: Equatable, Sendable {
    public let markdown: String
    public let provenance: MemoSpecProvenance

    public init(markdown: String, provenance: MemoSpecProvenance) {
        self.markdown = markdown
        self.provenance = provenance
    }

    public var title: String {
        MemoSpecDocument.title(from: markdown)
    }
}

public protocol SpecImproving: Sendable {
    func improveSpec(memoID: MemoID, transcript: String) async throws -> String
}

public enum MemoSpecDocument {
    private static let provenancePrefix = "<!-- provenance:"
    private static let maximumBytes = 128 * 1_024

    public static func improvePrompt(transcript: String) -> String {
        """
        Turn this Watch voice transcript into a markdown spec.
        Reply with markdown only. Use a title heading, then Summary, Requirements, and Open questions.
        Do not execute the idea, inspect files, use the network, or request approval.

        Transcript:
        \(transcript)
        """
    }

    public static func localFallback(
        transcript: String,
        capturedAt: Date,
        memoID: MemoID
    ) -> MemoSpec {
        let raw = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = title(fromTranscript: raw)
        let summary = summary(from: raw)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let markdown = """
        # \(title)

        > Improvement: unverified local wrapper. Foundation Models and Codex App Server did not produce this spec.

        ## Summary
        \(summary)

        ## Requirements
        - \(raw)

        ## Open questions
        - What should Codex do with this idea?

        ## Raw transcript
        \(raw)

        Captured at: \(formatter.string(from: capturedAt))
        Memo: \(memoID.rawValue)
        """
        return MemoSpec(markdown: markdown, provenance: .localFallback)
    }

    public static func acceptAppServerMarkdown(_ text: String) -> MemoSpec? {
        accept(text, provenance: .appServer)
    }

    public static func acceptFoundationModelsMarkdown(_ text: String) -> MemoSpec? {
        accept(text, provenance: .foundationModels)
    }

    private static func accept(_ text: String, provenance: MemoSpecProvenance) -> MemoSpec? {
        let markdown = unwrapFence(text)
        guard looksLikeSpec(markdown), validContent(markdown) else { return nil }
        return MemoSpec(markdown: markdown, provenance: provenance)
    }

    public static func serialized(_ spec: MemoSpec) -> String {
        "\(provenancePrefix) \(spec.provenance.rawValue) -->\n\n\(spec.markdown)\n"
    }

    public static func parse(_ text: String) -> MemoSpec? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard validContent(trimmed) else { return nil }
        let provenance: MemoSpecProvenance
        let markdown: String
        if trimmed.hasPrefix(provenancePrefix),
           let end = trimmed.range(of: "-->")
        {
            let token = trimmed[trimmed.index(trimmed.startIndex, offsetBy: provenancePrefix.count)..<end.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            provenance = MemoSpecProvenance(rawValue: token) ?? .localFallback
            markdown = trimmed[end.upperBound...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            provenance = .localFallback
            markdown = trimmed
        }
        guard validContent(markdown) else { return nil }
        return MemoSpec(markdown: markdown, provenance: provenance)
    }

    public static func title(from markdown: String) -> String {
        for line in markdown.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("# ") {
                let value = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { return value }
            }
        }
        return "Voice memo"
    }

    public static func html(markdown: String, title: String) -> String {
        """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <title>\(escape(title))</title>
        <style>
        :root { color-scheme: light dark; }
        body { font: 16px/1.45 -apple-system, BlinkMacSystemFont, sans-serif; max-width: 40rem; margin: 2rem auto; padding: 0 1.25rem; color: CanvasText; background: Canvas; }
        h1 { font-size: 1.6rem; letter-spacing: -0.02em; }
        h2 { font-size: 1.15rem; margin-top: 1.4rem; }
        blockquote { margin: 0; padding: 0.5rem 0.75rem; border-left: 3px solid GrayText; color: GrayText; }
        ul { padding-left: 1.2rem; }
        p { margin: 0.6rem 0; }
        </style>
        </head>
        <body>
        \(htmlBody(markdown))
        </body>
        </html>
        """
    }

    public static func looksLikeSpec(_ markdown: String) -> Bool {
        let text = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        return text.contains("# ") || text.localizedCaseInsensitiveContains("## Summary")
    }

    private static func title(fromTranscript transcript: String) -> String {
        let line = transcript.split(whereSeparator: \.isNewline).first.map(String.init) ?? transcript
        let sentence = line.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: true)
            .first.map(String.init) ?? line
        let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Voice memo" }
        if trimmed.count <= 72 { return trimmed }
        return String(trimmed.prefix(72)).trimmingCharacters(in: .whitespaces) + "…"
    }

    private static func summary(from transcript: String) -> String {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 280 { return trimmed }
        return String(trimmed.prefix(280)).trimmingCharacters(in: .whitespaces) + "…"
    }

    private static func unwrapFence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```") else { return trimmed }
        var lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.first?.hasPrefix("```") == true {
            lines.removeFirst()
        }
        if lines.last?.hasPrefix("```") == true {
            lines.removeLast()
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func validContent(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
            && trimmed.utf8.count <= maximumBytes
            && !trimmed.unicodeScalars.contains(where: { $0.value == 0 })
    }

    private static func htmlBody(_ markdown: String) -> String {
        var html: [String] = []
        var inList = false
        func closeList() {
            if inList {
                html.append("</ul>")
                inList = false
            }
        }
        for line in markdown.components(separatedBy: "\n") {
            if line.hasPrefix("<!--") { continue }
            if line.hasPrefix("# ") {
                closeList()
                html.append("<h1>\(escape(String(line.dropFirst(2))))</h1>")
            } else if line.hasPrefix("## ") {
                closeList()
                html.append("<h2>\(escape(String(line.dropFirst(3))))</h2>")
            } else if line.hasPrefix("- ") {
                if !inList {
                    html.append("<ul>")
                    inList = true
                }
                html.append("<li>\(escape(String(line.dropFirst(2))))</li>")
            } else if line.hasPrefix("> ") {
                closeList()
                html.append("<blockquote>\(escape(String(line.dropFirst(2))))</blockquote>")
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                closeList()
            } else {
                closeList()
                html.append("<p>\(escape(line))</p>")
            }
        }
        closeList()
        return html.joined(separator: "\n")
    }

    private static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
