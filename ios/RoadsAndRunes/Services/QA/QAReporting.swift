import Foundation
import Snitch

/// Snitch (github.com/monjar/mobile-app-qa-sdk, docs/QA.md): a tester pulls the tab
/// on the right edge, says what went wrong and sends it, with the screen, the last
/// seconds of video and a timeline of the last minutes, to the Roads & Runes project
/// on the Snitch server. The settings are the `Snitch` dictionary in project.yml.
/// Snitch decides at run time: on in Debug, ad hoc and TestFlight, inert on the App Store.
enum QAReporting {
    static func start() {
        // Tests and previews drive the screens themselves; the tab and the one-time
        // "this is a test build" card would sit in their way.
        let env = ProcessInfo.processInfo.environment
        guard env["RR_UI_TEST"] != "1",
              env["XCTestConfigurationFilePath"] == nil,
              env["XCODE_RUNNING_FOR_PREVIEWS"] != "1" else { return }
        Snitch.start()
        // Which backend the build talks to: localhost, a LAN address or Fly.
        Snitch.setMetadata("server", Config.apiBaseURL.host)
    }
}
