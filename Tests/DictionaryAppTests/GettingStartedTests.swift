import Foundation
import Testing
@testable import DictionaryApp

@Suite struct BrowserExtensionExportTests {
    func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("source/icons"), withIntermediateDirectories: true)
        for file in BrowserExtensionExport.files { try Data("synthetic-\(file)".utf8).write(to: root.appendingPathComponent("source/\(file)")) }
        return root
    }
    @Test func exportIsIndependentAllowlistedAndNeverOverwrites() throws {
        let root = try fixture(), source = root.appendingPathComponent("source")
        try Data("PRIVATE_SENTINEL".utf8).write(to: source.appendingPathComponent("token"))
        let destination = try BrowserExtensionExport.export(source: source, parent: root)
        for file in BrowserExtensionExport.files { #expect(try Data(contentsOf: destination.appendingPathComponent(file)) == Data(contentsOf: source.appendingPathComponent(file))) }
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("token").path))
        #expect(throws: BrowserExtensionExport.Failure.self) { try BrowserExtensionExport.export(source: source, parent: root) }
    }
    @Test func symlinksAndMissingFilesFailBeforePublishing() throws {
        let root = try fixture(), source = root.appendingPathComponent("source")
        // A symlink supplied as the source directory is rejected before reading it.
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        #expect(throws: BrowserExtensionExport.Failure.self) { try BrowserExtensionExport.export(source: link, parent: root) }
        #expect(throws: (any Error).self) { try BrowserExtensionExport.export(source: root.appendingPathComponent("missing"), parent: root) }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Dictionary Browser Extension").path))
    }
    @Test func existingDestinationSymlinkIsNotFollowed() throws {
        let root = try fixture(), source = root.appendingPathComponent("source")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Dictionary Browser Extension"), withDestinationURL: root.appendingPathComponent("does-not-exist"))
        #expect(throws: BrowserExtensionExport.Failure.self) { try BrowserExtensionExport.export(source: source, parent: root) }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("does-not-exist").path))
    }
}
@MainActor @Suite struct GettingStartedTests {
    @Test func samplePreparationIsNotAQueryAndPreservesDrafts() async throws {
        let provider = ControlledProvider()
        let coordinator = LookupCoordinator(provider: provider)
        let state = ManualLookupState(coordinator: coordinator)
        #expect(state.prepareExample())
        #expect(state.target == "bank")
        #expect(state.context == "They walked along the bank of the river.")
        #expect(!coordinator.manual.isLoading)
        #expect(await provider.calls.isEmpty)
        state.target = "my draft"
        #expect(!state.prepareExample())
        #expect(state.target == "my draft")
        state.target = ""; state.context = "my context"
        #expect(!state.prepareExample())
        #expect(state.context == "my context")
    }
}
