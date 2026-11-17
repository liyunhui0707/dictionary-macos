import AppKit

enum ScreenContextSafety {
    /// Capture has already validated the source, pixels and unique target box.
    /// Additional conservative filters reduce interruptions; they do not verify meaning.
    static func eligible(sentence: String, lines: [ScreenTextLine], hasSpellingIssue: (String) -> Bool) -> Bool {
        !lines.isEmpty && lines.allSatisfy { $0.confidence >= 0.95 } &&
        sentence.utf16.count <= 400 && !hasSpellingIssue(sentence)
    }

    @MainActor static func hasSpellingIssue(_ text: String) -> Bool {
        NSSpellChecker.shared.checkSpelling(of: text, startingAt: 0, language: "en_US", wrap: false,
                                           inSpellDocumentWithTag: 0, wordCount: nil).location != NSNotFound
    }

    static func validEdit(_ text: String, target: String) -> Bool {
        let value = SelectionLocation.trim(text)
        return !value.isEmpty && value.utf16.count <= 2000 && ScreenTextContext.occurrences(target, in: value).count == 1
    }
}
