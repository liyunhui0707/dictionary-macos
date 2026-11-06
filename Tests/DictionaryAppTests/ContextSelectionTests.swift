import ApplicationServices
import Foundation
import Testing
@testable import DictionaryApp

struct ContextSelectionTests {
    private let sentence="We sat on the bank of the river."

    @Test func onlyCompleteKnownTreesCanSupplyHeuristicContext() throws {
        let complete=graph([.group([1,2]),.text(sentence),.group([])]).extractReport()
        #expect(complete.captured?.capture?.reliability == .heuristic)
        #expect(complete.captured?.capture?.range == nil)
        #expect(complete.captured?.containingSentence == sentence)
        let valueLeaf=graph([AXNode(role:"AXTextArea",value:sentence,children:[])]).extractReport().captured
        #expect(valueLeaf?.capture?.reliability == .heuristic && valueLeaf?.containingSentence == sentence)
        for nodes in [[AXNode(role:"AXGroup",value:sentence,children:nil)],
                      [.group([1,2]),.text(sentence),AXNode(role:"AXStaticText",value:nil,children:nil)],
                      [.group([1,0]),.text(sentence)],
                      [.group([1,2]),.text(sentence),AXNode(role:"AXTextArea",value:nil,children:[])]] {
            let capture=try #require(graph(nodes).extractReport().captured)
            #expect(capture.target == "bank" && capture.context == "bank")
            #expect(capture.containingSentence == nil && capture.capture?.reliability == .targetOnly)
        }
    }

    @Test func prefixWordsNeverEstablishTheSelectedOccurrence() {
        let onlyPrefix=graph([.text("The bankruptcy hearing ended.")]).extractReport().captured
        #expect(onlyPrefix?.capture?.reliability == .targetOnly)
        let unique=graph([.text("The bankruptcy hearing ended. We sat on the bank of the river.")]).extractReport().captured
        #expect(unique?.capture?.reliability == .heuristic)
        #expect(unique?.containingSentence == sentence)
        let duplicate=graph([.text("The bank closed. We sat on the bank.")]).extractReport().captured
        #expect(duplicate?.capture?.reason == .ambiguousOccurrence)
    }

    @Test func depthNodeAndUTF16StopsNeverProveUniquenessFromAPrefix() {
        let chain=(0..<27).map { AXNode.group([$0+1]) } + [.text(sentence)]
        let many=[AXNode.group(Array(1...4001)),.text(sentence)] + Array(repeating:.text(""),count:4000)
        for nodes in [chain,many,[AXNode.text(sentence + String(repeating:"🌊",count:4000))]] {
            let captured=graph(nodes).extractReport().captured
            #expect(captured?.capture?.reliability == .targetOnly)
            #expect(captured?.context == "bank" && captured?.containingSentence == nil)
            #expect(captured?.capture?.method == .axTreeWalk && captured?.capture?.reason == .budgetExceeded)
        }
    }

    @Test func separatorsAreIncludedInTheRawCollectionBudget() {
        let first=sentence + String(repeating:" ",count:3999-sentence.utf16.count)
        for (last,quality) in [(4000,CaptureReliability.heuristic),(4001,.targetOnly)] {
            let captured=graph([.group([1,2]),.text(first),.text(String(repeating:" ",count:last))]).extractReport().captured
            #expect(captured?.capture?.reliability == quality)
            #expect(captured?.capture?.method == .axTreeWalk)
            #expect(captured?.capture?.reason == (quality == .heuristic ? nil : .budgetExceeded))
        }
    }

    // B1-M1: completion and actual work stops are separate from a counter reaching zero.
    @Test func reviewTreeFallbackMethodAndStopReasons() throws {
        let deep=(0..<26).map { AXNode.group([$0+1]) } + [.text("No selected word here.")]
        let cases: [([AXNode], CaptureReason)] = [
            ([.text("The bank closed." + String(repeating:"x",count:8001))], .budgetExceeded),
            ([.text("The bank closed. We sat on the bank.")], .ambiguousOccurrence),
            ([.text("No selected word here.")], .contextUnavailable),
            ([.group([1]), AXNode(role:"AXStaticText",value:nil,children:nil)], .incompleteTraversal),
            ([AXNode(role:"AXGroup",value:nil,children:nil)], .incompleteTraversal),
            ([.group([0])], .incompleteTraversal),
            ([.group([1,2]),.text(String(repeating:"x",count:8000)),AXNode(role:"AXStaticText",value:nil,children:nil)], .incompleteTraversal),
            (deep, .budgetExceeded),
            ([.group(Array(1...4000))] + Array(repeating:.text(""),count:4000), .budgetExceeded),
            ([AXNode(role:"AXTextArea",value:String(repeating:"x",count:8001),children:[])], .budgetExceeded)]
        for (nodes, reason) in cases {
            let captured=try #require(graph(nodes).extractReport().captured)
            #expect(captured.capture?.method == .axTreeWalk)
            #expect(captured.capture?.reason == reason)
            #expect(captured.capture?.reliability == .targetOnly)
            #expect(captured.capture?.range == nil && captured.containingSentence == nil)
        }
    }

