import Foundation
import zlib

struct EnglishSense: Identifiable, Equatable, Sendable {
    let id: String
    let synsetID: String
    let partOfSpeech: String
    let definition: String
    let examples: [String]
}

struct EnglishEntryMatch: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable { case spelling, recordedForm, possibleBase }
    let lemma: String
    let kind: Kind
    let senses: [EnglishSense]
    var id: String { kind.rawValue + ":" + lemma }
    var label: String {
        switch kind {
        case .spelling: "\(lemma) · 词典条目"
        case .recordedForm: "\(lemma) · 词典收录的原形"
        case .possibleBase: "\(lemma) · 可能的原形"
        }
    }
}

/// Offline definitions: no context ranking, model calls or mutations of AI output.
/// Loaded once, off the UI actor, for reference disclosure or local target-only lookup.
actor EnglishDictionary {
    static let shared = EnglishDictionary(resourceURL: bundledResourceURL)
    static let bundleName = "DictionaryApp_DictionaryApp.bundle"
    static var bundledResourceURL: URL? {
        if Bundle.main.bundleURL.pathExtension == "app" {
            // Installed apps must never fall back to SwiftPM's absolute build-directory path.
            return Bundle.main.resourceURL.flatMap { packagedResource(in: $0) }
        }
        return Bundle.module.url(forResource: "oewn-2025.json", withExtension: "gz", subdirectory: "EnglishDictionary")
    }

    static func packagedResource(in resources: URL) -> URL? {
        let bundle = resources.appendingPathComponent(bundleName)
        // SwiftPM's native and Xcode build systems use flat and Contents-style bundles.
        return ["Contents/Resources/EnglishDictionary/oewn-2025.json.gz", "EnglishDictionary/oewn-2025.json.gz"]
            .map { bundle.appendingPathComponent($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private let resourceURL: URL?
    private var loaded: Result<Lexicon, Error>?

    init(resourceURL: URL?) { self.resourceURL = resourceURL }

    func lookup(_ target: String) throws -> [EnglishSense] {
        try lookupEntries(target).flatMap(\.senses)
    }

    func lookupEntries(_ target: String) throws -> [EnglishEntryMatch] {
        let key = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return [] }
        if loaded == nil {
            loaded = Result {
                guard let resourceURL else { throw ReferenceError.unavailable }
                let data = try Data(contentsOf: resourceURL)
                return try JSONDecoder().decode(Lexicon.self, from: Self.inflate(data))
            }
        }
        let lexicon = try loaded!.get()
        let lemma = lexicon.entries[key] != nil ? key : key.lowercased()
        var matches: [EnglishEntryMatch] = []
        let exact = try senses(lemma, in: lexicon)
        if !exact.isEmpty { matches.append(.init(lemma: lemma, kind: .spelling, senses: exact)) }
        // Preserve a dictionary's explicit capitalization (e.g. US); never stem a proper-name entry.
        if !exact.isEmpty && lemma != lemma.lowercased() { return matches }

        var recorded: [String: Set<String>] = [:]
        for row in lexicon.forms[key] ?? lexicon.forms[key.lowercased()] ?? [] {
            guard row.count == 2 else { throw ReferenceError.unavailable }
            if row[0] != lemma { recorded[row[0], default: []].insert(row[1]) }
        }
        for base in recorded.keys.sorted() {
            let ids = recorded[base]!
            let found = try senses(base, in: lexicon).filter { ids.contains($0.id) }
            guard found.count == ids.count else { throw ReferenceError.unavailable }
            matches.append(.init(lemma: base, kind: .recordedForm, senses: found))
        }
        for (base, parts) in Self.regularCandidates(key.lowercased()).sorted(by: { $0.key < $1.key }) where base != lemma {
            let found = try senses(base, in: lexicon).filter {
                parts.contains($0.partOfSpeech) && !(recorded[base]?.contains($0.id) ?? false)
            }
            if !found.isEmpty { matches.append(.init(lemma: base, kind: .possibleBase, senses: found)) }
        }
        return matches
    }

    private func senses(_ lemma: String, in lexicon: Lexicon) throws -> [EnglishSense] {
        try (lexicon.entries[lemma] ?? []).map { row in
            guard row.count == 2, let definition = lexicon.synsets[row[1]], !definition.definitions.isEmpty else {
                throw ReferenceError.unavailable
            }
            return EnglishSense(id: row[0], synsetID: row[1], partOfSpeech: definition.pos,
                                definition: definition.definitions.joined(separator: "; "), examples: definition.examples)
        }
    }

    /// Limited English suffix candidates, accepted only when an entry with the matching POS exists.
    /// These are possibilities, never proof of morphology or a choice of contextual meaning.
    private static func regularCandidates(_ word: String) -> [String: Set<String>] {
        guard word.count > 2, word.count <= 64, word.utf8.allSatisfy({ (97...122).contains($0) }) else { return [:] }
        var candidates: [String: Set<String>] = [:]
        func add(_ suffix: String, _ replacement: String, _ parts: Set<String>) {
            guard word.hasSuffix(suffix), word.count > suffix.count + 1 else { return }
            candidates[String(word.dropLast(suffix.count)) + replacement, default: []].formUnion(parts)
        }
        if !["ss", "us", "is"].contains(where: word.hasSuffix) { add("s", "", ["n", "v"]) }
        for suffix in ["ses", "xes", "zes", "ches", "shes", "oes"] {
            add(suffix, String(suffix.dropLast(2)), ["n", "v"])
        }
        add("ies", "y", ["n", "v"])
        add("ied", "y", ["v"])
        add("ed", "", ["v"]); add("ed", "e", ["v"])
        add("ing", "", ["v"]); add("ing", "e", ["v"])
        return candidates
    }

    enum ReferenceError: Error { case unavailable }

    /// Gzip is bounded and CRC checked by zlib. Corruption is an unavailable resource, not "no entry".
    static func inflate(_ data: Data) throws -> Data {
        guard data.count <= 8 * 1024 * 1024 else { throw ReferenceError.unavailable }
        return try data.withUnsafeBytes { input in
            var stream = z_stream()
            guard inflateInit2_(&stream, 31, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
                throw ReferenceError.unavailable
            }
            defer { inflateEnd(&stream) }
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(data.count)
            var output = Data(count: 32 * 1024 * 1024)
            let status = output.withUnsafeMutableBytes { buffer in
                stream.next_out = buffer.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(buffer.count)
                return zlib.inflate(&stream, Z_FINISH)
            }
            guard status == Z_STREAM_END, stream.avail_in == 0 else { throw ReferenceError.unavailable }
            output.count = Int(stream.total_out)
            return output
        }
    }

    private struct Lexicon: Decodable {
        let entries: [String: [[String]]]
        let synsets: [String: Definition]
        let forms: [String: [[String]]]
    }

    private struct Definition: Decodable {
        let definitions: [String]
        let examples: [String]
        let pos: String
        init(from decoder: Decoder) throws {
            var values = try decoder.unkeyedContainer()
            definitions = try values.decode([String].self)
            examples = try values.decode([String].self)
            pos = try values.decode(String.self)
            guard values.isAtEnd else { throw ReferenceError.unavailable }
        }
    }
}
