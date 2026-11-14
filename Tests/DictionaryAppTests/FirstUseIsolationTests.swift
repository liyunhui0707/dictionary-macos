import Foundation
import Testing
@testable import DictionaryApp

struct FirstUseIsolationTests {
    @Test func absentFlagPreservesNormalLaunchAndInvalidFlagsNeverFallBackToDailyData() throws {
        #expect(try FirstUseIsolation.resolve(environment: [:], bundleID: nil, hasQABuild: false) == nil)
        let flag = [FirstUseIsolation.environmentKey: UUID().uuidString]
        for bundle in ["com.liyunhui.DictionaryApp", "unknown"] {
            #expect(throws: FirstUseIsolation.Failure.self) {
                try FirstUseIsolation.resolve(environment: flag, bundleID: bundle, hasQABuild: true)
            }
        }
        #expect(throws: FirstUseIsolation.Failure.self) {
            try FirstUseIsolation.resolve(environment: flag, bundleID: "com.liyunhui.DictionaryApp.testing", hasQABuild: false)
        }
        #expect(throws: FirstUseIsolation.Failure.self) {
            try FirstUseIsolation.resolve(environment: [FirstUseIsolation.environmentKey: "../not-a-run"],
                bundleID: "com.liyunhui.DictionaryApp.testing", hasQABuild: true)
        }
        #expect(throws: FirstUseIsolation.Failure.self) {
            try FirstUseIsolation.resolve(environment: flag.merging(["DICTIONARY_MODEL": "override:model"]) { _, new in new },
                bundleID: "com.liyunhui.DictionaryApp.testing", hasQABuild: true)
        }
    }

    @Test func fixedTestingRunsUseDistinctNamesWithoutTouchingAnyStore() throws {
        let id = UUID()
        let run = try #require(try FirstUseIsolation.resolve(environment: [FirstUseIsolation.environmentKey: id.uuidString],
            bundleID: "com.liyunhui.DictionaryApp.testing", hasQABuild: true))
        #expect(run.id == id)
        #expect(run.preferencesDomain.hasSuffix(id.uuidString))
        #expect(run.preferencesDomain != "com.liyunhui.DictionaryApp.testing")
        #expect(run.tokenDirectory.lastPathComponent == id.uuidString)
        #expect(run.tokenDirectory.path.contains("DictionaryApp-Testing/FirstUse/"))
        #expect(run.preferencesDomain != FirstUseIsolation(id: UUID()).preferencesDomain)
    }
}
