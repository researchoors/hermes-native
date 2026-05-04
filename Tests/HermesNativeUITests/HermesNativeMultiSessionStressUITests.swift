import XCTest
#if os(iOS)
import UIKit
#endif

/// Exercises the real app shell against a configured gateway by opening several
/// sessions, submitting prompts, switching between them repeatedly, and checking
/// that the composer remains present + hittable after each switch.
final class HermesNativeMultiSessionStressUITests: XCTestCase {
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
            attachment.name = "multi-session-stress-metrics"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        super.tearDown()
    }

    @MainActor
    func testCreateThreeSessionsAndSwitchComposerUnderLoad() throws {
        continueAfterFailure = false

        let app = launchConfiguredApp()
        dismissNotificationPromptIfNeeded()
        XCTAssertTrue(waitForSessionsUI(in: app), "Sessions UI should appear before stress run")
        attachScreenshot(named: "00-sessions-ready", app: app)

        let prompts = [
            "qa-a",
            "qa-b",
            "qa-c"
        ]

        for (index, prompt) in prompts.enumerated() {
            measureStep("create-submit-session-\(index + 1)") {
                createSessionAndSubmitPrompt(in: app, prompt: prompt)
            }
            attachScreenshot(named: "0\(index + 1)-session-\(index + 1)-submitted", app: app)
            navigateBackToSessionsIfPossible(in: app)
            XCTAssertTrue(waitForSessionsUI(in: app), "Should return to Sessions after submitting session \(index + 1)")
        }

        attachScreenshot(named: "04-three-sessions-list", app: app)
        let rowTitles = discoverNewestOwnedSessionTitles(in: app, count: prompts.count)
        XCTAssertEqual(rowTitles.count, prompts.count, "Expected to discover created owned session rows")

        for round in 1...4 {
            for (index, title) in rowTitles.enumerated() {
                measureStep("switch-round-\(round)-row-\(index + 1)") {
                    let rowTitle = app.staticTexts[title].firstMatch
                    XCTAssertTrue(rowTitle.waitForExistence(timeout: 5), "Session row \(title) should exist")
                    rowTitle.tap()
                    let input = resolveChatInput(in: app, timeout: 8)
                    assertComposerUsable(input, app: app, context: "round \(round) row \(index + 1)")
                    input.tap()
                    // Type a tiny marker but do not send it; this specifically
                    // catches malformed composer focus/hit-testing where text is
                    // routed to the wrong stale field or cannot be entered.
                    input.typeText(".")
                    XCTAssertTrue(input.exists, "Composer should still exist after typing marker")
                }
                navigateBackToSessionsIfPossible(in: app)
                XCTAssertTrue(waitForSessionsUI(in: app), "Should return to sessions after round \(round) row \(index + 1)")
            }
        }

        attachScreenshot(named: "05-after-switch-stress", app: app)
    }


    @MainActor
    private func discoverNewestOwnedSessionTitles(in app: XCUIApplication, count: Int) -> [String] {
        let tree = app.debugDescription
        let marker = "label: 'My Sessions'"
        guard let markerRange = tree.range(of: marker) else {
            let attachment = XCTAttachment(string: tree)
            attachment.name = "missing-my-sessions-section-tree"
            attachment.lifetime = .keepAlways
            add(attachment)
            return []
        }
        let afterSection = String(tree[markerRange.upperBound...])
        var titles: [String] = []
        for line in afterSection.components(separatedBy: .newlines) {
            if line.contains("label: 'Cron Sessions'") || line.contains("label: 'Archived'") || line.contains("label: 'Other Sessions'") {
                break
            }
            guard line.contains("StaticText"),
                  let labelRange = line.range(of: "label: '") else { continue }
            let rest = line[labelRange.upperBound...]
            guard let end = rest.firstIndex(of: "'") else { continue }
            let label = String(rest[..<end])
            if label.hasPrefix("TUI ·") || label.hasPrefix("Dark Manga ·") || label.hasPrefix("Cron") || label.hasPrefix("(") {
                continue
            }
            if label == "My Sessions" || label == "Sessions" || label == "SESSIONS" {
                continue
            }
            if !titles.contains(label) {
                titles.append(label)
            }
            if titles.count == count { break }
        }
        if titles.count < count {
            let attachment = XCTAttachment(string: tree)
            attachment.name = "owned-session-title-discovery-tree"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        return titles
    }

    @MainActor
    private func launchConfiguredApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest", "--multi-session-stress"]

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
    private func createSessionAndSubmitPrompt(in app: XCUIApplication, prompt: String) {
        let startButton = app.buttons["startNewChatButton"].firstMatch
        let newSessionButton = app.buttons["newSessionButton"].firstMatch
        if startButton.waitForExistence(timeout: 2) {
            startButton.tap()
        } else {
            XCTAssertTrue(newSessionButton.waitForExistence(timeout: 10), "New Session button should be visible")
            newSessionButton.tap()
        }

        let input = resolveChatInput(in: app, timeout: 20)
        assertComposerUsable(input, app: app, context: "create session")
        input.tap()
        paste(prompt, into: input, app: app)

        let sendButton = app.buttons["sendButton"]
        XCTAssertTrue(sendButton.waitForExistence(timeout: 5), "send button should exist")
        XCTAssertTrue(sendButton.isHittable, "send button should be hittable")
        sendButton.tap()
    }

    @MainActor
    private func ownedSessionRows(in app: XCUIApplication) -> [XCUIElement] {
        app.cells.allElementsBoundByIndex.filter { cell in
            cell.exists && cell.frame.height > 20
        }
    }

    @MainActor
    private func resolveChatInput(in app: XCUIApplication, timeout: TimeInterval) -> XCUIElement {
        let textView = app.textViews["chatInput"]
        if textView.waitForExistence(timeout: timeout / 2) { return textView }
        let textField = app.textFields["chatInput"]
        _ = textField.waitForExistence(timeout: timeout / 2)
        return textField
    }

    @MainActor
    private func assertComposerUsable(_ input: XCUIElement, app: XCUIApplication, context: String) {
        if !(input.exists && input.isHittable) {
            attachScreenshot(named: "composer-not-usable-\(context)", app: app)
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "composer-not-usable-tree-\(context)"
            tree.lifetime = .keepAlways
            add(tree)
        }
        XCTAssertTrue(input.exists, "chat input should exist (\(context))")
        XCTAssertTrue(input.isHittable, "chat input should be hittable (\(context))")
        XCTAssertGreaterThan(input.frame.width, 200, "chat input hit region should be wide enough (\(context))")
        XCTAssertGreaterThan(input.frame.height, 20, "chat input hit region should be tall enough (\(context))")
    }

    @MainActor
    private func navigateBackToSessionsIfPossible(in app: XCUIApplication) {
        let sessionsBackButton = app.navigationBars.buttons["Sessions"].firstMatch
        if sessionsBackButton.waitForExistence(timeout: 2), sessionsBackButton.isHittable {
            sessionsBackButton.tap()
            return
        }
        let backButton = app.navigationBars.buttons["Back"].firstMatch
        if backButton.waitForExistence(timeout: 1), backButton.isHittable {
            backButton.tap()
            return
        }
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
    private func attachScreenshot(named name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func measureStep(_ name: String, _ body: () -> Void) {
        let start = Date()
        body()
        samples.append(MetricSample(name: name, duration: Date().timeIntervalSince(start), details: ""))
    }
}
