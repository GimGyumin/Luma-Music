import SwiftUI

struct LumaReleaseIntroductionView: View {
    let isUpdate: Bool
    let onContinue: () -> Void

    private func text(_ key: String.LocalizationValue) -> String {
        String(localized: key, bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
    }

    var body: some View {
        LumaSplashView(
            title: isUpdate ? text("What’s New in Luma") : text("Get Started with Luma"),
            summary: text("Your music, beautifully in tune."),
            icon: "music.note", accent: LumaColors.accent, appIconName: "WelcomeAppIcon",
            features: [
                .init(icon: "play.rectangle", title: text("A closer look at your music"),
                      detail: text("Explore albums and rediscover favorites with artwork that takes center stage.")),
                .init(icon: "quote.bubble", title: text("Follow every word"),
                      detail: text("Read along with lyrics, translations, and pronunciation when available.")),
                .init(icon: "slider.horizontal.3", title: text("Make yourself at home"),
                      detail: text("Choose your audio quality and manage downloaded music in Storage."))
            ],
            footnote: nil,
            buttonTitle: isUpdate ? text("Continue") : text("Get Started"),
            buttonIdentifier: "luma.introduction.continue", onContinue: onContinue
        )
    }
}
