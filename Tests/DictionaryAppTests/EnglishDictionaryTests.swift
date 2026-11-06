import Foundation
import SwiftUI
import Testing
@testable import DictionaryApp

struct EnglishDictionaryTests {
    @MainActor @Test func referenceIsPresentWhileWaitingAndInEveryFinishedOutcome() throws {
        let request = try LookupRequest.manual(target: "bank", context: "")
        let translation = Translation(meaningInContext: "银行", literalGloss: nil, partOfSpeech: nil,
                                      exampleTranslation: nil, alternatives: nil)
        for layout in [LookupResultView.Layout.standard, .popup] {
            #expect(referenceTargets(in: LookupResultView(phase: .idle, layout: layout).body).isEmpty)
            for phase in [LookupPhase.loading(request),
                          .finished(request, .success(LookupResult(request: request, translation: translation))),
                          .finished(request, .failure("Synthetic error", rawOutput: nil)),
                          .finished(request, .cancelled)] {
                let view = LookupResultView(phase: phase, layout: layout)
                #expect(referenceTargets(in: view.body) == ["bank"])
            }
            let next = try LookupRequest.manual(target: "apple", context: "")
            #expect(referenceTargets(in: LookupResultView(phase: .loading(next), layout: layout).body) == ["apple"])
        }
    }

    @MainActor @Test func localReferenceDoesNotWaitForOrResubmitTheProvider() async throws {
        let provider = ControlledProvider()
        let coordinator = LookupCoordinator(provider: provider)
        let operation = coordinator.submit(try .manual(target: "bank", context: ""), to: .selection)
        let call = await provider.waitForCall("bank")
        let target = try #require(referenceTargets(in: LookupResultView(phase: coordinator.selection, layout: .popup).body).first)
        let reference = EnglishReferenceState()
        reference.expanded = true
        await reference.load(target: target)
        #expect(reference.senses?.contains { $0.id == "bank%1:17:01::" } == true)
        #expect(coordinator.selection.isLoading)
        #expect(await provider.calls.count == 1)
        coordinator.dismissSelection()
        #expect(await operation.value.isCancelled)
        await provider.succeed(call)
        await operation.providerTask?.value
        guard case .idle = coordinator.selection else { Issue.record("Late result restored dismissed lookup"); return }
    }

    // Inspect the constructed view values, without opening a window or evaluating StateObject.
    // This checks placement in both production layouts, not desktop interaction or appearance.
    @MainActor private func referenceTargets(in value: Any, depth: Int = 0) -> [String] {
        if let reference = value as? EnglishDictionaryReferenceView { return [reference.target] }
        guard depth < 30 else { return [] }
        return Mirror(reflecting: value).children.flatMap { referenceTargets(in: $0.value, depth: depth + 1) }
    }

    @Test func bankHasRealDistinctSensesAndExamples() async throws {
        let result = try await EnglishDictionary.shared.lookup("bank")
        #expect(result.count == 18)
        let river = try #require(result.first { $0.id == "bank%1:17:01::" })
        let finance = try #require(result.first { $0.id == "bank%1:14:00::" })
        #expect(river.definition.contains("body of water"))
        #expect(finance.definition.contains("financial institution"))
        #expect(river.synsetID == "09236472-n")
        #expect(!river.examples.isEmpty)
        #expect(Set(result.map(\.id)).count == result.count)
    }

    @Test func generalLookupIsNotABankFixtureAndDoesNotInventMissingEntries() async throws {
        for word in ["apple", "run", "interest", "computer", "kick the bucket"] {
            #expect(try await !EnglishDictionary.shared.lookup(word).isEmpty)
        }
        let normalized = try await EnglishDictionary.shared.lookup(" BANK \n")
        let bank = try await EnglishDictionary.shared.lookup("bank")
        #expect(normalized == bank)
        for word in ["", "nonexistentxyzzydictionary", "bank of the river xyzzy", "../../bank"] {
            #expect(try await EnglishDictionary.shared.lookup(word).isEmpty)
        }
    }

