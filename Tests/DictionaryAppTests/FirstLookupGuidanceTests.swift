import Foundation
import Testing
@testable import DictionaryApp

@MainActor
struct FirstLookupGuidanceTests {
    @Test func invalidModelListIsNotAnInvitationToSubmitAgain() {
        var state = FirstLookupGuidance.State()
        state.status = .invalidResponse
        #expect(FirstLookupGuidance.message(state).contains("模型列表"))
    }

    @Test func noMeaningDoesNotSuggestAConnectionFailure() {
        var state = FirstLookupGuidance.State()
        state.manual = .noMeaning
        #expect(FirstLookupGuidance.message(state).contains("已响应"))
    }

    @Test func activeQueryAsksToWaitInsteadOfSubmittingAgain() {
        var state = FirstLookupGuidance.State()
        state.manual = .querying
        #expect(FirstLookupGuidance.message(state).contains("等待"))
    }

    @Test func browserFilesAreASeparateStepAndDoNotRequireAccessibility() {
        var state = FirstLookupGuidance.State()
        state.manual = .responseReceived
        state.permission = .required
        #expect(FirstLookupGuidance.message(state).contains("准备浏览器扩展"))
        state.extensionPrepared = true
        #expect(FirstLookupGuidance.message(state).contains("配对"))
        #expect(!FirstLookupGuidance.message(state).contains("授权"))
    }

    @Test func aNewFailedCheckOverridesOldSuccessButANewResponseRecoversIt() {
        var state = FirstLookupGuidance.State()
        state.manual = .responseReceived
        state.complete = true
        state.status = .unavailable
        state.responseAt = Date(timeIntervalSince1970: 10)
        state.checkedAt = Date(timeIntervalSince1970: 20)
        #expect(FirstLookupGuidance.message(state).contains("打开 Ollama"))
        state.responseAt = Date(timeIntervalSince1970: 30)
        #expect(FirstLookupGuidance.message(state).contains("可以开始阅读"))
    }

    @Test func actionableFailuresPointToTheAppropriateSettings() {
        var state = FirstLookupGuidance.State()
        state.status = .missingModel
        #expect(FirstLookupGuidance.resolve(state).action == .localModel)
        state.status = .unavailable
        #expect(FirstLookupGuidance.resolve(state).action == .checkLocal)
        state.status = .available
        state.manual = .noMeaning
        #expect(FirstLookupGuidance.resolve(state).action == .localModel)
        state.local = false
        #expect(FirstLookupGuidance.resolve(state).action == .service)
    }

    @Test func nativeAndOptionalBooksScreenPermissionsAreCheckedOnlyOnTheirRoutes() {
        var state = FirstLookupGuidance.State()
        state.status = .available
        state.manual = .responseReceived
        state.route = .books
        #expect(FirstLookupGuidance.resolve(state).action == .permissions)
        state.permission = .granted
        #expect(FirstLookupGuidance.resolve(state).action == nil) // Screen path is optional.
        state.booksScreenEnabled = true
        #expect(FirstLookupGuidance.resolve(state).action == .permissions)
        state.screenPermission = true
        #expect(FirstLookupGuidance.resolve(state).action == nil)
        state.reading = .needsContext
        #expect(FirstLookupGuidance.message(state).contains("原句缺失"))
        #expect(!FirstLookupGuidance.message(state).contains("重新授权"))
    }

    @Test func managedCloudAndPendingRestartDoNotPromptALocalCheckOrAutoRestart() {
        var state = FirstLookupGuidance.State()
        state.local = false
        #expect(FirstLookupGuidance.resolve(state).action == .example)
        state.needsService = true
        #expect(FirstLookupGuidance.resolve(state).action == .service)
        state.needsService = false; state.local = true; state.restartRequired = true
        #expect(FirstLookupGuidance.message(state).contains("启动时的模型"))
        #expect(FirstLookupGuidance.resolve(state).action == .localModel)
    }
}
