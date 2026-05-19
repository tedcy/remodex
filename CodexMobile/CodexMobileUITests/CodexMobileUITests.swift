// FILE: CodexMobileUITests.swift
// Purpose: Measures timeline scrolling and streaming append performance on deterministic fixtures.
// Layer: UI Test
// Exports: CodexMobileUITests
// Depends on: XCTest

import XCTest

final class CodexMobileUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testReloadConversationAgainstExternalBridge() throws {
        guard let pairingPayload = externalBridgePairingPayloadBase64() else {
            throw XCTSkip("Set REMODEX_UITEST_PAIRING_PAYLOAD_BASE64 or write /tmp/remodex-sim-pairing.b64 to run the external bridge smoke test.")
        }

        let app = XCUIApplication()
        app.launchEnvironment["CodexUITestsPairingPayloadBase64"] = pairingPayload
        app.launch()

        let firstThreadRow = app.buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "sidebar.thread.row."))
            .firstMatch
        XCTAssertTrue(firstThreadRow.waitForExistence(timeout: 45))
        firstThreadRow.tap()

        let timeline = app.scrollViews["turn.timeline.scrollview"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 20))

        let threadActions = threadActionsMenu(in: app)
        XCTAssertTrue(threadActions.waitForExistence(timeout: 10))
        XCTAssertEqual(threadActions.value as? String, "Ready")
        let reloadState = reloadConversationStateProbe(in: app)
        XCTAssertTrue(reloadState.waitForExistence(timeout: 5))
        let reloadStateBeforeTap = reloadState.value as? String
        XCTAssertTrue(reloadStateBeforeTap?.hasSuffix(":ready") == true)
        threadActions.tap()

        let reloadConversation = app.buttons["Reload Conversation"]
        XCTAssertTrue(reloadConversation.waitForExistence(timeout: 5))
        XCTAssertTrue(reloadConversation.isEnabled)
        XCTAssertTrue(reloadConversation.isHittable)
        reloadConversation.tap()

        let reloadStarted = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                let currentReloadState = self.reloadConversationStateProbe(in: app)
                return currentReloadState.exists
                    && (currentReloadState.value as? String) != reloadStateBeforeTap
            },
            object: app
        )
        XCTAssertEqual(XCTWaiter.wait(for: [reloadStarted], timeout: 8), .completed)

        let reloadCompleted = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                let currentReloadState = self.reloadConversationStateProbe(in: app)
                let currentValue = currentReloadState.value as? String
                return currentReloadState.exists
                    && currentValue != reloadStateBeforeTap
                    && currentValue?.hasSuffix(":ready") == true
            },
            object: app
        )
        XCTAssertEqual(XCTWaiter.wait(for: [reloadCompleted], timeout: 20), .completed)

        XCTAssertTrue(timeline.waitForExistence(timeout: 20))
        XCTAssertFalse(app.staticTexts["Couldn't reload this conversation from the server yet."].waitForExistence(timeout: 2))
    }

    private func threadActionsMenu(in app: XCUIApplication) -> XCUIElement {
        app.buttons["thread.actions.menu"]
    }

    private func reloadConversationStateProbe(in app: XCUIApplication) -> XCUIElement {
        app.otherElements["thread.reloadConversation.state"]
    }

    private func externalBridgePairingPayloadBase64() -> String? {
        let environmentPayload = ProcessInfo.processInfo.environment["REMODEX_UITEST_PAIRING_PAYLOAD_BASE64"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let environmentPayload, !environmentPayload.isEmpty {
            return environmentPayload
        }

        let filePayload = try? String(contentsOfFile: "/tmp/remodex-sim-pairing.b64", encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let filePayload, !filePayload.isEmpty {
            return filePayload
        }

        return nil
    }

    func testTurnTimelineScrollingPerformance() {
        let app = XCUIApplication()
        app.launchArguments += [
            "-CodexUITestsFixture",
            "-CodexUITestsMessageCount", "1200",
        ]
        app.launch()

        let timeline = app.scrollViews["turn.timeline.scrollview"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 5))

        measure(metrics: [XCTOSSignpostMetric.scrollingAndDecelerationMetric]) {
            timeline.swipeUp(velocity: .fast)
            timeline.swipeUp(velocity: .fast)
            timeline.swipeDown(velocity: .fast)
            timeline.swipeDown(velocity: .fast)
        }
    }

    func testTurnStreamingAppendPerformance() {
        let app = XCUIApplication()
        app.launchArguments += [
            "-CodexUITestsFixture",
            "-CodexUITestsMessageCount", "500",
            "-CodexUITestsAutoStream",
        ]
        app.launch()

        XCTAssertTrue(app.scrollViews["turn.timeline.scrollview"].waitForExistence(timeout: 5))

        measure(metrics: [XCTClockMetric(), XCTCPUMetric(), XCTMemoryMetric()]) {
            // Wait window where fixture appends streaming chunks into the active timeline.
            RunLoop.current.run(until: Date().addingTimeInterval(1.6))
        }
    }
}
