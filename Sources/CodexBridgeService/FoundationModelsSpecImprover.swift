import Foundation
import CodexBridgeShared

#if canImport(FoundationModels)
import FoundationModels
#endif

public enum FoundationModelsSpecImprover {
    public static func availability() -> FoundationModelsAvailability {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            return mapAvailability(SystemLanguageModel.default.availability)
        }
        #endif
        return .unavailable("Foundation Models are not in this build.")
    }

    public static func liveIfAvailable() -> (any SpecImproving)? {
        #if canImport(FoundationModels)
        if #available(macOS 26, *), availability().isAvailable {
            return LiveFoundationModelsSpecImprover()
        }
        #endif
        return nil
    }

    #if canImport(FoundationModels)
    @available(macOS 26, *)
    private static func mapAvailability(
        _ availability: SystemLanguageModel.Availability
    ) -> FoundationModelsAvailability {
        switch availability {
        case .available:
            .available
        case .unavailable(.deviceNotEligible):
            .unavailable("This Mac does not support Apple Intelligence.")
        case .unavailable(.appleIntelligenceNotEnabled):
            .unavailable("Apple Intelligence is not enabled.")
        case .unavailable(.modelNotReady):
            .unavailable("The on-device model is still downloading or preparing.")
        case .unavailable:
            .unavailable("Foundation Models are unavailable.")
        }
    }
    #endif
}

#if canImport(FoundationModels)
@available(macOS 26, *)
private struct LiveFoundationModelsSpecImprover: SpecImproving {
    func improveSpec(memoID: MemoID, transcript: String) async throws -> String {
        _ = memoID
        let prompt = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { throw AppServerInboxError.invalidConfiguration }
        switch SystemLanguageModel.default.availability {
        case .available:
            break
        case .unavailable:
            throw AppServerInboxError.unavailable
        }

        let session = LanguageModelSession(
            instructions: Instructions("""
            Turn a Watch voice transcript into a markdown spec.
            Use only facts from the transcript. Do not invent requirements.
            """)
        )
        do {
            let draft = try await session.respond(
                to: Prompt(prompt),
                generating: MemoSpecDraft.self,
                options: GenerationOptions(temperature: 0.1, maximumResponseTokens: 400)
            ).content
            return MemoSpecDraft.markdown(draft)
        } catch LanguageModelSession.GenerationError.decodingFailure {
            let draft = try await session.respond(
                to: Prompt("""
                \(prompt)

                Return only values that fit the requested spec fields.
                """),
                generating: MemoSpecDraft.self,
                options: GenerationOptions(temperature: 0.0, maximumResponseTokens: 400)
            ).content
            return MemoSpecDraft.markdown(draft)
        } catch {
            throw AppServerInboxError.unavailable
        }
    }
}

@available(macOS 26, *)
@Generable
private struct MemoSpecDraft: Sendable {
    @Guide(description: "Short title taken only from the transcript")
    var title: String

    @Guide(description: "One-paragraph summary of what the speaker asked for")
    var summary: String

    @Guide(description: "Concrete requirements stated in the transcript")
    var requirements: [String]

    @Guide(description: "Open questions implied by the transcript")
    var openQuestions: [String]

    static func markdown(_ draft: Self) -> String {
        let requirements = draft.requirements.isEmpty
            ? "- None stated in the transcript."
            : draft.requirements.map { "- \($0)" }.joined(separator: "\n")
        let questions = draft.openQuestions.isEmpty
            ? "- None stated in the transcript."
            : draft.openQuestions.map { "- \($0)" }.joined(separator: "\n")
        return """
        # \(draft.title)

        > Improvement: on-device Foundation Models. Not Codex App Server.

        ## Summary
        \(draft.summary)

        ## Requirements
        \(requirements)

        ## Open questions
        \(questions)
        """
    }
}
#endif
