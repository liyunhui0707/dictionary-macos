import Foundation
import NaturalLanguage

enum LookupTask: String, CaseIterable, Sendable {
    case dictionary, translation
    var label: String { self == .dictionary ? "查词" : "翻译" }

    /// Grammar and sentence boundaries are hints, not claims of user intent.
    /// The visible mode switch remains available for ambiguous expressions.
    static func inferred(from source: String) -> Self {
        let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.setLanguage(.english); tokenizer.string = text
        let words = tokenizer.tokens(for: text.startIndex..<text.endIndex).map { String(text[$0]) }
        guard words.count > 1 else { return .dictionary }
        let sentences = NLTokenizer(unit: .sentence)
        sentences.setLanguage(.english); sentences.string = text
        if sentences.tokens(for: text.startIndex..<text.endIndex).count > 1 { return .translation }
        if text.range(of: "[.!?][\"'”’)]*$", options: .regularExpression) != nil { return .translation }
        if text.contains("\n") && words.count >= 4 { return .translation }
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text; tagger.setLanguage(.english, range: text.startIndex..<text.endIndex)
        var tags: [NLTag] = []
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass,
                             options: [.omitWhitespace, .omitPunctuation]) { tag, _ in
            tags.append(tag ?? .otherWord); return true
        }
        let subjects: Set<String> = ["i", "you", "he", "she", "it", "we", "they", "there", "this", "that", "these", "those"]
        if subjects.contains(words[0].lowercased()), tags.contains(.verb) { return .translation }
        if tags.count >= 2, tags[0] == .noun, tags[1] == .verb { return .translation }
        if words.count >= 3, tags.first == .verb, tags.dropFirst().contains(where: { $0 == .determiner || $0 == .pronoun }) {
            return .translation
        }
        if words.count >= 4, tags.contains(.verb), tags.prefix(2).contains(.determiner) { return .translation }
        return words.count >= 9 ? .translation : .dictionary
    }
}

enum LookupMode: String, CaseIterable {
    case automatic, dictionary, translation
    var label: String {
        switch self { case .automatic: return "自动"; case .dictionary: return "查词"; case .translation: return "翻译" }
    }
    var task: LookupTask? {
        switch self { case .automatic: return nil; case .dictionary: return .dictionary; case .translation: return .translation }
    }
}
