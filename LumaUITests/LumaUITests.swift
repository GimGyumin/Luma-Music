// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

//
//  LumaUITests.swift
//  LumaUITests
//

import XCTest

final class LumaUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

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

    @MainActor
    func testFirstRunReachesServerCredentialsWithoutOptionalSetup() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--luma-ui-testing", "-onboardingComplete", "NO"]
        app.launch()

        let languageContinue = app.buttons["onboarding.language.continue"]
        XCTAssertTrue(languageContinue.waitForExistence(timeout: 20))
        languageContinue.tap()

        let serverURL = app.textFields["onboarding.server.url"]
        XCTAssertTrue(serverURL.waitForExistence(timeout: 10))
        serverURL.tap()
        serverURL.typeText("https://example.invalid")
        app.buttons["onboarding.server.continue"].tap()

        XCTAssertTrue(app.textFields["onboarding.server.username"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.secureTextFields["onboarding.server.password"].exists)
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
