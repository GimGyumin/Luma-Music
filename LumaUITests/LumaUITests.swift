
//
// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root.
//
// LumaUITests.swift
// LumaUITests
//

import XCTest

#if os(iOS) && !targetEnvironment(simulator) && canImport(SiriEvaluations)
import Testing
import Evaluations
import SiriEvaluations
#endif

// MARK: - Existing UI Tests

final class LumaUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false

        #if os(macOS)
        throw XCTSkip(
            "Luma's UI flows are exercised on iOS; the macOS host cannot boot this UI-test app."
        )
        #endif
    }

    // MARK: App Launch

    @MainActor
    func testAppFinishesBooting() throws {
        let app = XCUIApplication()
        app.launch()

        let content = app.descendants(matching: .any)["luma.content"]

        XCTAssertTrue(
            content.waitForExistence(timeout: 20),
            "The app did not finish booting. Recovery visible: \(app.descendants(matching: .any)["luma.storage-recovery"].exists)"
        )
    }

    // MARK: First Run Onboarding

    @MainActor
    func testFirstRunReachesServerCredentialsWithoutOptionalSetup() throws {
        let app = XCUIApplication()

        app.launchArguments = [
            "--luma-ui-testing",
            "-onboardingComplete",
            "NO"
        ]

        app.launch()

        let languageContinue = app.buttons[
            "onboarding.language.continue"
        ]

        XCTAssertTrue(
            languageContinue.waitForExistence(timeout: 20)
        )

        languageContinue.tap()

        let serverURL = app.textFields[
            "onboarding.server.url"
        ]

        XCTAssertTrue(
            serverURL.waitForExistence(timeout: 10)
        )

        serverURL.tap()
        serverURL.typeText("https://example.invalid")

        app.buttons["onboarding.server.continue"].tap()

        XCTAssertTrue(
            app.textFields["onboarding.server.username"]
                .waitForExistence(timeout: 10)
        )

        XCTAssertTrue(
            app.secureTextFields[
                "onboarding.server.password"
            ].exists
        )
    }

    // MARK: Launch Performance

    @MainActor
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }

    // MARK: Diagnostics

    @MainActor
    func testDiagnosticsOptInUsesLocalSinkInUITests() throws {
        let app = XCUIApplication()

        app.launchArguments = [
            "--luma-ui-testing",
            "-luma.appLanguage",
            "en",
            "-AppleLanguages",
            "(en)",
            "-AppleLocale",
            "en_US"
        ]

        app.launch()

        XCTAssertTrue(
            app.descendants(matching: .any)["luma.content"]
                .waitForExistence(timeout: 20)
        )

        let settingsTab = app.tabBars.buttons["Settings"]

        XCTAssertTrue(
            settingsTab.waitForExistence(timeout: 10)
        )

        settingsTab.tap()

        // Diagnostics, developer logs, and troubleshooting
        // share one Advanced destination in Settings.

        let advanced = app.buttons["Advanced"]

        for _ in 0..<4 {
            if advanced.exists {
                break
            }
            app.swipeUp()
        }

        XCTAssertTrue(
            advanced.waitForExistence(timeout: 10)
        )

        advanced.tap()

        let toggle = app.switches[
            "settings.diagnostics.share"
        ]

        let status = app.staticTexts[
            "settings.diagnostics.status"
        ]

        XCTAssertTrue(
            toggle.waitForExistence(timeout: 10)
        )

        if (toggle.value as? String) == "1" {
            toggle.tap()
        }

        XCTAssertEqual(
            toggle.value as? String,
            "0"
        )

        XCTAssertTrue(status.exists)

        toggle.tap()

        let local = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "label == %@",
                "Local test diagnostics are active."
            ),
            object: status
        )

        XCTAssertEqual(
            XCTWaiter.wait(for: [local], timeout: 10),
            .completed
        )

        let probe = app.buttons[
            "settings.diagnostics.probe"
        ]

        XCTAssertTrue(
            probe.waitForExistence(timeout: 10)
        )

        probe.tap()

        let result = app.descendants(matching: .any)[
            "settings.diagnostics.probe-result"
        ]

        XCTAssertTrue(
            result.waitForExistence(timeout: 10)
        )

        let recorded = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "label CONTAINS %@",
                "Test trace recorded"
            ),
            object: result
        )

        XCTAssertEqual(
            XCTWaiter.wait(for: [recorded], timeout: 10),
            .completed
        )

        XCTAssertTrue(
            app.buttons[
                "settings.diagnostics.dashboard"
            ].exists
            || app.buttons[
                "Open Firebase Performance Dashboard"
            ].exists
        )

        XCTAssertTrue(
            app.descendants(matching: .any)[
                "settings.diagnostics.session-started"
            ].exists
        )

        toggle.tap()

        let disabled = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "label == %@",
                "Diagnostic sharing is off."
            ),
            object: status
        )

        XCTAssertEqual(
            XCTWaiter.wait(for: [disabled], timeout: 10),
            .completed
        )
    }
}

// MARK: - Siri AI Evaluations
// Requires iOS 27.3+ on a physical device.
// LumaUITests deployment target must be iOS 27.3+.

#if os(iOS) && !targetEnvironment(simulator) && canImport(SiriEvaluations)

// MARK: Siri Evaluation Definition

struct LumaSiriEvaluation: Evaluation {

    let name = "Luma Siri AI Basic Response Test"

    let dataset = SiriScenarioLoader {
        SiriScenario {
            UserTurn("대한민국의 수도는 어디야?") {
                SiriResponse(.contains("서울"))
            }
        }
    }

    func subject(
        from sample: SiriScenario
    ) async throws -> SiriScenarioSubject {
        try await SiriService.run(scenario: sample)
    }

    var evaluators: Evaluators {
        SiriExpectationEvaluator()
    }

    func aggregateMetrics(
        using aggregator: inout MetricsAggregator
    ) {
        Self.computeSiriMetrics(into: &aggregator)
    }
}

// MARK: Siri AI Test Suite

@Suite(.serialized)
struct LumaSiriAITests {

    @Test(.evaluates(LumaSiriEvaluation()))
    func testSiriAI() async throws {

        let result = EvaluationContext.current.result

        let passRate = result.aggregateValue(
            .mean(of: .siriResponseAllPass)
        )

        #expect(
            passRate == 1,
            "Siri AI did not return the expected response."
        )
    }
}

#endif
