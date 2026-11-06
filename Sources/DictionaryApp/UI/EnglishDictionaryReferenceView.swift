import SwiftUI

/// This disclosure is independent of Translation and cannot promote a rejected source sentence.
struct EnglishDictionaryReferenceView: View {
    let target: String
    @StateObject private var reference: EnglishReferenceState

    init(target: String, reference: EnglishReferenceState? = nil) {
        self.target = target
        _reference = StateObject(wrappedValue: reference ?? EnglishReferenceState())
    }

    var body: some View {
        DisclosureGroup("英文词典参考", isExpanded: $reference.expanded) {
            VStack(alignment: .leading, spacing: 10) {
                Text("真实英文义项，供你核对；未自动匹配当前语境。")
                    .font(.system(size: 12)).foregroundStyle(DictionaryStyle.secondary)
                if reference.unavailable {
                    Text("暂时无法打开词典参考。")
                } else if let matches = reference.matches {
                    if matches.isEmpty {
                        Text("OEWN 2025 未找到此拼写或支持的原形。未收录不代表这个词不存在。")
                    } else {
                        ForEach(matches) { match in
                            if match.kind == .spelling {
                                Text(match.label).font(.system(size: 12)).foregroundStyle(DictionaryStyle.secondary)
                                EnglishSenseList(senses: match.senses)
                            } else {
                                DisclosureGroup(match.label) {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text(match.kind == .recordedForm ?
                                             "词典记录了这一词形关系；未判断它是否适用于当前语境。" :
                                             "依据常见词形规则找到的词典条目，未确认是当前词的原形。")
                                            .font(.system(size: 12)).foregroundStyle(DictionaryStyle.secondary)
                                        EnglishSenseList(senses: match.senses)
                                    }.padding(.top, 6)
                                }
                            }
                        }
                    }
                } else {
                    Text("正在打开本地词典…").foregroundStyle(DictionaryStyle.secondary)
                }
                Text("Open English Wordnet 2025 · OEWN team & Princeton WordNet。英文精简数据，不含中文词典释义。")
                    .font(.system(size: 12)).foregroundStyle(DictionaryStyle.secondary)
                HStack {
                    Link("来源", destination: URL(string: "https://github.com/globalwordnet/english-wordnet/releases/tag/2025-edition")!)
                    Link("许可与署名", destination: URL(string: "https://github.com/globalwordnet/english-wordnet/blob/2025-edition/LICENSE.md")!)
                }.font(.system(size: 12))
            }
            .font(.system(size: 13)).padding(.top, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 12))
        .task(id: reference.expanded) {
            await reference.load(target: target)
        }
    }

}

private struct EnglishSenseList: View {
    let senses: [EnglishSense]
    @StateObject private var expansion = EnglishSenseExpansion()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(senses.count) 个义项").font(.system(size: 12)).foregroundStyle(DictionaryStyle.secondary)
            ForEach(expansion.visibleSenses(in: senses)) { sense in
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(sense.definition)
                        ForEach(Array(sense.examples.prefix(2).enumerated()), id: \.offset) { _, example in
                            Text("词典例句：\(example)").foregroundStyle(DictionaryStyle.secondary)
                        }
                        DisclosureGroup("条目编号") {
                            Text("Sense: \(sense.id) · Synset: \(sense.synsetID)")
                        }.font(.system(size: 11)).foregroundStyle(DictionaryStyle.secondary)
                    }.padding(.vertical, 4)
                } label: {
                    Text("\(partOfSpeech(sense.partOfSpeech)) · \(sense.definition)").lineLimit(2)
                }
            }
            if senses.count > 4 {
                Button(expansion.showAll ? "收起更多义项" : "查看全部 \(senses.count) 个义项") { expansion.showAll.toggle() }
                    .buttonStyle(.link)
            }
        }
    }

    private func partOfSpeech(_ value: String) -> String {
        switch value {
        case "n": return "noun"
        case "v": return "verb"
        case "a", "s": return "adjective"
        case "r": return "adverb"
        default: return value
        }
    }
}

@MainActor
final class EnglishSenseExpansion: ObservableObject {
    @Published var showAll = false
    func visibleSenses(in senses: [EnglishSense]) -> [EnglishSense] { showAll ? senses : Array(senses.prefix(4)) }
}

/// Per-result disclosure state. Does not own or edit the model answer or source evidence.
@MainActor
final class EnglishReferenceState: ObservableObject {
    @Published var expanded = false
    @Published private(set) var matches: [EnglishEntryMatch]?
    var senses: [EnglishSense]? { matches.map { $0.flatMap(\.senses) } }
    @Published private(set) var unavailable = false

    func load(target: String, dictionary: EnglishDictionary = .shared) async {
        guard expanded, senses == nil, !unavailable else { return }
        do {
            let result = try await dictionary.lookupEntries(target)
            guard !Task.isCancelled else { return }
            matches = result
        } catch {
            if !Task.isCancelled { unavailable = true }
        }
    }
}
