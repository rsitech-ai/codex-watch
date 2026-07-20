import Foundation

public enum MarkerReconciliation: Equatable, Sendable {
    case absent
    case delivered
    case duplicate(count: Int)
    case inconclusive
}

public enum MarkerReconciler {
    public static func evaluate(
        marker: String,
        historyTexts: [String],
        authoritative: Bool
    ) -> MarkerReconciliation {
        guard authoritative, !marker.isEmpty else { return .inconclusive }
        let normalizedMarker = normalize(marker)
        let count = historyTexts.reduce(into: 0) { total, text in
            total += occurrences(of: normalizedMarker, in: normalize(text))
        }
        switch count {
        case 0: return .absent
        case 1: return .delivered
        default: return .duplicate(count: count)
        }
    }

    private static func normalize(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .precomposedStringWithCanonicalMapping
    }

    private static func occurrences(of marker: String, in text: String) -> Int {
        var count = 0
        var start = text.startIndex
        while start < text.endIndex,
              let range = text.range(of: marker, range: start..<text.endIndex)
        {
            let beforeBoundary = range.lowerBound == text.startIndex
                || !isIdentifier(text[text.index(before: range.lowerBound)])
            let afterBoundary = range.upperBound == text.endIndex
                || !isIdentifier(text[range.upperBound])
            if beforeBoundary, afterBoundary { count += 1 }
            start = range.upperBound
        }
        return count
    }

    private static func isIdentifier(_ character: Character) -> Bool {
        character == "_" || character.isLetter || character.isNumber
    }
}