    @Test func reviewExactlyCompletedBudgetsAreNotReportedAsStops() throws {
        let exactNodes=[AXNode.group(Array(1...3999))] + Array(repeating:.text(""),count:3999)
        let exactDepth=(0..<25).map { AXNode.group([$0+1]) } + [.text("No selected word here.")]
        let exactHops=(0..<12).map { AXNode(role:"AXGroup",value:nil,children:[],parent:$0 == 11 ? nil : $0+1) }
        for nodes in [[AXNode.text(String(repeating:"x",count:8000))], exactNodes, exactDepth, exactHops] {
            let captured=try #require(graph(nodes).extractReport().captured)
            #expect(captured.capture?.method == .axTreeWalk)
            #expect(captured.capture?.reason == .contextUnavailable)
        }
        let tooManyHops=(0..<13).map { AXNode(role:"AXGroup",value:nil,children:[],parent:$0 == 12 ? nil : $0+1) }
        let stopped=try #require(graph(tooManyHops).extractReport().captured)
        #expect(stopped.capture?.method == .axTreeWalk && stopped.capture?.reason == .budgetExceeded)
        let cycle=[AXNode(role:"AXGroup",value:nil,children:[],parent:1),AXNode(role:"AXGroup",value:nil,children:[],parent:0)]
        #expect(graph(cycle).extractReport().captured?.capture?.reason == .incompleteTraversal)
    }

    @Test func reviewAXRangeMethodIsPreservedOnItsOwnPaths() throws {
        for (start,quality,reason) in [(14,CaptureReliability.anchored,nil as CaptureReason?), (0,.targetOnly,.rangeMismatch)] {
            let captured=try #require(graph([.text(sentence)],range:NSRange(location:start,length:4)).extractReport().captured)
            #expect(captured.capture?.method == .axRange)
            #expect(captured.capture?.reliability == quality && captured.capture?.reason == reason)
        }
    }

    @MainActor @Test func reviewTraversalReasonSurvivesDiagnosticsWithoutSourceOrCopy() async throws {
        let secret="PRIVATE_REMEDIATION_SOURCE"
        for (value,reason) in [(secret + String(repeating:"x",count:8001),CaptureReason.budgetExceeded),
                               ("No selected word here.",.contextUnavailable),(nil as String?,.incompleteTraversal)] {
            let report=graph([AXNode(role:"AXStaticText",value:value,children:nil)]).extractReport()
            let pipeline=NativeCapturePipeline(isTrusted:{true},safari:{nil},ax:{report},clipboard:{
                Issue.record("Readable AX target must not invoke copy")
                return ClipboardCapture(text:nil,failure:.unchanged)
            })
            let captured=try await pipeline.capture(isSafari:false)
            #expect(captured.capture?.method == .axTreeWalk && captured.capture?.reason == reason)
            #expect(captured.diagnostics.reason == reason && captured.diagnostics.reliability == .targetOnly)
            #expect(captured.diagnostics.strategy == .axSelectionOnly)
            if value == nil { #expect(captured.diagnostics.issues.contains { $0.code == .axCallFailed && $0.attribute == .value }) }
            let encoded=String(decoding:try JSONEncoder().encode(captured.diagnostics),as:UTF8.self)
            #expect(!encoded.contains(secret) && !encoded.contains("bank") && !encoded.contains("range"))
        }
    }

    private func graph(_ nodes: [AXNode], range: NSRange? = nil) -> ContextExtractor {
        let elements=nodes.indices.map { AXUIElementCreateApplication(Int32(10000+$0)) }
        let byHash=Dictionary(uniqueKeysWithValues:elements.enumerated().map { (CFHash($0.element),$0.offset) })
        return ContextExtractor(readAttribute:{ element,attribute in
            switch attribute {
            case .focusedApplication,.focusedUIElement: return .value(elements[0])
            case .selectedText: return .value("bank" as CFString)
            case .selectedTextRange:
                guard let range else { return .failure(.attributeUnsupported) }
                var span=CFRange(location:range.location,length:range.length)
                return .value(AXValueCreate(.cfRange,&span)!)
            default: break
            }
            guard let i=byHash[CFHash(element)] else { return .failure(.attributeUnsupported) }
            let n=nodes[i]
            switch attribute {
            case .role: return n.role.map { .value($0 as CFString) } ?? .failure(.attributeUnsupported)
            case .value: return n.value.map { .value($0 as CFString) } ?? .failure(.cannotComplete)
            case .parent: return n.parent.map { .value(elements[$0]) } ?? .failure(.attributeUnsupported)
            case .children: return n.children.map { .value($0.map { elements[$0] } as CFArray) } ?? .failure(.attributeUnsupported)
            default: return .failure(.attributeUnsupported)
            }
        })
    }
}

private struct AXNode {
    let role:String?
    let value:String?
    let children:[Int]?
    var parent:Int? = nil
    static func group(_ children:[Int]) -> Self { .init(role:"AXGroup",value:nil,children:children) }
    static func text(_ value:String) -> Self { .init(role:"AXStaticText",value:value,children:nil) }
}
