import SwiftUI

/// Native help destination shared by Settings and feature-specific "Learn More" rows.
struct HelpSettingsView: View {
    private var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["LumaBuildIdentifier"] as? String ?? ""
        return build.isEmpty ? short : "\(short) (\(build))"
    }

    var body: some View {
        Form {
            Section {
                SettingsActionRow("GitHub에서 보기", subtitle: "Luma Music 소스와 릴리스") {
                    ExternalLinkOpener.openTrusted(LumaURLs.repository)
                }
                SettingsActionRow("피드백 보내기", subtitle: "버그, 기능 제안, UI·재생 문제") {
                    ExternalLinkOpener.openTrusted(
                        LumaURLs.newIssue(
                            title: "[Feedback] Luma Music \(version)",
                            body: "## 무엇을 하려고 했나요?\n\n\n## 어떤 일이 일어났나요?\n\n\n## 재현 방법\n1. \n2. \n3. \n\n## 환경\n- Luma Music: \(version)\n- 기기 / OS: \n- 오디오 형식: \n\n> 진단 로그나 서버 주소는 자동으로 첨부되지 않습니다. 필요한 경우 직접 검토한 뒤 첨부해 주세요."
                        )
                    )
                }
            } header: {
                SettingsSectionHeader("도움말 및 지원")
            } footer: {
                SettingsSectionFooter("문제를 재현하는 방법과 사용 중인 기기·오디오 형식을 적어 주시면 도움이 됩니다. 토큰, 서버 비밀번호, 비공개 URL은 올리지 마세요.")
            }

            Section {
                ForEach(GuideCatalog.all) { guide in
                    NavigationLink {
                        GuideView(guide: guide.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(guide.title).font(.lumaBody)
                            Text(guide.subtitle).font(.lumaCaption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            } header: {
                SettingsSectionHeader("가이드")
            } footer: {
                SettingsSectionFooter("가이드는 Luma Music GitHub 저장소의 공식 문서를 불러옵니다. 오프라인이면 마지막으로 저장된 문서를 사용합니다.")
            }
        }
        .formStyle(.grouped)
        .modifier(SettingsSubpageStyle())
        .navigationTitle(Text("도움말"))
        .navigationBarTitleDisplayModeInline()
    }
}

/// Compact feature-level link. Reuses the existing settings row/typography language.
struct FeatureGuideLink: View {
    let guide: GuideID
    var title: LocalizedStringKey = "이 기능에 관하여"

    var body: some View {
        SettingsNavigationRow(title) {
            GuideView(guide: guide)
        }
    }
}
