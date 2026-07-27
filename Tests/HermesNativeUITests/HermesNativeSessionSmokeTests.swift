import XCTest

// MARK: - Session lifecycle smoke tests
//
// Covers the failure modes that keep surfacing in production:
//   1. Nav pane smoke  — tap every sidebar/tab item, assert the pane opens and
//      the app doesn't crash or hang.
//   2. Long-session second turn — send a prompt, wait for full response, send a
//      second prompt in the SAME session, assert the input field is focusable
//      and the send button is hittable (catches the "input bar stuck after
//      elongated session" bug).
//   3. Session switch while streaming — session A starts streaming, user
//      switches to session B and types; assert B's input accepts text (catches
//      cross-session input routing bugs).
//   4. Concurrent sessions complete — two sessions run simultaneously; both
//      finish and both input bars re-enable.
//
// All tests gate on a live gateway (HERMES_NATIVE_GATEWAY_URL env var).
// They are intentionally additive — XCTSkip early if the gateway is absent so
// they don't fail hermetic CI.

final class HermesNativeSessionSmokeTests: XCTestCase {

    // MARK: - Shared helpers

    private var gatewayURL: String {
        ProcessInfo.processInfo.environment["HERMES_NATIVE_GATEWAY_URL"] ?? ""
    }

    private var apiKey: String? {
        ProcessInfo.processInfo.environment["HERMES_NATIVE_API_KEY"]
            ?? ProcessInfo.processInfo.environment["API_SERVER_KEY"]
    }

    @MainActor
    private func launchApp() throws -> XCUIApplication {
        guard !gatewayURL.isEmpty else {
            throw XCTSkip("HERMES_NATIVE_GATEWAY_URL not set — skipping live gateway test")
        }
        let app = XCUIApplication()
        app.launchArguments = ["--uitest"]
        var env = ["HERMES_NATIVE_GATEWAY_URL": gatewayURL]
        if let key = apiKey, !key.isEmpty {
            env["HERMES_NATIVE_API_KEY"] = key
        }
        app.launchEnvironment = env
        app.launch()
        return app
    }

    @MainActor
    private func connectAndReachSessions(_ app: XCUIApplication) -> Bool {
        #if os(iOS)
        let sessionMarker = app.staticTexts["Sessions"]
        #else
        // macOS: the sessions panel title or the sidebar Sessions button
        let sessionMarker = app.staticTexts["Sessions"]
        #endif
        if !sessionMarker.waitForExistence(timeout: 4) {
            let connectButton = app.buttons["connectButton"]
            if connectButton.waitForExistence(timeout: 10) {
                connectButton.tap()
            }
        }
        return sessionMarker.waitForExistence(timeout: 25)
    }

    @MainActor
    private func openNewSession(_ app: XCUIApplication) {
        let startButton = app.buttons["startNewChatButton"].firstMatch
        let newButton = app.buttons["newSessionButton"].firstMatch
        if startButton.waitForExistence(timeout: 2) {
            startButton.tap()
        } else {
            _ = newButton.waitForExistence(timeout: 10)
            newButton.tap()
        }
    }

    /// Returns the chat input element, waiting up to `timeout` seconds.
    @MainActor
    private func chatInput(_ app: XCUIApplication, timeout: TimeInterval = 10) -> XCUIElement {
        let tv = app.textViews["chatInput"]
        if tv.waitForExistence(timeout: timeout / 2) { return tv }
        let tf = app.textFields["chatInput"]
        _ = tf.waitForExistence(timeout: timeout / 2)
        return tf
    }

    @MainActor
    private func sendMessage(_ app: XCUIApplication, text: String) {
        let input = chatInput(app)
        XCTAssertTrue(input.exists, "chatInput must exist before sending")
        input.tap()
        input.typeText(text)
        let send = app.buttons["sendButton"]
        XCTAssertTrue(send.waitForExistence(timeout: 5), "sendButton must exist")
        send.tap()
    }

    /// Waits until the stop button disappears (streaming finished).
    @MainActor
    @discardableResult
    private func waitForStreamingToFinish(_ app: XCUIApplication, timeout: TimeInterval = 60) -> Bool {
        let stop = app.buttons["stopButton"].firstMatch
        if stop.waitForExistence(timeout: 8) {
            return stop.waitForNonExistence(timeout: timeout)
        }
        return true  // never started streaming — treat as done
    }

