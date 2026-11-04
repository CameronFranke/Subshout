import Foundation

/// Validation shared by the settings editor and transcription requests.
/// Errors identify positions, never the user's vocabulary text.
enum Vocabulary {
    static let maximumEntries = 128
    static let maximumPhraseBytes = 256

    enum ValidationError: LocalizedError, Equatable {
        case emptyPhrase(Int)
        case controlCharacter(Int)
        case phraseTooLong(Int)
        case tooManyEntries

        var errorDescription: String? {
            switch self {
            case .emptyPhrase(let position):
                return "Entry \(position) is empty."
            case .controlCharacter(let position):
                return "Entry \(position) contains a non-whitespace control character."
            case .phraseTooLong(let position):
                return "Entry \(position) exceeds \(Vocabulary.maximumPhraseBytes) UTF-8 bytes."
            case .tooManyEntries:
                return "Use at most \(Vocabulary.maximumEntries) unique words or phrases."
            }
        }
    }

    /// Blank editor lines are separators, not vocabulary entries.
    static func parse(_ text: String) throws -> [String] {
        let lines = text.components(separatedBy: .newlines)
            .filter { !$0.unicodeScalars.allSatisfy(isWhitespace) }
        return try normalize(lines)
    }

    /// Preserve first spelling/order while collapsing whitespace and duplicates.
    static func normalize(_ entries: [String]) throws -> [String] {
        var normalized: [String] = []
        var seen: Set<String> = []
        for (index, entry) in entries.enumerated() {
            for scalar in entry.unicodeScalars {
                switch scalar.properties.generalCategory {
                case .control, .format, .surrogate, .privateUse, .unassigned:
                    if !isWhitespace(scalar) {
                        throw ValidationError.controlCharacter(index + 1)
                    }
                default:
                    break
                }
            }
            let phrase = entry.unicodeScalars.split(whereSeparator: isWhitespace)
                .map { String(String.UnicodeScalarView($0)) }.joined(separator: " ")
            guard !phrase.isEmpty else { throw ValidationError.emptyPhrase(index + 1) }
            guard phrase.utf8.count <= maximumPhraseBytes else {
                throw ValidationError.phraseTooLong(index + 1)
            }
            let key = phrase.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            if seen.insert(key).inserted {
                normalized.append(phrase)
                guard normalized.count <= maximumEntries else { throw ValidationError.tooManyEntries }
            }
        }
        return normalized
    }

    // Match Python str.isspace(), including its four information separators.
    private static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isWhitespace || (0x1C...0x1F).contains(scalar.value)
    }
}
