import Foundation
import Testing
@testable import DictionaryApp

@Suite struct BrowserExtensionExportTests {
    func fixture(version: String = "0.2.1") throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("source/icons"), withIntermediateDirectories: true)
        for file in BrowserExtensionExport.files { try Data("synthetic-\(file)".utf8).write(to: root.appendingPathComponent("source/\(file)")) }
        try JSONSerialization.data(withJSONObject: ["version": version]).write(to: root.appendingPathComponent("source/manifest.json"))
        return root
    }
    @Test func preparesVersionedAllowlistedFilesAndReusesOnlyIdenticalContent() throws {
        let root = try fixture(), source = root.appendingPathComponent("source"), parent = root.appendingPathComponent("exports")
        try Data("PRIVATE_SENTINEL".utf8).write(to: source.appendingPathComponent("token"))
        let first = try BrowserExtensionExport.prepare(source: source, parent: parent)
        #expect(first.version == "0.2.1" && !first.reused)
        #expect(first.directory.lastPathComponent == "Wordlit Browser Extension 0.2.1")
        for file in BrowserExtensionExport.files { #expect(try Data(contentsOf: first.directory.appendingPathComponent(file)) == Data(contentsOf: source.appendingPathComponent(file))) }
        #expect(!FileManager.default.fileExists(atPath: first.directory.appendingPathComponent("token").path))
        let date = try first.directory.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let second = try BrowserExtensionExport.prepare(source: source, parent: parent)
        #expect(second.directory == first.directory && second.reused)
        #expect(try second.directory.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == date)
    }
    @Test func anotherVersionGetsItsOwnDirectoryAndOldFilesRemain() throws {
        let root = try fixture(), source = root.appendingPathComponent("source")
        let first = try BrowserExtensionExport.prepare(source: source, parent: root)
        let original = try Data(contentsOf: first.directory.appendingPathComponent("manifest.json"))
        try Data(#"{"version":"0.2.2"}"#.utf8).write(to: source.appendingPathComponent("manifest.json"))
        let second = try BrowserExtensionExport.prepare(source: source, parent: root)
        #expect(second.version == "0.2.2" && first.directory != second.directory)
        #expect(try Data(contentsOf: first.directory.appendingPathComponent("manifest.json")) == original)
    }
    @Test(arguments: ["modified", "extra", "fileLink", "iconsLink"])
    func existingDifferentOrUnsafeDirectoryIsNeverOverwritten(mode: String) throws {
        let root = try fixture(), source = root.appendingPathComponent("source")
        let first = try BrowserExtensionExport.prepare(source: source, parent: root)
        switch mode {
        case "modified": try Data("keep-modified".utf8).write(to: first.directory.appendingPathComponent("content.js"))
        case "extra": try Data("keep-extra".utf8).write(to: first.directory.appendingPathComponent("unexpected"))
        case "fileLink":
            let file = first.directory.appendingPathComponent("content.js")
            try FileManager.default.moveItem(at: file, to: root.appendingPathComponent("original.js"))
            try FileManager.default.createSymbolicLink(at: file, withDestinationURL: root.appendingPathComponent("original.js"))
        default:
            let icons = first.directory.appendingPathComponent("icons")
            try FileManager.default.moveItem(at: icons, to: root.appendingPathComponent("original-icons"))
            try FileManager.default.createSymbolicLink(at: icons, withDestinationURL: root.appendingPathComponent("original-icons"))
        }
        #expect(throws: BrowserExtensionExport.Failure.self) { try BrowserExtensionExport.prepare(source: source, parent: root) }
        if mode == "modified" { #expect(try String(contentsOf: first.directory.appendingPathComponent("content.js"), encoding: .utf8) == "keep-modified") }
        if mode == "extra" { #expect(FileManager.default.fileExists(atPath: first.directory.appendingPathComponent("unexpected").path)) }
    }
    @Test(arguments: ["../escape", "0.2.1/escape", "invalid", "0.2.1\n"])
    func unsafeVersionCannotCreateAnExport(version: String) throws {
        let root = try fixture(version: version), parent = root.appendingPathComponent("uncreated")
        #expect(throws: BrowserExtensionExport.Failure.self) { try BrowserExtensionExport.prepare(source: root.appendingPathComponent("source"), parent: parent) }
        #expect(!FileManager.default.fileExists(atPath: parent.path))
    }
    @Test func finderMetadataDoesNotInvalidateAnOtherwiseExactFolder() throws {
        let root = try fixture(), source = root.appendingPathComponent("source")
        let first = try BrowserExtensionExport.prepare(source: source, parent: root)
        try Data("finder metadata".utf8).write(to: first.directory.appendingPathComponent(".DS_Store"))
        let checked = try BrowserExtensionExport.verify(source: source, directory: first.directory)
        #expect(checked.version == "0.2.1")
        #expect(try BrowserExtensionExport.prepare(source: source, parent: root).reused)
    }
    @Test func symlinkSourcesAndDestinationAreNotFollowed() throws {
        let root = try fixture(), source = root.appendingPathComponent("source")
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        #expect(throws: BrowserExtensionExport.Failure.self) { try BrowserExtensionExport.prepare(source: link, parent: root) }
        let destination = root.appendingPathComponent("Wordlit Browser Extension 0.2.1")
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: root.appendingPathComponent("absent"))
        #expect(throws: BrowserExtensionExport.Failure.self) { try BrowserExtensionExport.prepare(source: source, parent: root) }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("absent").path))
    }
}

@MainActor @Suite struct BrowserExtensionSetupTests {
    @Test func restartRevalidatesFilesWithoutMarkingAnyLookupSuccessful() throws {
        let root = try BrowserExtensionExportTests().fixture()
        var saved: URL?
        let setup = BrowserExtensionSetup(source: root.appendingPathComponent("source"), managedParent: root.appendingPathComponent("managed"), persist: { saved = $0 })
        setup.refresh()
        #expect(setup.prepared == nil && saved == nil)
        setup.prepare()
        let directory = try #require(setup.prepared?.directory)
        #expect(saved == directory)
        let reopened = BrowserExtensionSetup(source: root.appendingPathComponent("source"), managedParent: root.appendingPathComponent("managed"), savedDirectory: saved)
        #expect(reopened.prepared == nil)
        reopened.refresh()
        #expect(reopened.prepared?.directory == directory)
        #expect(reopened.prepared?.version == "0.2.1")
        try Data("changed".utf8).write(to: directory.appendingPathComponent("content.js"))
        reopened.refresh()
        #expect(reopened.prepared == nil)
        #expect(reopened.message.contains("重新准备"))
    }
    @Test func preparingAgainRetainsAChosenVerifiedLocation() throws {
        let root = try BrowserExtensionExportTests().fixture(), managed = root.appendingPathComponent("managed")
        let setup = BrowserExtensionSetup(source: root.appendingPathComponent("source"), managedParent: managed)
        setup.prepare(in: root.appendingPathComponent("chosen"))
        let chosen = try #require(setup.prepared?.directory)
        setup.prepare()
        #expect(setup.prepared?.directory == chosen && setup.prepared?.reused == true)
        #expect(!FileManager.default.fileExists(atPath: managed.path))
    }
    @Test func failedPreparationDoesNotReplaceSavedLocationOrRemoveOldFiles() throws {
        let root = try BrowserExtensionExportTests().fixture()
        var saved: URL?
        let setup = BrowserExtensionSetup(source: root.appendingPathComponent("source"), managedParent: root.appendingPathComponent("managed"), persist: { saved = $0 })
        setup.prepare()
        let original = try #require(saved)
        try Data("changed".utf8).write(to: original.appendingPathComponent("content.js"))
        setup.prepare()
        #expect(setup.prepared == nil && saved == original)
        let custom = root.appendingPathComponent("chosen-folder")
        setup.prepare(in: custom)
        #expect(setup.prepared?.directory.deletingLastPathComponent().path == custom.path)
        #expect(try String(contentsOf: original.appendingPathComponent("content.js"), encoding: .utf8) == "changed")
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
