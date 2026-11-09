// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import OSLog
import SwiftSonic
import SwiftUI

struct AccountSettingsView: View {
    @Environment(\.appContainer) private var container
    @Environment(\.dismiss) private var dismiss

    @State private var user: User?
    @State private var capabilities: ServerCapabilities?
    @State private var scanStatus: ScanStatus?
    @State private var isLoadingInfo = false
    @State private var isSyncing = false
    @State private var isScanning = false
    @State private var statusMessage: String?
    @State private var statusIsError = false
    @State private var showChangePassword = false
    @State private var showLogoutConfirm = false
    @State private var pollTask: Task<Void, Never>?

    private var server: ServerSnapshot? { container?.serverState.activeServer }

    var body: some View {
        Form {
            accountSection
            if let server, container?.serverState.needsSubsonicVerification == true {
                Section { AccountVerificationRow(server: server) }
            }
            librarySection
            serverInfoSection
            sessionSection
            if let statusMessage {
                Section {
                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundStyle(statusIsError ? .red : .secondary)
                }
            }
        }
        .formStyle(.grouped)
        .modifier(SettingsSubpageStyle())
        .navigationTitle(String(localized: "Account", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            await loadInfo()
        }
        .onDisappear {
            pollTask?.cancel()
        }
        .sheet(isPresented: $showChangePassword) {
            if let server, let serverService = container?.serverService {
                ChangePasswordSheet(server: server, serverService: serverService)
            }
        }
        .lumaDestructiveAlert(
            String(localized: "Log Out?", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
            isPresented: $showLogoutConfirm,
            message: String(localized: "This removes saved servers, downloads, caches, Home pins, and local search history from this device. Settings and iCloud listening history are kept.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
            destructiveButtonTitle: String(localized: "Log Out", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        ) {
            Task { await logOut() }
        }
    }

    // MARK: - Sections

    private var accountSection: some View {
        Section {
            LabeledContent {
                Text(server?.username ?? "—")
                    .foregroundStyle(.secondary)
            } label: {
                Label {
                    Text(String(localized: "Username", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                } icon: {
                    SettingsIcon(systemImage: "person.circle.fill", color: Color.lumaAccent)
                }
            }
            if let email = user?.email, !email.isEmpty {
                LabeledContent {
                    Text(email)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } label: {
                    Label {
                        Text(String(localized: "Email", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                    } icon: {
                        SettingsIcon(systemImage: "envelope.fill", color: .blue)
                    }
                }
            }
            LabeledContent {
                Text(user?.adminRole == true
                      ? String(localized: "Administrator", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
                      : String(localized: "User", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                    .foregroundStyle(.secondary)
            } label: {
                Label {
                    Text(String(localized: "Role", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                } icon: {
                    SettingsIcon(systemImage: "person.badge.shield.checkmark.fill", color: .indigo)
                }
            }
            if let maxBitRate = user?.maxBitRate {
                LabeledContent {
                    Text("\(maxBitRate) kbps")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } label: {
                    Label {
                        Text(String(localized: "Max bitrate", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                    } icon: {
                        SettingsIcon(systemImage: "speedometer", color: .teal)
                    }
                }
            }
            Button {
                showChangePassword = true
            } label: {
                Label {
                    Text(String(localized: "Change Password", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                } icon: {
                        SettingsIcon(systemImage: "lock.shield.fill", color: .orange)
                }
            }
        } header: {
            SettingsSectionHeader(verbatim: String(localized: "Account Info", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
        } footer: {
            Text(String(localized: "Account details come from your Subsonic server. Changing the password updates the server and the Keychain on this device.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
    }

    private var serverInfoSection: some View {
        Section {
            LabeledContent {
                Text(server?.displayName ?? "—")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } label: {
                Label {
                    Text(String(localized: "Display Name", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                } icon: {
                    SettingsIcon(systemImage: "text.badge.checkmark", color: .gray)
                }
            }
            LabeledContent {
                Text(server?.baseURL ?? "—")
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            } label: {
                Label {
                    Text(String(localized: "Address", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                } icon: {
                    SettingsIcon(systemImage: "globe", color: .blue)
                }
            }
            LabeledContent {
                Text(capabilities?.serverType ?? "—")
                    .foregroundStyle(.secondary)
            } label: {
                Label {
                    Text(String(localized: "Server Type", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                } icon: {
                    SettingsIcon(systemImage: "server.rack", color: .blue)
                }
            }
            LabeledContent {
                Text(capabilities?.serverVersion ?? server?.serverVersion ?? "—")
                    .foregroundStyle(.secondary)
            } label: {
                Label {
                    Text(String(localized: "Server Version", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                } icon: {
                    SettingsIcon(systemImage: "info.circle.fill", color: .blue)
                }
            }
            LabeledContent {
                Text(capabilities?.apiVersion ?? "—")
                    .foregroundStyle(.secondary)
            } label: {
                Label {
                    Text(String(localized: "API Version", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                } icon: {
                        SettingsIcon(systemImage: "number.circle.fill", color: .purple)
                }
            }
            if isLoadingInfo {
                ProgressView()
            }
        } header: {
            SettingsSectionHeader(verbatim: String(localized: "Server Info", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
        }
    }

    private var librarySection: some View {
        Section {
            Button {
                Task { await syncLibrary() }
            } label: {
                if isSyncing {
                    HStack(spacing: LumaSpacing.s) {
                        ProgressView().scaleEffect(0.8)
                        Text(String(localized: "Syncing…", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                    }
                } else {
                    Label {
                        Text(String(localized: "Sync Library Data", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                    } icon: {
                        SettingsIcon(systemImage: "arrow.triangle.2.circlepath.circle.fill", color: .blue)
                    }
                }
            }
            .disabled(isSyncing || isScanning)

            Button {
                Task { await startScan(.quick) }
            } label: {
                Label {
                    Text(String(localized: "Quick Scan", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                } icon: {
                    SettingsIcon(systemImage: "sparkles", color: .orange)
                }
            }
            .disabled(isScanning || isSyncing)

            Button {
                Task { await startScan(.full) }
            } label: {
                Label {
                    Text(String(localized: "Full Scan", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                } icon: {
                    SettingsIcon(systemImage: "internaldrive.fill", color: LumaColors.accent)
                }
            }
            .disabled(isScanning || isSyncing)

            if let scanStatus {
                LabeledContent {
                    Text(scanStatus.scanning
                          ? String(localized: "Scanning…", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
                          : String(localized: "Idle", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                        .foregroundStyle(.secondary)
                } label: {
                    Label {
                        Text(String(localized: "Scan Status", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                    } icon: {
                        SettingsIcon(systemImage: "arrow.counterclockwise.circle.fill", color: .gray)
                    }
                }
                if let count = scanStatus.count {
                    LabeledContent {
                        Text("\(count)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    } label: {
                        Label {
                            Text(String(localized: "Files indexed", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                        } icon: {
                            SettingsIcon(systemImage: "doc.fill", color: .green)
                        }
                    }
                }
                if let folders = scanStatus.folderCount {
                    LabeledContent {
                        Text("\(folders)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    } label: {
                        Label {
                            Text(String(localized: "Folders", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                        } icon: {
                            SettingsIcon(systemImage: "folder.fill", color: .orange)
                        }
                    }
                }
                if let last = scanStatus.lastScan {
                    LabeledContent {
                        Text(last.formatted(date: .abbreviated, time: .shortened))
                            .foregroundStyle(.secondary)
                    } label: {
                        Label {
                            Text(String(localized: "Last scan", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                        } icon: {
                            SettingsIcon(systemImage: "clock.fill", color: LumaColors.accent)
                        }
                    }
                }
            }
        } header: {
            SettingsSectionHeader(verbatim: String(localized: "Library", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
        } footer: {
            Text(String(localized: "Sync refreshes favorites and clears Luma’s API caches. Quick Scan asks the server to rescan new or changed files; Full Scan forces a complete rescan when the server supports it (e.g. Navidrome).", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
        }
    }

    private var sessionSection: some View {
        Section {
            Button(role: .destructive) {
                showLogoutConfirm = true
            } label: {
                Label {
                    Text(String(localized: "Log Out", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                } icon: {
                    SettingsIcon(systemImage: "rectangle.portrait.and.arrow.right.fill", color: .red)
                }
            }
        } header: {
            SettingsSectionHeader(verbatim: String(localized: "Session", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
        }
    }

    // MARK: - Actions

    private func loadInfo() async {
        guard let container, let server else { return }
        isLoadingInfo = true
        defer { isLoadingInfo = false }
        do {
            let client = try await container.serverService.makeSwiftSonicClient()
            async let userTask = client.getUser(username: server.username)
            async let capsTask = client.refreshCapabilities()
            async let scanTask = client.getScanStatus()
            user = try await userTask
            capabilities = try await capsTask
            scanStatus = try? await scanTask
        } catch {
            Logger.settings.error("Account info load failed: \(error.localizedDescription, privacy: .public)")
            present(String(localized: "Couldn’t load account info.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), error: true)
        }
    }

    private func syncLibrary() async {
        guard let container else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            await container.libraryService.invalidateClientCache()
            await container.playlistService.invalidateClientCache()
            await container.radioService.invalidateClientCache()
            try await container.favoritesService.syncFromServer()
            present(String(localized: "Library data synced.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), error: false)
        } catch {
            Logger.settings.error("Library sync failed: \(error.localizedDescription, privacy: .public)")
            present(error.localizedDescription, error: true)
        }
    }

    private func startScan(_ mode: LibraryScanMode) async {
        guard let container, let server else { return }
        isScanning = true
        present(
            mode == .full
                ? String(localized: "Starting full scan…", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
                : String(localized: "Starting quick scan…", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
            error: false
        )
        do {
            let status = try await LibraryScanService.startScan(
                mode: mode,
                baseURL: server.baseURL,
                username: server.username,
                serverService: container.serverService
            )
            scanStatus = status
            if status.scanning {
                present(String(localized: "Scan started on the server.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), error: false)
                beginPolling()
            } else {
                isScanning = false
                present(String(localized: "Scan finished.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), error: false)
                prepareLibraryAfterScan()
            }
        } catch {
            isScanning = false
            Logger.settings.error("Scan failed: \(error.localizedDescription, privacy: .public)")
            present(error.localizedDescription, error: true)
        }
    }

    private func beginPolling() {
        pollTask?.cancel()
        pollTask = Task {
            guard let container else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { break }
                do {
                    let status = try await LibraryScanService.status(
                        serverService: container.serverService
                    )
                    scanStatus = status
                    if !status.scanning {
                        isScanning = false
                        present(String(localized: "Scan finished.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), error: false)
                        prepareLibraryAfterScan()
                        break
                    }
                } catch {
                    isScanning = false
                    present(error.localizedDescription, error: true)
                    break
                }
            }
        }
    }

    /// A scan is how the user says "I just added music", so the local index and the artwork are
    /// prepared immediately instead of waiting for the next launch to notice the new file count.
    ///
    /// This is also the in-app trigger for the library-preparation Live Activity: it runs while the
    /// user is watching Settings, which is exactly the "task the user is actively tracking" case
    /// ActivityKit asks for. The pass itself still decides whether there is anything to do.
    private func prepareLibraryAfterScan() {
        guard let container else { return }
        Task {
            await container.libraryPreparationService.prepareIfLibraryChanged(
                serverService: container.serverService,
                libraryService: container.libraryService,
                indexService: container.libraryIndexService,
                coverPreload: container.albumCoverPreloadService
            )
        }
    }

    private func logOut() async {
        guard let container else { return }
        do {
            try await container.logOutAndClearLocalData()
            dismiss()
        } catch {
            Logger.settings.error("Log out failed: \(error.localizedDescription, privacy: .public)")
            present(error.localizedDescription, error: true)
        }
    }

    private func present(_ message: String, error: Bool) {
        statusMessage = message
        statusIsError = error
    }
}

// MARK: - Change password

private struct ChangePasswordSheet: View {
    let server: ServerSnapshot
    let serverService: any ServerServiceProtocol

    @Environment(\.dismiss) private var dismiss
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    private var canSave: Bool {
        !newPassword.isEmpty
            && newPassword == confirmPassword
            && newPassword.count >= 4
            && !isSaving
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SettingsTextFieldRow(title: "New Password", systemImage: "lock.fill", color: .orange) {
                        SecureField(String(localized: "New Password", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), text: $newPassword)
                            .textContentType(.newPassword)
                    }
                    SettingsTextFieldRow(title: "Confirm Password", systemImage: "checkmark.shield.fill", color: .green) {
                        SecureField(String(localized: "Confirm Password", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), text: $confirmPassword)
                            .textContentType(.newPassword)
                    }
                } footer: {
                    Text(String(localized: "The new password is sent to the server, then saved in the Keychain on this device.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }
            }
            .formStyle(.grouped)
            .modifier(SettingsSubpageStyle())
            .navigationTitle(String(localized: "Change Password", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button(String(localized: "Save", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)) {
                            Task { await save() }
                        }
                        .disabled(!canSave)
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 360, minHeight: 220)
        #endif
    }

    private func save() async {
        guard newPassword == confirmPassword else {
            errorMessage = String(localized: "Passwords do not match.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
            return
        }
        isSaving = true
        defer { isSaving = false }
        do {
            let headers = (try? await serverService.activeCredentials())?.customHeaders ?? [:]
            let client = try await serverService.makeSwiftSonicClient()
            try await client.changePassword(username: server.username, newPassword: newPassword)
            try await serverService.updateServer(
                id: server.id,
                displayName: server.displayName,
                baseURL: server.baseURL,
                username: server.username,
                password: newPassword,
                customHeaders: headers
            )
            dismiss()
        } catch {
            Logger.settings.error("Change password failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
        }
    }
}