    @Test func brokenResourceIsUnavailableRatherThanAMissingEntry() async {
        let dictionary = EnglishDictionary(resourceURL: URL(fileURLWithPath: "/nonexistent-oewn-test-resource"))
        do {
            _ = try await dictionary.lookup("bank")
            Issue.record("Missing dictionary resource was accepted")
        } catch {}
    }

    @Test func gzipCorruptionAndTrailingBytesAreRejected() throws {
        let url = try #require(EnglishDictionary.bundledResourceURL)
        let good = try Data(contentsOf: url)
        for bytes in [Data(), Data(good.prefix(100)), good + Data([0]), Data(repeating: 0, count: 8 * 1024 * 1024 + 1)] {
            #expect(throws: (any Error).self) { try EnglishDictionary.inflate(bytes) }
        }
    }

    @Test func installedResourceLookupWorksOutsideTheDevelopmentTree() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dictionary-resource-\(UUID().uuidString)")
        let resources = root.appendingPathComponent("Dictionary.app/Contents/Resources")
        #expect(EnglishDictionary.packagedResource(in: resources) == nil)
        for layout in ["Contents/Resources", ""] {
            let directory = resources.appendingPathComponent(layout.isEmpty ? "native" : "xcode")
            let destination = directory.appendingPathComponent(EnglishDictionary.bundleName)
                .appendingPathComponent(layout).appendingPathComponent("EnglishDictionary/oewn-2025.json.gz")
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: #require(EnglishDictionary.bundledResourceURL), to: destination)
            let found = try #require(EnglishDictionary.packagedResource(in: directory))
            #expect(found == destination)
            #expect(try await EnglishDictionary(resourceURL: found).lookup("bank").count == 18)
        }
        // Test-owned copy retained; no installed App or user resource is touched.
    }

    @MainActor @Test func disclosureLoadsOnlyOnDemandAndLimitsVisibleSenses() async {
        let state = EnglishReferenceState()
        let expansion = EnglishSenseExpansion()
        #expect(!state.expanded && !expansion.showAll && state.senses == nil)
        await state.load(target: "bank")
        #expect(state.senses == nil)
        state.expanded = true
        await state.load(target: "bank")
        #expect(state.senses?.count == 18 && expansion.visibleSenses(in: state.senses ?? []).count == 4)
        expansion.showAll = true
        #expect(expansion.visibleSenses(in: state.senses ?? []).count == 18)
        #expect(!state.unavailable)
    }

    @MainActor @Test func noEntryAndUnavailableHaveDifferentStates() async {
        let missing = EnglishReferenceState()
        missing.expanded = true
        await missing.load(target: "nonexistentxyzzydictionary")
        #expect(missing.senses == [] && !missing.unavailable)
        let broken = EnglishReferenceState()
        broken.expanded = true
        await broken.load(target: "bank", dictionary: EnglishDictionary(resourceURL: nil))
        #expect(broken.senses == nil && broken.unavailable)
    }

    @Test func dictionaryDoesNotChangeAIOrRestoreRejectedSentences() async throws {
        let source = "We sat on the bank of the river."
        let translation = Translation(meaningInContext: "银行", literalGloss: nil, partOfSpeech: nil,
                                      exampleTranslation: "REJECTED", alternatives: nil)
        for location in [captureMetadata(start: 14, end: 18, reason: .sentenceUnavailable),
                         SelectionLocation(reliability: .targetOnly, method: .clipboard)] {
            let request = LookupRequest(target: "bank", context: source, containingSentence: source,
                                        source: "Synthetic", capture: location)
            #expect(try await !EnglishDictionary.shared.lookup(request.target).isEmpty)
            let presentation = LookupResultPresentation(request: request, translation: translation)
            #expect(presentation.sentence == nil && presentation.sentenceTranslation == nil)
            #expect(translation.meaningInContext == "银行")
        }
    }
}

