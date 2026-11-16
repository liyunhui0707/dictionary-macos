import Foundation
import Testing
@testable import DictionaryApp

@MainActor
struct BooksScreenFallbackTests {
    private let targetOnly = CapturedContext(target:"bank",context:"bank",containingSentence:nil,
        capture:.init(reliability:.targetOnly,method:.clipboard,reason:.contextUnavailable))
    private func frame(_ value:UInt8=1) -> BooksScreenSnapshot {
        .init(windowID:12,windowBounds:CGRect(x:0,y:0,width:900,height:600),
              region:CGRect(x:0,y:0,width:800,height:360),pointer:CGPoint(x:195,y:20),digest:Data([value]),image:nil)
    }
    private var lines:[ScreenTextLine] {
        [.init(text:"They walked along the bank of the river.",bounds:CGRect(x:10,y:10,width:500,height:20),
               confidence:0.99,words:[.init(text:"bank",bounds:CGRect(x:180,y:10,width:40,height:20))])]
    }
    @Test func recognitionBeyondThreeSecondsCanStillReachReviewWithinTheCaptureBudget() async throws {
        var time: TimeInterval = 10
        var snapshots = 0
        var suppliedBudget: TimeInterval = 0
        let result = try await BooksScreenFallback.capture(enabled: true, isBooks: true, permission: true,
            nativeHasSentence: false, isCurrent: { true },
            snapshot: { snapshots += 1; time += 0.25; return frame() },
            native: { time += 0.5; return targetOnly },
            recognize: { _, _, budget in
                suppliedBudget = budget
                let work: TimeInterval = 3.5
                time += min(work, budget)
                return budget >= work ? .recognized(lines) : .timedOut
            }, now: { time })
        #expect(suppliedBudget >= 3.5 && suppliedBudget <= 4)
        #expect(result.containingSentence == lines[0].text && result.diagnostics.screenContext == .needsConfirmation)
        #expect(snapshots == 3 && time < 18)
        #expect(result.diagnostics.screenRecognitionBudgetMilliseconds == 4000)
        #expect(result.diagnostics.screenRecognitionElapsedMilliseconds == 3500)
    }

    @Test func spentCaptureBudgetPreservesNativeTextWithoutStartingRecognition() async throws {
        var time: TimeInterval = 0
        var recognitionCalls = 0
        let result = try await BooksScreenFallback.capture(enabled: true, isBooks: true, permission: true,
            nativeHasSentence: false, isCurrent: { true }, snapshot: { frame() },
            native: { time = 8; return targetOnly },
            recognize: { _, _, _ in recognitionCalls += 1; return .recognized(lines) }, now: { time })
        #expect(recognitionCalls == 0)
        #expect(result.target == targetOnly.target && result.containingSentence == nil)
        #expect(result.diagnostics.screenContext == .timedOut)
        #expect(result.diagnostics.screenRecognitionBudgetMilliseconds == nil)
        #expect(result.diagnostics.screenRecognitionElapsedMilliseconds == nil)
    }

    @Test func quickRecognitionNearTheDeadlineKeepsItsExistingRecoveryPath() async throws {
        var time: TimeInterval = 0
        var budgetSeen: TimeInterval = 0
        let result = try await BooksScreenFallback.capture(enabled: true, isBooks: true, permission: true,
            nativeHasSentence: false, isCurrent: { true }, snapshot: { frame() },
            native: { time = 6.5; return targetOnly }, recognize: { _, _, budget in
                budgetSeen = budget
                time += 0.1
                return .recognized(lines)
            }, now: { time })
        #expect(budgetSeen > 0 && budgetSeen <= 1.5)
        #expect(result.containingSentence == lines[0].text && result.diagnostics.screenContext == .needsConfirmation)
    }

    @Test(arguments: ["source", "cancel"])
    func sourceChangeOrCancellationAfterSnapshotDoesNotStartRecognition(change: String) async throws {
        var snapshots = 0
        var current = true
        var recognitionCalls = 0
        let task = Task {
            try await BooksScreenFallback.capture(enabled: true, isBooks: true, permission: true,
                nativeHasSentence: false, isCurrent: { current }, snapshot: {
                    snapshots += 1
                    if snapshots == 2 {
                        if change == "source" { current = false }
                        else { withUnsafeCurrentTask { $0?.cancel() } }
                    }
                    return frame()
                }, native: { targetOnly }, recognize: { _, _, _ in
                    recognitionCalls += 1
                    return .recognized(lines)
                })
        }
        let result = try await task.value
        #expect(recognitionCalls == 0 && result.containingSentence == nil)
        #expect(result.diagnostics.screenContext == .sourceChanged)
    }