    /// Asserts the input bar is interactive: focusable and send button hittable.
    @MainActor
    private func assertInputBarUsable(_ app: XCUIApplication, context: String) {
        let input = chatInput(app, timeout: 5)
        XCTAssertTrue(input.exists, "[\(context)] chatInput should exist")
        XCTAssertTrue(input.isEnabled, "[\(context)] chatInput should be enabled")
        input.tap()
        // Typing a space and deleting it is the lightest possible interactive probe.
        input.typeText(" ")
        input.typeText(XCUIKeyboardKey.delete.rawValue)
        let send = app.buttons["sendButton"]
        XCTAssertTrue(send.waitForExistence(timeout: 3), "[\(context)] sendButton should exist")
        XCTAssertTrue(send.isHittable, "[\(context)] sendButton should be hittable")
    }

    @MainActor
    private func screenshot(_ name: String, app: XCUIApplication) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    // MARK: - macOS sidebar nav helper

    /// Taps a macOS sidebar button by its accessibilityLabel, asserts a
    /// landmark element appears, then taps the Close / dismiss button (or
    /// presses Escape) to return to the main canvas.
    @MainActor
    private func exerciseSidebarPane(
        app: XCUIApplication,
        buttonLabel: String,
        landmarkText: String,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        #if os(macOS)
        let button = app.buttons[buttonLabel].firstMatch
        guard button.waitForExistence(timeout: 5) else {
            // Pane gated behind a capability flag — skip gracefully.
            return
        }
        button.tap()
        screenshot("pane-opened-\(buttonLabel.lowercased().replacingOccurrences(of: " ", with: "-"))", app: app)
        // Assert some landmark is visible in the pane.
        let landmark = app.staticTexts[landmarkText].firstMatch
        let found = landmark.waitForExistence(timeout: 6)
        XCTAssertTrue(found, "[\(buttonLabel)] expected landmark '\(landmarkText)' not found", file: file, line: line)
        // Dismiss: try Escape first, then a "Done" or "Close" button.
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.4)
        let done = app.buttons["Done"].firstMatch
        if done.waitForExistence(timeout: 1) { done.tap() }
        #else
        // On iOS each pane is a tab — handled by testNavPaneSmoke_iOSTabs.
        _ = buttonLabel; _ = landmarkText
        #endif
    }

    // MARK: - 1. Nav pane smoke

    /// macOS: tap every sidebar button, assert the pane opens, dismiss.
    @MainActor
    func testNavPaneSmoke_macOSSidebar() throws {
        continueAfterFailure = false
        let app = try launchApp()
        XCTAssertTrue(connectAndReachSessions(app), "Should reach Sessions after connect")

        let panes: [(button: String, landmark: String)] = [
            ("Settings",      "Settings"),
            ("Sessions",      "Sessions"),
            ("Cron Dashboard","Cron Jobs"),
            ("Activity",      "Activity"),
            ("Skills",        "Skills"),
            ("Feed",          "Feed"),
            ("Learning",      "Learning"),
            ("Wiki Graph",    "Wiki"),
            ("Artifacts",     "Artifacts"),
        ]

        for (button, landmark) in panes {
            exerciseSidebarPane(app: app, buttonLabel: button, landmarkText: landmark)
        }

        screenshot("nav-smoke-complete", app: app)
    }

    /// iOS: tap every tab, assert the tab content loads.
    @MainActor
    func testNavPaneSmoke_iOSTabs() throws {
        #if os(iOS)
        continueAfterFailure = false
        let app = try launchApp()
        XCTAssertTrue(connectAndReachSessions(app), "Should reach Sessions after connect")

        let tabs: [(label: String, landmark: String)] = [
            ("Sessions",  "Sessions"),
            ("Cron",      "Cron Jobs"),
            ("Wiki",      "Wiki"),
            ("Skills",    "Skills"),
            ("Artifacts", "Artifacts"),
            ("Feed",      "Feed"),
            ("Learning",  "Learning"),
        ]

        for (label, landmark) in tabs {
            let tab = app.tabBars.buttons[label].firstMatch
            guard tab.waitForExistence(timeout: 5) else { continue }
            tab.tap()
            screenshot("tab-\(label.lowercased())", app: app)
            let found = app.staticTexts[landmark].firstMatch.waitForExistence(timeout: 6)
                || app.navigationBars[landmark].firstMatch.waitForExistence(timeout: 3)
            XCTAssertTrue(found, "Tab '\(label)' — landmark '\(landmark)' not visible after tap")
        }
        #else
        throw XCTSkip("iOS-only test")
        #endif
    }

    // MARK: - 2. Long-session second turn

    /// Send a prompt, wait for the full response, then assert the input bar is
    /// immediately usable for a second turn in the same session. This is the
    /// direct repro for "input bar stuck after elongated session".
    @MainActor
    func testInputBarUsableAfterFirstResponse() throws {
        continueAfterFailure = false
        let app = try launchApp()
        XCTAssertTrue(connectAndReachSessions(app), "Should reach Sessions")
        openNewSession(app)

        sendMessage(app, text: "Reply with exactly: TURN_ONE_OK")
        screenshot("01-turn-one-sent", app: app)

        XCTAssertTrue(
            waitForStreamingToFinish(app, timeout: 60),
            "First response should complete within 60s"
        )
        screenshot("02-turn-one-complete", app: app)

        // Core assertion: input bar must be usable without ANY user interaction
        // other than tapping it — no scroll, no swipe, no dismiss.
        assertInputBarUsable(app, context: "after-first-response")
        screenshot("03-input-bar-usable", app: app)

        // Actually send the second turn to confirm the full round-trip works.
        sendMessage(app, text: "Reply with exactly: TURN_TWO_OK")
        screenshot("04-turn-two-sent", app: app)
        XCTAssertTrue(
            waitForStreamingToFinish(app, timeout: 60),
            "Second response should complete within 60s"
        )
        screenshot("05-turn-two-complete", app: app)
    }

    // MARK: - 3. Session switch while streaming

    /// Start a long-running prompt in session A. While it's streaming, switch to
    /// session B and assert B's input bar accepts text. This catches cross-session
    /// input routing bugs (typing into A's input while viewing B's chat).
    @MainActor
    func testInputRouting_SwitchSessionWhileStreaming() throws {
        continueAfterFailure = false
        let app = try launchApp()
        XCTAssertTrue(connectAndReachSessions(app), "Should reach Sessions")

        // Session A — kick off a slow task so it keeps streaming
        openNewSession(app)
        sendMessage(app, text: "Count from 1 to 20, one number per line, slowly.")
        screenshot("01-session-a-streaming", app: app)

        // Give it a moment to start streaming before we switch away
        let stopA = app.buttons["stopButton"].firstMatch
        _ = stopA.waitForExistence(timeout: 8)

        // Navigate back to sessions list
        #if os(macOS)
        let sessionsButton = app.buttons["Sessions"].firstMatch
        if sessionsButton.waitForExistence(timeout: 3) { sessionsButton.tap() }
        #else
        let backButton = app.navigationBars.buttons["Sessions"].firstMatch
        if backButton.waitForExistence(timeout: 3) { backButton.tap() }
        #endif
        Thread.sleep(forTimeInterval: 0.5)

        // Session B — open a fresh session
        openNewSession(app)
        screenshot("02-session-b-opened", app: app)

        // Core assertion: B's input must be usable while A is still streaming
        assertInputBarUsable(app, context: "session-b-while-a-streams")
        screenshot("03-session-b-input-usable", app: app)

        // Send a message in B to confirm routing is correct
        sendMessage(app, text: "Reply with exactly: SESSION_B_OK")
        let predB = NSPredicate(format: "label CONTAINS[c] %@", "SESSION_B_OK")
        let bVisible = app.staticTexts.containing(predB).element.waitForExistence(timeout: 15)
        screenshot("04-session-b-message-visible", app: app)
        XCTAssertTrue(bVisible, "Session B message should appear in session B's chat, not session A's")
    }

    // MARK: - 4. Concurrent sessions both complete

    /// Open two sessions, kick off a prompt in each, wait for both to finish,
    /// assert both input bars re-enable. Catches the case where completing one
    /// session leaves the other's input bar in a permanently disabled state.
    @MainActor
    func testConcurrentSessions_BothInputBarsReEnable() throws {
        continueAfterFailure = false
        let app = try launchApp()
        XCTAssertTrue(connectAndReachSessions(app), "Should reach Sessions")

        // --- Session A ---
        openNewSession(app)
        sendMessage(app, text: "Reply with exactly: CONCURRENT_A_OK")
        screenshot("01-session-a-sent", app: app)

        // Navigate back before A finishes
        #if os(macOS)
        app.buttons["Sessions"].firstMatch.tap()
        #else
        let backA = app.navigationBars.buttons["Sessions"].firstMatch
        if backA.waitForExistence(timeout: 3) { backA.tap() }
        #endif
        Thread.sleep(forTimeInterval: 0.5)

        // --- Session B ---
        openNewSession(app)
        sendMessage(app, text: "Reply with exactly: CONCURRENT_B_OK")
        screenshot("02-session-b-sent", app: app)

        // Wait for B to finish — it should re-enable its input
        XCTAssertTrue(
            waitForStreamingToFinish(app, timeout: 60),
            "Session B should finish streaming"
        )
        screenshot("03-session-b-done", app: app)
        assertInputBarUsable(app, context: "session-b-after-completion")

        // Navigate back and into A; wait for A to finish then check its input
        #if os(macOS)
        app.buttons["Sessions"].firstMatch.tap()
        #else
        let backB = app.navigationBars.buttons["Sessions"].firstMatch
        if backB.waitForExistence(timeout: 3) { backB.tap() }
        #endif
        Thread.sleep(forTimeInterval: 0.5)

        // Tap the first session cell (session A)
        let firstCell = app.cells.element(boundBy: 0)
        if firstCell.waitForExistence(timeout: 5) { firstCell.tap() }
        screenshot("04-session-a-revisited", app: app)

        // Wait for A to finish (it may still be streaming)
        XCTAssertTrue(
            waitForStreamingToFinish(app, timeout: 60),
            "Session A should also finish streaming"
        )
        screenshot("05-session-a-done", app: app)
        assertInputBarUsable(app, context: "session-a-after-both-complete")
    }

    // MARK: - 5. Wiki navigation smoke

    /// Open the wiki, wait for the graph to load, tap around the node canvas,
    /// open the file tree, and assert no crash. Covers the "click around in
    /// Wiki" scenario.
    @MainActor
    func testWikiNavigation_GraphAndFileTree() throws {
        continueAfterFailure = false
        let app = try launchApp()
        XCTAssertTrue(connectAndReachSessions(app), "Should reach Sessions")

        // Open wiki
        #if os(macOS)
        let wikiButton = app.buttons["Wiki Graph"].firstMatch
        guard wikiButton.waitForExistence(timeout: 5) else {
            throw XCTSkip("Wiki Graph button not present — capability not enabled")
        }
        wikiButton.tap()
        #else
        let wikiTab = app.tabBars.buttons["Wiki"].firstMatch
        guard wikiTab.waitForExistence(timeout: 5) else {
            throw XCTSkip("Wiki tab not present — capability not enabled")
        }
        wikiTab.tap()
        #endif

        screenshot("wiki-01-opened", app: app)

        // Give the graph layout engine time to settle
        Thread.sleep(forTimeInterval: 3)
        screenshot("wiki-02-graph-settled", app: app)

        // Tap the center of the canvas — should either select a node or be a no-op
        let canvas = app.otherElements.firstMatch
        let center = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        center.tap()
        Thread.sleep(forTimeInterval: 0.5)
        screenshot("wiki-03-canvas-tapped", app: app)

        // Tap a few more points to exercise node selection
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.4)).tap()
        Thread.sleep(forTimeInterval: 0.3)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.6)).tap()
        Thread.sleep(forTimeInterval: 0.3)
        screenshot("wiki-04-nodes-tapped", app: app)

        // Assert app is still alive and responsive
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 5),
            "App should still be running after wiki canvas interaction"
        )

        // Try to open the file tree sidebar if present
        #if os(macOS)
        let fileTreeToggle = app.buttons["Toggle Sidebar"].firstMatch
        if fileTreeToggle.waitForExistence(timeout: 3) {
            fileTreeToggle.tap()
            Thread.sleep(forTimeInterval: 0.5)
            screenshot("wiki-05-file-tree-open", app: app)
            fileTreeToggle.tap()  // close it again
        }
        #endif

        screenshot("wiki-06-done", app: app)
    }
}

// MARK: - Shared XCUI helper

private extension XCUIElement {
    func waitForNonExistence(timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}
