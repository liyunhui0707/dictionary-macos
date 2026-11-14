import AppKit

@main
@MainActor
struct DictionaryAppMain {
    static func main() {
        let app = NSApplication.shared
        let delegate: AppDelegate
        do {
            let firstUse = try FirstUseIsolation.resolve(environment: ProcessInfo.processInfo.environment,
                bundleID: Bundle.main.bundleIdentifier, hasQABuild: QABuildIdentity.current != nil)
            delegate = try AppDelegate(firstUse: firstUse)
        } catch {
            NSLog("First-use QA requires a fixed Testing build and a valid run UUID; launch stopped without changing settings.")
            return
        }
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}
