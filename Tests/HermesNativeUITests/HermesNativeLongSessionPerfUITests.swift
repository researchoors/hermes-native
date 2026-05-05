import XCTest
#if os(iOS)
import UIKit
#endif

/// Live gateway-backed long-session stress test.
///
/// This intentionally drives one growing conversation through repeated turns,
/// checks that the composer remains usable as transcript size increases, and
/// attaches per-turn latency + process-memory samples for before/after perf
/// comparisons.
final class HermesNativeLongSessionPerfUITests: XCTestCase {
    private struct MetricSample {
        let name: String
        let duration: TimeInterval
        let details: String
    }

    private var samples: [MetricSample] = []

    override func tearDown() {
        if !samples.isEmpty {
            let lines = samples.map { sample in
                String(format: "%.3fs %@ %@", sample.duration, sample.name, sample.details)
            }.joined(separator: "\n")
            let attachment = XCTAttachment(string: lines)
            attachment.name = "long-session-perf-metrics"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        attachSimulatorPerfLogIfPresent()
        super.tearDown()
    }

    private func attachSimulatorPerfLogIfPresent() {
        let fileManager = FileManager.default
        let candidates = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).map {
            $0.appendingPathComponent("hermes-native/long-session-perf.log")
        } + [fileManager.temporaryDirectory.appendingPathComponent("hermes-native-long-session-perf.log")]

        for url in candidates where fileManager.fileExists(atPath: url.path) {
            if let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty {
                let attachment = XCTAttachment(string: text)
                attachment.name = "long-session-app-perf-log"
                attachment.lifetime = .keepAlways
                add(attachment)
                return
            }
        }
    }

    @MainActor
    func testLongGrowingSessionComposerLatencyAndMemory() throws {
        continueAfterFailure = false

        let app = launchConfiguredApp()
        dismissNotificationPromptIfNeeded()
        XCTAssertTrue(waitForSessionsUI(in: app), "Sessions UI should appear before long-session stress")

        measureStep("create-session") {
            openNewSession(in: app)
            let input = resolveChatInput(in: app, timeout: 20)
            assertComposerUsable(input, app: app, context: "new-session")
        }

        let prompts = [
            "Long session perf turn 1. Reply with two concise markdown sections and one tiny table. Keep it under 180 words.",
            "Continue this same session with one concise section and a compact bullet list. Keep it under 180 words.",
            "Continue again with one tiny code block and one paragraph explaining it. Keep it under 180 words."
        ]

        for (index, prompt) in prompts.enumerated() {
            let turn = index + 1
            let inputBefore = resolveChatInput(in: app, timeout: 12)
            assertComposerUsable(inputBefore, app: app, context: "before-turn-\(turn)")

            measureStep("turn-\(turn)-submit") {
                submitPrompt(prompt, in: app)
            }

            measureStep("turn-\(turn)-settle") {
                waitForTurnToSettle(in: app, timeout: 75)
            }

            let inputAfter = resolveChatInput(in: app, timeout: 12)
            assertComposerUsable(inputAfter, app: app, context: "after-turn-\(turn)")
        }

        measureStep("final-composer-focus") {
            let input = resolveChatInput(in: app, timeout: 12)
            assertComposerUsable(input, app: app, context: "final")
            input.tap()
            input.typeText(".")
        }
    }