struct EnglishMorphologyTests {
    @Test func referenceSensesAreUniqueAndMultipleOriginalEntriesAreRetained() async throws {
        for word in ["charged", "running", "axes", "children", "went", "agorae", "torn", "wound"] {
            let matches = try await EnglishDictionary.shared.lookupEntries(word)
            #expect(Set(matches.map(\.id)).count == matches.count)
            let ids = matches.flatMap(\.senses).map(\.id)
            #expect(Set(ids).count == ids.count)
        }
        let entries = try await EnglishDictionary.shared.lookupEntries("agorae")
        let agora = try #require(entries.first { $0.lemma == "agora" && $0.kind == .recordedForm })
        #expect(agora.senses.count == 3)
        #expect(agora.senses.contains { $0.id == "agora%1:23:00::" })
        #expect(agora.senses.contains { $0.id == "agora%1:15:00::" })
    }

    @Test func retainsExactAdjectiveAndOffersOnlyRealVerbSensesForCharged() async throws {
        let matches = try await EnglishDictionary.shared.lookupEntries("charged")
        let exact = try #require(matches.first)
        #expect(exact.lemma == "charged" && exact.kind == .spelling)
        #expect(exact.senses.count == 4)
        let base = try #require(matches.first { $0.lemma == "charge" })
        #expect(base.kind == .possibleBase)
        #expect(base.senses.count == 25)
        #expect(base.senses.allSatisfy { $0.partOfSpeech == "v" })
        #expect(base.senses.contains { $0.definition.contains("electric") })
    }

    @Test func dictionaryRecordedIrregularFormsKeepTheirPartOfSpeech() async throws {
        for (form, lemma, pos) in [("children", "child", "n"), ("went", "go", "v"), ("mice", "mouse", "n"), ("ran", "run", "v")] {
            let matches = try await EnglishDictionary.shared.lookupEntries(form)
            let base = try #require(matches.first { $0.lemma == lemma && $0.kind == .recordedForm })
            #expect(!base.senses.isEmpty)
            #expect(base.senses.allSatisfy { $0.partOfSpeech == pos })
        }
        let running = try await EnglishDictionary.shared.lookupEntries("running")
        #expect(running.first?.lemma == "running" && running.first?.kind == .spelling)
        #expect(running.contains { $0.lemma == "run" && $0.kind == .recordedForm })
    }

    @Test func regularCandidatesAreReferencesNotContextualDecisions() async throws {
        for (form, lemma) in [("banks", "bank"), ("walked", "walk"), ("studies", "study")] {
            let matches = try await EnglishDictionary.shared.lookupEntries(form)
            #expect(matches.contains { $0.lemma == lemma && $0.kind == .possibleBase })
        }
        let axes = try await EnglishDictionary.shared.lookupEntries("axes")
        #expect(axes.contains { $0.lemma == "axis" && $0.kind == .recordedForm })
        #expect(axes.contains { $0.lemma == "axe" })
        #expect(axes.contains { $0.lemma == "ax" })
        let bank = try await EnglishDictionary.shared.lookupEntries(" BANK \n")
        #expect(bank.count == 1 && bank.first?.kind == .spelling)
        #expect(bank.first?.senses.count == 18)
        #expect(try await EnglishDictionary.shared.lookupEntries("US").allSatisfy { $0.kind == .spelling })
        for absent in ["zyxqvexamples", "bank of the rivers", "../../banks", ""] {
            #expect(try await EnglishDictionary.shared.lookupEntries(absent).isEmpty)
        }
    }

    @MainActor @Test func referenceStateExposesBaseLabelsAndPreservesHonestMissingState() async throws {
        let state = EnglishReferenceState()
        state.expanded = true
        await state.load(target: "charged")
        #expect(state.matches?.first?.lemma == "charged")
        #expect(state.matches?.contains { $0.lemma == "charge" && $0.kind == .possibleBase } == true)
        let missing = EnglishReferenceState()
        missing.expanded = true
        await missing.load(target: "zyxqvexample")
        #expect(missing.matches == [] && !missing.unavailable)
    }
}
