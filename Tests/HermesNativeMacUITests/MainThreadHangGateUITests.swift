import XCTest

/// The macOS main-thread hang gate. Launches the app with `--hang-fatal` so the
/// MainThreadWatchdog escalates ANY >250ms main-thread stall to an
/// `assertionFailure` — which crashes the app, so this test observes the crash
/// (app no longer running / no longer responding) and fails.
///
/// Every beachball this app has shipped was on macOS. This runs the launch +
/// early-navigation path under the fatal watchdog so a stall introduced by a
/// new view/perf change fails the PR instead of reaching a user. It's hermetic
/// (no gateway) — it exercises the paths reachable without a backend; the lint
/// rules (no_heavy_work_in_view_body etc.) cover the pattern at author time,
/// and this covers the runtime run-loop the rules can't see.
internal final class MainThreadHangGateUITests: XCTestCase {

    @MainActor
    internal func testLaunchAndOnboardingDoNotHangMainThread() throws {
        continueAfterFailure = false

        let app = XCUIApplication()
        // --hang-fatal: a main-thread stall >250ms trips assertionFailure.
        // --uitest: hermetic launch (no gateway auto-config).
        app.launchArguments = ["--uitest", "--hang-fatal"]
        app.launchEnvironment = [
            "HERMES_NATIVE_GATEWAY_URL": "",
            "HERMES_NATIVE_API_KEY": "",
            "API_SERVER_KEY": ""
        ]
        app.launch()

        // Reaching a rendered onboarding state means the launch run-loop turns
        // all completed under the fatal watchdog without a stall. If any turn
        // had hung, the assertion would have crashed the app and this wait
        // would fail instead.
        XCTAssertTrue(
            app.staticTexts["Connect to your gateway"].waitForExistence(timeout: 20),
            "App should reach onboarding without a main-thread hang (--hang-fatal armed)"
        )

        // Exercise a little interaction so the input/focus run-loop paths run
        // under the watchdog too, then confirm the app is still alive (a fatal
        // hang would have terminated it).
        let connect = app.buttons["connectButton"]
        if connect.waitForExistence(timeout: 5) {
            connect.tap()
        }
        XCTAssertEqual(app.state, .runningForeground,
                       "App must stay alive — a --hang-fatal assertion would have crashed it")
    }
}