    @MainActor
    private func launchConfiguredApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest", "--long-session-perf", "--disable-animations", "--defer-streaming-transcript", "--virtualize-transcript"]
        let environment = ProcessInfo.processInfo.environment
        let gatewayURL = environment["HERMES_NATIVE_GATEWAY_URL"] ?? "ws://127.0.0.1:18642/v1/ws"
        var launchEnvironment = ["HERMES_NATIVE_GATEWAY_URL": gatewayURL]
        if let apiKey = environment["HERMES_NATIVE_API_KEY"], !apiKey.isEmpty {
            launchEnvironment["HERMES_NATIVE_API_KEY"] = apiKey
        } else if let apiServerKey = environment["API_SERVER_KEY"], !apiServerKey.isEmpty {
            launchEnvironment["HERMES_NATIVE_API_KEY"] = apiServerKey
            launchEnvironment["API_SERVER_KEY"] = apiServerKey
        }
        app.launchEnvironment = launchEnvironment
        app.launch()
        return app
    }

    @MainActor
    private func waitForSessionsUI(in app: XCUIApplication) -> Bool {
        let sessions = app.staticTexts["Sessions"]
        if !sessions.waitForExistence(timeout: 3) {
            let connectButton = app.buttons["connectButton"]
            if connectButton.waitForExistence(timeout: 10) {
                connectButton.tap()
            }
        }
        return sessions.waitForExistence(timeout: 25)
    }

    @MainActor
    private func openNewSession(in app: XCUIApplication) {
        let startButton = app.buttons["startNewChatButton"].firstMatch
        let newSessionButton = app.buttons["newSessionButton"].firstMatch
        if startButton.waitForExistence(timeout: 2) {
            startButton.tap()
        } else {
            XCTAssertTrue(newSessionButton.waitForExistence(timeout: 10), "New Session button should be visible")
            newSessionButton.tap()
        }
    }

    @MainActor
    private func submitPrompt(_ prompt: String, in app: XCUIApplication) {
        let input = resolveChatInput(in: app, timeout: 15)
        assertComposerUsable(input, app: app, context: "submit")
        input.tap()
        paste(prompt, into: input, app: app)

        let sendButton = app.buttons["sendButton"]
        XCTAssertTrue(sendButton.waitForExistence(timeout: 5), "send button should exist")
        XCTAssertTrue(sendButton.isHittable, "send button should be hittable")
        sendButton.tap()
    }

    @MainActor
    private func waitForTurnToSettle(in app: XCUIApplication, timeout: TimeInterval) {
        let sendButton = app.buttons["sendButton"]
        let input = resolveChatInput(in: app, timeout: 4)
        let baselineValue = input.value as? String
        let deadline = Date().addingTimeInterval(timeout)
        var sawBusyState = false
        var unchangedTicksAfterBusy = 0

        while Date() < deadline {
            let stopButton = app.buttons["stopButton"].firstMatch
            let currentValue = input.exists ? (input.value as? String) : nil
            let inputCleared = baselineValue == nil || currentValue != baselineValue
            if stopButton.exists || (sendButton.exists && !sendButton.isEnabled) || inputCleared {
                sawBusyState = true
            }
            if sawBusyState, input.exists, input.isHittable, !stopButton.exists {
                if sendButton.exists, sendButton.isEnabled {
                    return
                }
                // SwiftUI may leave the empty composer send button disabled after
                // completion. Treat stable, hittable composer + no stop button as
                // settled after a few polls.
                unchangedTicksAfterBusy += 1
                if unchangedTicksAfterBusy >= 6 {
                    return
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        attachEvidence(named: "turn-settle-timeout", app: app)
        XCTFail("Timed out waiting for turn to settle")
    }

    @MainActor
    private func resolveChatInput(in app: XCUIApplication, timeout: TimeInterval) -> XCUIElement {
        let textField = app.textFields["chatInput"]
        if textField.waitForExistence(timeout: timeout / 3) { return textField }
        let textView = app.textViews["chatInput"]
        _ = textView.waitForExistence(timeout: timeout * 2 / 3)
        return textView
    }

    @MainActor
    private func assertComposerUsable(_ input: XCUIElement, app: XCUIApplication, context: String) {
        if !(input.exists && input.isHittable) {
            attachEvidence(named: "composer-not-usable-\(context)", app: app)
        }
        XCTAssertTrue(input.exists, "chat input should exist (\(context))")
        XCTAssertTrue(input.isHittable, "chat input should be hittable (\(context))")
        XCTAssertGreaterThan(input.frame.width, 200, "chat input hit region should be wide enough (\(context))")
        XCTAssertGreaterThan(input.frame.height, 20, "chat input hit region should be tall enough (\(context))")
    }

    @MainActor
    private func dismissNotificationPromptIfNeeded() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let dontAllowButton = springboard.buttons["Don’t Allow"]
        if dontAllowButton.waitForExistence(timeout: 3) {
            dontAllowButton.tap()
        } else {
            let allowButton = springboard.buttons["Allow"]
            if allowButton.waitForExistence(timeout: 1) {
                allowButton.tap()
            }
        }
    }

    @MainActor
    private func paste(_ text: String, into input: XCUIElement, app: XCUIApplication) {
        #if os(iOS)
        UIPasteboard.general.string = text
        input.press(forDuration: 1.0)
        let pasteMenu = app.menuItems["Paste"]
        if pasteMenu.waitForExistence(timeout: 2) {
            pasteMenu.tap()
            return
        }
        #endif
        input.typeText(text)
    }

    @MainActor
    private func attachEvidence(named name: String, app: XCUIApplication) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)

        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "\(name)-accessibility-tree"
        tree.lifetime = .keepAlways
        add(tree)
    }

    @MainActor
    private func measureStep(_ name: String, _ body: () -> Void) {
        let start = Date()
        body()
        samples.append(MetricSample(name: name, duration: Date().timeIntervalSince(start), details: ""))
    }

}