    @Test(arguments: ["recognition", "finalPixels"])
    func expiredCaptureCannotPresentEvenAValidLateSentence(phase: String) async throws {
        var time: TimeInterval = 0
        var snapshots = 0
        let result = try await BooksScreenFallback.capture(enabled: true, isBooks: true, permission: true,
            nativeHasSentence: false, isCurrent: { true },
            snapshot: { snapshots += 1; if snapshots == 3 { time = 8 }; return frame() },
            native: { targetOnly }, recognize: { _, _, _ in
                if phase == "recognition" { time = 8 }
                return .recognized(lines)
            }, now: { time })
        #expect(result.containingSentence == nil && result.context == targetOnly.context)
        #expect(result.diagnostics.screenContext == .timedOut)
        #expect(snapshots == (phase == "recognition" ? 2 : 3))
    }

    @Test func stableWindowRecoversOnlyAReviewableHeuristicSentence() async throws {
        var snapshots=0, copies=0
        let result=try await BooksScreenFallback.capture(enabled:true,isBooks:true,permission:true,nativeHasSentence:false,
            isCurrent:{ true },snapshot:{ snapshots+=1; return frame() },native:{ copies+=1; return targetOnly },
            recognize:{ _,_,_ in .recognized(lines) })
        #expect(snapshots==3 && copies==1)
        #expect(result.context==lines[0].text && result.capture?.method == .screenOCR)
        #expect(result.capture?.reliability == .heuristic && result.capture?.range == nil)
        #expect(result.diagnostics.screenContext == .needsConfirmation)
        let metadata=String(decoding:try JSONEncoder().encode(result.diagnostics),as:UTF8.self)
        #expect(!metadata.contains("bank") && !metadata.contains("river"))
    }
    @Test(arguments:["disabled","otherApp","permission","nativeContext"])
    func unavailableOrUnneededFallbackNeverReadsPixels(mode:String) async throws {
        var snapshots=0
        let result=try await BooksScreenFallback.capture(enabled:mode != "disabled",isBooks:mode != "otherApp",
            permission:mode != "permission",nativeHasSentence:mode == "nativeContext",isCurrent:{true},
            snapshot:{snapshots+=1;return frame()},native:{targetOnly},recognize:{ _,_,_ in Issue.record("Unexpected OCR");return .recognized([]) })
        #expect(snapshots==0 && result.capture?.reliability == .targetOnly)
    }
    @Test(arguments:[2,3])
    func pageChangeBeforeOrAfterRecognitionDiscardsPixels(changedAt:Int) async throws {
        var snapshots=0
        let result=try await BooksScreenFallback.capture(enabled:true,isBooks:true,permission:true,nativeHasSentence:false,
            isCurrent:{true},snapshot:{snapshots+=1;return frame(snapshots>=changedAt ? 2:1)},
            native:{targetOnly},recognize:{ _,_,_ in .recognized(lines)})
        #expect(result.context=="bank" && result.containingSentence==nil)
    }
    @Test func sourceChangeCannotAttachAScreenSentence() async throws {
        var current=true
        let result=try await BooksScreenFallback.capture(enabled:true,isBooks:true,permission:true,nativeHasSentence:false,
            isCurrent:{current},snapshot:{frame()},native:{targetOnly},recognize:{ _,_,_ in current=false;return .recognized(lines)})
        #expect(result.context=="bank" && result.containingSentence==nil)
    }
    @Test(arguments:["window","bounds","region","pointer"])
    func changedWindowGeometryOrPointerCannotReusePixels(change:String) async throws {
        var count=0
        let initial=frame()
        let other=BooksScreenSnapshot(windowID:change == "window" ? 13:initial.windowID,
            windowBounds:change == "bounds" ? initial.windowBounds.offsetBy(dx:1,dy:0):initial.windowBounds,
            region:change == "region" ? initial.region.offsetBy(dx:1,dy:0):initial.region,
            pointer:change == "pointer" ? CGPoint(x:196,y:20):initial.pointer,digest:initial.digest,image:nil)
        let result=try await BooksScreenFallback.capture(enabled:true,isBooks:true,permission:true,nativeHasSentence:false,
            isCurrent:{true},snapshot:{count+=1;return count==1 ? initial:other},native:{targetOnly},recognize:{ _,_,_ in .recognized(lines)})
        #expect(result.context=="bank" && result.containingSentence==nil)
    }
    @Test func nativeSuccessAlwaysWinsWithoutOCR() async throws {
        let native=CapturedContext(target:"bank",context:lines[0].text,containingSentence:lines[0].text,
            capture:.init(reliability:.heuristic,method:.axTreeWalk))
        var snapshots=0
        let result=try await BooksScreenFallback.capture(enabled:true,isBooks:true,permission:true,nativeHasSentence:false,
            isCurrent:{true},snapshot:{snapshots+=1;return frame()},native:{native},
            recognize:{ _,_,_ in Issue.record("Unexpected OCR");return .recognized([])})
        #expect(snapshots==1 && result.capture?.method == .axTreeWalk)
    }
    @Test func paragraphWithoutConfirmedSentenceCanOfferScreenPreview() async throws {
        var paragraph=CapturedContext(target:"bank",context:"They walked along the bank of the river.",containingSentence:nil,
            capture:.init(reliability:.heuristic,method:.axRange,reason:.sentenceUnavailable))
        paragraph.diagnostics.includeQuality(paragraph.capture)
        let result=try await BooksScreenFallback.capture(enabled:true,isBooks:true,permission:true,nativeHasSentence:false,
            isCurrent:{true},snapshot:{frame()},native:{paragraph},recognize:{ _,_,_ in .recognized(lines)})
        #expect(result.containingSentence==lines[0].text && result.capture?.method == .screenOCR)
        #expect(result.diagnostics.reason == nil)
    }
    @Test func failedScreenSupplementPreservesNativeParagraph() async throws {
        let paragraph=CapturedContext(target:"bank",context:"They walked along the bank of the river.",containingSentence:nil,
            capture:.init(reliability:.heuristic,method:.axRange,reason:.sentenceUnavailable))
        let result=try await BooksScreenFallback.capture(enabled:true,isBooks:true,permission:true,nativeHasSentence:false,
            isCurrent:{true},snapshot:{nil},native:{paragraph},recognize:{ _,_,_ in .recognized([])})
        #expect(result.context==paragraph.context && result.capture?.method == .axRange)
        #expect(result.containingSentence==nil)
    }
    @Test func screenshotOrOCRFailurePreservesCopiedWord() async throws {
        let result=try await BooksScreenFallback.capture(enabled:true,isBooks:true,permission:true,nativeHasSentence:false,
            isCurrent:{true},snapshot:{nil},native:{targetOnly},recognize:{ _,_,_ in .recognized([])})
        #expect(result.target=="bank" && result.containingSentence==nil)
    }

