import Foundation
import Testing
@testable import DictionaryApp

@MainActor @Suite struct ReadingSampleTests {
    @Test func sampleIsBundledOfflineAndNeverReadsCredentialsOrChangesLookup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = TokenStore(directory: root)
        let provider = ControlledProvider(), coordinator = LookupCoordinator(provider: ControlledProvider())
        coordinator.configurePrimaryProvider(provider, label: "Synthetic", isCloud: false)
        let handler = TranslateHandler(tokenStore: store, coordinator: coordinator)
        let active = coordinator.submit(try .manual(target: "active", context: ""), to: .selection)
        let call = await provider.waitForCall("active")
        let response = await handler.handle(HTTPRequest(method: "GET", path: "/reading-sample", headers: [:], body: Data()))
        #expect(response.status == 200)
        #expect(response.headers["Content-Type"] == "text/html; charset=utf-8")
        #expect(response.headers["Cache-Control"] == "no-store")
        let html = String(decoding: response.body, as: UTF8.self)
        #expect(html.contains("They walked along the bank of the river."))
        #expect(html.contains("She deposited her savings at the bank."))
        #expect(!html.contains("<script") && !html.contains("<link"))
        #expect(!html.contains("http://") && !html.contains("https://"))
        #expect(!FileManager.default.fileExists(atPath: root.path)) // no token generated
        let calls = await provider.calls.count
        #expect(coordinator.selection.isLoading && calls == 1)
        await provider.succeed(call)
        #expect(await active.value.result != nil)
        #expect(FirstLookupProgress.readingSampleURL.absoluteString == "http://127.0.0.1:49152/reading-sample")
    }
    @Test(arguments: ["Contents/Resources", ""])
    func packagedSampleUsesOnlyItsInstalledBundleAndSupportsBothLayouts(layout: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(ReadingSampleResource.packaged(in: root) == nil)
        let resources = root.appendingPathComponent("DictionaryApp_DictionaryApp.bundle").appendingPathComponent(layout)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let sample = resources.appendingPathComponent("ReadingSample.html")
        try Data("synthetic".utf8).write(to: sample)
        #expect(ReadingSampleResource.packaged(in: root)?.path == sample.path)
        #expect(ReadingSampleResource.packaged(in: root.appendingPathComponent("unrelated")) == nil)
    }
    @Test func staticRouteDoesNotExposeOtherFilesOrOpenAuthenticatedRoutes() async {
        let provider = ControlledProvider(), coordinator = LookupCoordinator(provider: ControlledProvider())
        coordinator.configurePrimaryProvider(provider, label: "Synthetic", isCloud: false)
        let handler = TranslateHandler(tokenStore: TokenStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)), coordinator: coordinator)
        for (method, path, status) in [("GET", "/v1/status", 401), ("POST", "/v1/translate", 401),
                                     ("POST", "/reading-sample", 404), ("GET", "/reading-sample/../token", 404),
                                     ("GET", "/reading-sample?file=token", 404), ("GET", "/token", 404)] {
            let response = await handler.handle(HTTPRequest(method: method, path: path, headers: [:], body: Data()))
            #expect(response.status == status)
        }
        #expect(await provider.calls.isEmpty)
    }
}
