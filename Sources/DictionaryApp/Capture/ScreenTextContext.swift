import Foundation

struct ScreenTextWord {
    let text: String
    let bounds: CGRect
    let range: UTF16Span?

    init(text: String, bounds: CGRect, range: UTF16Span? = nil) {
        self.text = text; self.bounds = bounds; self.range = range
    }
}

struct ScreenTextLine {
    let text: String
    let bounds: CGRect
    let confidence: Float
    let words: [ScreenTextWord]
}

/// OCR is a proposed reading of visible pixels, never an exact native selection.
enum ScreenTextContext {
    static func sentence(target: String, pointer: CGPoint, lines: [ScreenTextLine]) -> String? {
        guard target.range(of: "^[A-Za-z]+(?:['’-][A-Za-z]+)*$", options:.regularExpression) != nil,
              target.utf16.count <= 64, pointer.x.isFinite, pointer.y.isFinite, lines.count <= 200 else { return nil }
        func valid(_ rect: CGRect) -> Bool {
            rect.origin.x.isFinite && rect.origin.y.isFinite && rect.width.isFinite && rect.height.isFinite &&
            rect.width > 0 && rect.height > 0
        }
        let anchors: [(line: Int, range: NSRange)] = lines.indices.flatMap { index -> [(line: Int, range: NSRange)] in
            let line = lines[index]
            guard line.confidence >= 0.85, valid(line.bounds), line.text.utf16.count <= 2000 else { return [] }
            let matches = occurrences(target,in:line.text)
            let words = line.words.filter { $0.text.caseInsensitiveCompare(target) == .orderedSame }
                .sorted { ($0.range?.start ?? 0) < ($1.range?.start ?? 0) }
            guard !matches.isEmpty, words.count == matches.count else { return [] }
            // Every repeated word needs its own validated source range and box.
            // Never bind an occurrence by array order or nearest-pointer guessing.
            for (offset, word) in words.enumerated() {
                let match = matches[offset]
                let span = UTF16Span(start:match.location,end:NSMaxRange(match))
                guard (word.range == span || (words.count == 1 && word.range == nil)),
                      valid(word.bounds), line.bounds.insetBy(dx:-0.5,dy:-0.5).contains(word.bounds),
                      offset == 0 || words[offset-1].bounds.maxX <= word.bounds.minX else { return [] }
            }
            return words.indices.compactMap { offset in
                words[offset].bounds.insetBy(dx:-18,dy:-18).contains(pointer) ? (index,matches[offset]) : nil
            }
        }
        guard anchors.count == 1, let anchor = anchors.first else { return nil }
        let base = lines[anchor.line]
        let column = lines.indices.filter {
            valid(lines[$0].bounds) && abs(lines[$0].bounds.minX-base.bounds.minX) < base.bounds.height * 2
        }.sorted { lines[$0].bounds.minY < lines[$1].bounds.minY }
        guard let position = column.firstIndex(of:anchor.line) else { return nil }
        func adjacent(_ a:Int,_ b:Int) -> Bool {
            let gap = lines[b].bounds.minY-lines[a].bounds.maxY
            return gap >= -2 && gap <= max(lines[a].bounds.height,lines[b].bounds.height)*0.8
        }
        var start=position, end=position
        while start > 0 && adjacent(column[start-1],column[start]) { start -= 1 }
        while end+1 < column.count && adjacent(column[end],column[end+1]) { end += 1 }
        let paragraph = column[start...end]
        guard paragraph.count <= 12, paragraph.allSatisfy({ lines[$0].confidence >= 0.85 }),
              paragraph.reduce(0,{ $0 + lines[$1].text.utf16.count + 1 }) <= 2000 else { return nil }
        let text = paragraph.map { lines[$0].text }.joined(separator:" ")
        let prefix = paragraph.prefix(while: { $0 != anchor.line }).reduce(0) { $0+lines[$1].text.utf16.count+1 }
        let selected = NSRange(location:prefix+anchor.range.location,length:anchor.range.length)
        var sentence: String?
        (text as NSString).enumerateSubstrings(in:NSRange(location:0,length:text.utf16.count), options:.bySentences) { raw,range,_,_ in
            guard range.location <= selected.location, NSMaxRange(range) >= NSMaxRange(selected), let raw else { return }
            let candidate=SelectionLocation.trim(raw)
            guard occurrences(target,in:candidate).count == 1,
                  candidate.range(of:"^[\"“'‘(]*[A-Z]",options:.regularExpression) != nil,
                  candidate.range(of:"[.!?][\"'”’)\\]]*$",options:.regularExpression) != nil else { return }
            sentence=candidate
        }
        return sentence
    }

    static func occurrences(_ target:String,in text:String) -> [NSRange] {
        let pattern="(?<![\\p{L}\\p{M}\\p{N}_])"+NSRegularExpression.escapedPattern(for:target)+"(?![\\p{L}\\p{M}\\p{N}_])"
        guard let regex=try? NSRegularExpression(pattern:pattern,options:.caseInsensitive) else { return [] }
        return regex.matches(in:text,range:NSRange(location:0,length:text.utf16.count)).map(\.range)
    }
}