    @Test(arguments:["empty","failed","timeout"])
    func recognitionOutcomePreservesNativeTextAndReportsItsActualReason(outcome:String) async throws {
        let paragraph=CapturedContext(target:"bank",context:"They walked along the bank of the river.",containingSentence:nil,
            capture:.init(reliability:.heuristic,method:.axRange,reason:.sentenceUnavailable))
        let recognition:ScreenTextRecognition.Result = outcome == "failed" ? .failed : outcome == "timeout" ? .timedOut : .recognized([])
        let result=try await BooksScreenFallback.capture(enabled:true,isBooks:true,permission:true,nativeHasSentence:false,
            isCurrent:{true},snapshot:{frame()},native:{paragraph},recognize:{ _,_,_ in recognition})
        #expect(result.target==paragraph.target && result.context==paragraph.context && result.containingSentence==nil)
        #expect(result.capture?.method == .axRange)
        #expect(result.diagnostics.screenContext == (outcome == "failed" ? .recognitionFailed : outcome == "timeout" ? .timedOut : .textUnavailable))
    }

    private func reviewRequest() throws -> LookupRequest {
        try .captured(target:"bank",context:lines[0].text,sentence:lines[0].text,source:"Synthetic Books",
                      capture:.init(reliability:.heuristic,method:.screenOCR))
    }
    @Test func previewSendsNothingUntilCurrentConfirmationAndOnlyOnce() async throws {
        let provider=ControlledProvider(), coordinator=LookupCoordinator(provider:ControlledProvider())
        coordinator.configurePrimaryProvider(provider,label:"Synthetic cloud",isCloud:true)
        let id=coordinator.beginCapture()
        coordinator.finishCapture(id,request:try reviewRequest())
        for _ in 0..<5 { await Task.yield() }
        #expect(await provider.calls.isEmpty)
        #expect(coordinator.selectionCloud.offer==nil)
        guard case .reviewingContext(_,let reviewID)=coordinator.selection else { Issue.record("Preview missing"); return }
        #expect(reviewID==id)
        coordinator.confirmScreenContext(id)
        let call=await provider.waitForCall("bank")
        coordinator.confirmScreenContext(id)
        #expect(await provider.calls.count==1)
        await provider.succeed(call)
    }
    @Test(arguments:["newCapture","dismiss","cancel","configure"])
    func oldPreviewCannotAuthorizeAnotherQuery(action:String) async throws {
        let provider=ControlledProvider(),coordinator=LookupCoordinator(provider:ControlledProvider())
        coordinator.configurePrimaryProvider(provider,label:"Synthetic",isCloud:false)
        let id=coordinator.beginCapture();coordinator.finishCapture(id,request:try reviewRequest())
        switch action {
        case "newCapture": _=coordinator.beginCapture()
        case "dismiss": coordinator.dismissSelection()
        case "cancel": coordinator.cancel(.selection)
        default: coordinator.configurePrimaryProvider(provider,label:"Changed",isCloud:false)
        }
        coordinator.confirmScreenContext(id)
        for _ in 0..<5 { await Task.yield() }
        #expect(await provider.calls.isEmpty)
    }
    @Test func settingDefaultsOffAndDoesNotImplicitlyRequestPermission() {
        var saved:[Bool]=[]
        let settings=BooksScreenSettings(persist:{saved.append($0)})
        #expect(!settings.enabled && !settings.permissionGranted)
        settings.setEnabled(true);settings.setEnabled(false)
        #expect(saved==[true,false])
    }
}
