import Foundation
import SwiftUI

/// Diagnostics rows embedded in the combined Advanced settings screen.
/// Returning sections (instead of a nested `Form`) keeps the host form's chrome.
struct DiagnosticsSettingsSections: View {
    @State private var settings = DiagnosticsSettings.shared
    @State private var status = DiagnosticsStatusModel.shared
    @State private var probe = DiagnosticsProbeController.shared
    @State private var confirmsCrash = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            Section {
                Toggle("Share Diagnostics", isOn: Binding(
                    get: { settings.sharingEnabled },
                    set: { settings.setSharingEnabled($0) }
                ))
                .accessibilityIdentifier("settings.diagnostics.share")
                Text(statusText).font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings.diagnostics.status")
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Share performance and crash diagnostics with Firebase. Song titles, lyrics, account details and server addresses are excluded from custom reports.")
                    Text("Turning sharing off stops new custom traces immediately. Firebase may need an app restart before queued crash or performance data is no longer sent.")
                    #if os(macOS)
                    Text("On Mac, all diagnostics stay on this device. Firebase upload is iOS-only.")
                    #endif
                }
            }

            Section {
                SettingsValueRow("Firebase Configuration", value: firebaseConfigurationText)
                    .accessibilityIdentifier("settings.diagnostics.firebase-configuration")
                SettingsValueRow("Diagnostic Sharing", value: settings.sharingEnabled ? "On" : "Off")
                    .accessibilityIdentifier("settings.diagnostics.sharing-state")
                SettingsValueRow("Performance Collection", value: performanceText)
                    .accessibilityIdentifier("settings.diagnostics.performance-state")
                SettingsValueRow("Crashlytics Collection", value: crashlyticsText)
                    .accessibilityIdentifier("settings.diagnostics.crashlytics-state")
                SettingsValueRow("Instrumentation Mode", value: status.collection.backend.displayName)
                    .accessibilityIdentifier("settings.diagnostics.instrumentation-mode")
                SettingsValueRow("Firebase Server Receipt", value: serverReceiptText)
                    .accessibilityIdentifier("settings.diagnostics.server-receipt")

                SettingsActionRow(
                    "Check Diagnostics Delivery",
                    subtitle: "Records a test performance trace and verifies local collection. Firebase upload is automatic.",
                    isBusy: probe.isProbing
                ) {
                    _ = probe.start(settings: settings)
                    status.refresh(consent: settings.sharingEnabled)
                }
                .accessibilityIdentifier("settings.diagnostics.probe")

                if let result = probe.lastResult {
                    probeResultView(result)
                } else {
                    Text("No manual probe has been run yet.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let note = consistencyNote {
                    Text(LocalizedStringKey(note))
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settings.diagnostics.consistency")
                }
                DisclosureGroup("Info.plist Defaults") {
                    SettingsValueRow("Performance Collection", value: plistText(status.collection.infoPlist.performanceCollectionEnabled))
                    SettingsValueRow("Performance Deactivated", value: plistText(status.collection.infoPlist.performanceCollectionDeactivated))
                    SettingsValueRow("Instrumentation", value: plistText(status.collection.infoPlist.performanceInstrumentationEnabled))
                    SettingsValueRow("SDK Instrumentation", value: plistText(status.collection.state.performanceInstrumentationEnabled))
                    SettingsValueRow("Crashlytics Collection", value: plistText(status.collection.infoPlist.crashlyticsCollectionEnabled))
                }
            } header: {
                SettingsSectionHeader("Firebase Diagnostics Status")
            } footer: {
                SettingsSectionFooter("This button records a fixed-name test trace and verifies local instrumentation. It never enables sharing or forces an upload. Firebase SDK upload and dashboard appearance can take time and are not verified by the app.")
            }

            Section {
                SettingsValueRow("Last Test Trace", value: lastProbeTimeText)
                    .accessibilityIdentifier("settings.diagnostics.last-probe")
                SettingsValueRow("Trace Name", value: DiagnosticsTraceName.manualProbe.rawValue)
                SettingsValueRow("Trace Created", value: yesNo(probe.lastResult?.traceStarted))
                SettingsValueRow("Trace Finished", value: yesNo(probe.lastResult?.traceFinished))
                SettingsValueRow("Local Work Duration", value: durationText(probe.lastResult?.durationMilliseconds))
                SettingsValueRow("Adapter", value: probe.lastResult?.backend.displayName ?? "—")
                SettingsValueRow("Collection Active", value: yesNo(probe.lastResult?.collectionActive))
                SettingsValueRow("Checks Passed", value: probe.lastResult.map { "\($0.checksPassed)" } ?? "—")
                SettingsValueRow("Local Error", value: yesNo(probe.lastResult?.localError))
                SettingsValueRow("Server Receipt", value: probe.lastResult?.serverReceipt == .unavailable
                    ? "Not verifiable in app"
                    : probe.lastResult?.serverReceipt == .notApplicable ? "Not applicable (local only)" : "—")
            } header: {
                SettingsSectionHeader("Last Test Trace")
            } footer: {
                SettingsSectionFooter("A recorded trace means local instrumentation succeeded. A successful Firebase upload is never inferred from this result.")
            }

            Section {
                SettingsValueRow("Traces Started", value: "\(status.session.startedCount)")
                    .accessibilityIdentifier("settings.diagnostics.session-started")
                SettingsValueRow("Successfully Finished", value: "\(status.session.successCount)")
                SettingsValueRow("Failed Traces", value: "\(status.session.failureCount)")
                SettingsValueRow("Cancelled Traces", value: "\(status.session.cancelledCount)")
                SettingsValueRow("Recent Trace", value: status.session.lastEvent?.name.rawValue ?? "None")
                SettingsValueRow("Recent Duration", value: durationText(status.session.lastEvent?.durationMilliseconds))
            } header: {
                SettingsSectionHeader("Local Session Status")
            } footer: {
                SettingsSectionFooter("Live in-memory counters for this app run. Recent events are bounded to 50 and contain no media or account data. The UI updates at most twice per second.")
            }

            Section {
                SettingsActionRow(
                    "Open Firebase Performance Dashboard",
                    subtitle: "Opens the Firebase console in the browser. Google sign-in is handled there."
                ) {
                    ExternalLinkOpener.open(DiagnosticsLinks.performanceDashboard)
                }
                .accessibilityIdentifier("settings.diagnostics.dashboard")
            } footer: {
                SettingsSectionFooter("Local recording can succeed even if the dashboard has not updated yet. The app never handles Google account credentials.")
            }

            #if DEBUG
            Section {
                Button("Record Test Diagnostic") { DiagnosticsCenter.shared.report(.debugProbe) }
                    .disabled(!settings.sharingEnabled)
                    .accessibilityIdentifier("settings.diagnostics.test-error")
                if ProcessInfo.processInfo.arguments.contains("--luma-enable-diagnostics-crash-test") {
                    Button("Test Crash", role: .destructive) { confirmsCrash = true }
                        .disabled(!settings.sharingEnabled)
                }
            } header: { Text("Verification") }
            #endif
        }
        .onAppear {
            status.startObserving()
            status.refresh(consent: settings.sharingEnabled)
        }
        .onChange(of: settings.sharingEnabled) { _, enabled in
            status.refresh(consent: enabled)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                status.startObserving()
                status.refresh(consent: settings.sharingEnabled)
            } else if phase == .background {
                status.stopObserving()
            }
        }
        .onDisappear {
            probe.cancelActiveProbe()
            status.stopObserving()
        }
        .alert("Test Crash", isPresented: $confirmsCrash) {
            #if DEBUG
            Button("Crash App", role: .destructive) {
                guard settings.sharingEnabled,
                      ProcessInfo.processInfo.arguments.contains("--luma-enable-diagnostics-crash-test") else { return }
                fatalError("Explicit Luma diagnostics test crash")
            }
            #endif
            Button("Cancel", role: .cancel) {}
        } message: { Text("This developer test closes the app immediately.") }
    }


    private var statusText: LocalizedStringKey {
        switch settings.status {
        case .disabled: "Diagnostic sharing is off."
        case .local: "Local test diagnostics are active."
        case .sharing: "Diagnostic sharing is on."
        case .missingConfiguration: "Firebase configuration is unavailable. Local diagnostics are active; no data is uploaded."
        }
    }

    private var firebaseConfigurationText: String {
        status.collection.state.firebaseConfigured ? "Ready" : "Not Configured"
    }

    private var performanceText: String {
        guard settings.sharingEnabled else { return "Inactive" }
        guard status.collection.backend == .firebase else {
            return status.collection.backend == .local ? "Inactive" : "Unavailable"
        }
        switch status.collection.state.performance {
        case .active: return "Active"
        case .inactive: return "Inactive"
        case .unavailable: return "Unavailable"
        }
    }

    private var crashlyticsText: String {
        guard settings.sharingEnabled else { return "Inactive" }
        guard status.collection.backend == .firebase else {
            return status.collection.backend == .local ? "Inactive" : "Unavailable"
        }
        switch status.collection.state.crashlytics {
        case .active: return "Active"
        case .inactive: return "Inactive"
        case .unavailable: return "Unavailable"
        }
    }

    private var serverReceiptText: String {
        switch status.collection.backend {
        case .firebase: "Not verifiable in app"
        case .local: "Not applicable (local only)"
        case .disabled: "Unavailable"
        }
    }

    private var lastProbeTimeText: String {
        guard let result = probe.lastResult, result.traceStarted else { return "Never" }
        return result.executedAt.formatted(date: .abbreviated, time: .standard)
    }

    private var consistencyNote: String? {
        switch status.collection.consistency {
        case .consistent:
            return nil
        case .pendingRestart:
            return "Stored sharing and the SDK state differ. Firebase may apply the change on the next app launch."
        case .localOnly:
            return settings.status == .missingConfiguration
                ? "Firebase configuration is unavailable. Local diagnostics are active and no data is uploaded."
                : "No Firebase upload path is active on this device."
        case .unavailable:
            return settings.sharingEnabled && status.collection.backend == .disabled
                ? "Diagnostics are not configured on this build."
                : nil
        }
    }


    private func probeResultView(_ result: DiagnosticsProbeResult) -> some View {
        let presentation = probePresentation(result)
        return VStack(alignment: .leading, spacing: LumaSpacing.xs) {
            Text(LocalizedStringKey(presentation.title))
                .font(.lumaBody.weight(.semibold))
                .foregroundStyle(presentation.color)
            Text(LocalizedStringKey(presentation.detail))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("settings.diagnostics.probe-result")
    }

    private func probePresentation(_ result: DiagnosticsProbeResult) -> (title: String, detail: String, color: Color) {
        switch result.outcome {
        case .recorded:
            if result.backend == .firebase {
                return ("Test trace recorded",
                        "Firebase SDK handles upload automatically. Server receipt and dashboard appearance have not been verified.",
                        .green)
            }
            return ("Test trace recorded locally",
                    "Local instrumentation succeeded. This build has no Firebase upload path.",
                    .green)
        case .consentRequired:
            return ("Test trace not created",
                    "Diagnostic sharing is off. No probe was recorded.",
                    .orange)
        case .diagnosticsDisabled:
            return ("Test trace not created",
                    "Diagnostics are not configured on this build.",
                    .orange)
        case .firebaseNotConfigured:
            return ("Firebase is not configured",
                    "No valid Firebase configuration is available. No trace was created.",
                    .orange)
        case .collectionInactive:
            return ("Performance collection is inactive",
                    "Firebase Performance is not collecting. Restart after enabling sharing, then try again.",
                    .orange)
        case .collectionUnavailable:
            return ("Collection state is unavailable",
                    "The public Firebase API did not expose performance collection state.",
                    .orange)
        case .sampledOut:
            return ("Trace skipped by sampling",
                    "Local checks completed, but Release sampling did not create this trace. Try again later.",
                    .orange)
        case .traceUnavailable:
            return ("Test trace could not be created",
                    "The diagnostics adapter did not accept the trace.",
                    .orange)
        case .localChecksFailed:
            return ("Local diagnostics validation failed",
                    "The trace was not marked successful. No media or account data was involved.",
                    .orange)
        case .cancelled:
            return ("Test cancelled",
                    "The probe was cancelled before completion.",
                    .secondary)
        }
    }

    private func yesNo(_ value: Bool?) -> String {
        guard let value else { return "—" }
        return value ? "Yes" : "No"
    }

    private func durationText(_ milliseconds: Double?) -> String {
        guard let milliseconds else { return "—" }
        return String(format: "%.1f ms", milliseconds)
    }

    private func plistText(_ value: Bool?) -> String {
        guard let value else { return "Not set" }
        return value ? "On" : "Off"
    }
}

