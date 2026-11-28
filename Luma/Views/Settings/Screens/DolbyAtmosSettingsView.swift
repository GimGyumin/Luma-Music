// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

enum SettingsOnOffChoice: CaseIterable, SettingsChoiceItem {
    case on, off

    init(_ enabled: Bool) { self = enabled ? .on : .off }

    var choiceTitle: String {
        self == .on
            ? String(localized: "On", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
            : String(localized: "Off", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
    }
}

struct DolbyAtmosSettingsView: View {
    @Environment(\.appContainer) private var container
    @Bindable var settings: StreamingSettings

    var body: some View {
        Form {
            Section {
                ForEach(SettingsOnOffChoice.allCases, id: \.self) { choice in
                    Button {
                        settings.preferDolbyAtmos = choice == .on
                        Task { await container?.playerService.playbackVariantSettingsDidChange() }
                    } label: {
                        HStack {
                            Text(choice.choiceTitle).foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "checkmark")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(LumaColors.controlAccent)
                                .opacity(SettingsOnOffChoice(settings.preferDolbyAtmos) == choice ? 1 : 0)
                                .accessibilityHidden(true)
                        }
                        .frame(minHeight: 36)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(SettingsOnOffChoice(settings.preferDolbyAtmos) == choice ? [.isSelected] : [])
                }
            } footer: {
                SettingsSectionFooter("When enabled, plays a matching Dolby Atmos version from your server while keeping the original song title, artwork, and album information. If no reliable match is available, plays the original song. Changes apply to the next song.\n\nSpatial playback depends on the source file and connected audio device.")
            }
            Section {
                Toggle("Allow Dolby Atmos over Cellular", isOn: $settings.allowDolbyAtmosOverCellular)
                    .onChange(of: settings.allowDolbyAtmosOverCellular) { _, _ in
                        Task { await container?.playerService.playbackVariantSettingsDidChange() }
                    }
            } footer: {
                SettingsSectionFooter("When disabled, cellular playback uses the original song instead of a Dolby Atmos alternative. Dolby-only songs require Wi-Fi or a downloaded original. Changes apply to the next song.")
            }
        }
        .modifier(SettingsSubpageStyle())
        .navigationTitle("Dolby Atmos")
        #if os(iOS)
        .listStyle(.insetGrouped)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
