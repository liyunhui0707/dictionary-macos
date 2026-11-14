import Foundation

/// A bounded clean-configuration run for the existing fixed Testing app.
/// Never redirects a daily/public app's preferences or reuses its credentials.
struct FirstUseIsolation {
    static let environmentKey = "DICTIONARY_QA_FIRST_USE"
    let id: UUID
    var preferencesDomain: String { "com.liyunhui.DictionaryApp.testing.first-use.\(id.uuidString)" }
    var tokenDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DictionaryApp-Testing/FirstUse/\(id.uuidString)", isDirectory: true)
    }

    static func resolve(environment: [String: String], bundleID: String?, hasQABuild: Bool) throws -> Self? {
        guard let value = environment[environmentKey] else { return nil }
        guard bundleID == "com.liyunhui.DictionaryApp.testing", hasQABuild,
              let id = UUID(uuidString: value),
              !environment.keys.contains("DICTIONARY_PROVIDER"),
              !environment.keys.contains("DICTIONARY_MODEL") else { throw Failure.invalidTestLaunch }
        return Self(id: id)
    }

    enum Failure: Error { case invalidTestLaunch, unavailablePreferences }
}
