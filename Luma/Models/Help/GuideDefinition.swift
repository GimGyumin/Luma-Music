import Foundation

nonisolated enum GuideID: String, CaseIterable, Identifiable, Sendable {
    case losslessAudio = "lossless-audio"
    case replayGain = "replaygain"
    case gapless = "gapless"
    case crossfade = "crossfade"
    case offlineDownloads = "offline-downloads"
    case streamingCache = "streaming-cache"
    case serverConnection = "server-connection"
    case lyricsSync = "lyrics-sync"
    case replay = "replay"
    case pin = "pin"
    case privacy = "privacy"
    case immersiveArtwork = "immersive-artwork"
    case playlistRecommendations = "playlist-recommendations"
    case widgets = "widgets"
    case siriShortcuts = "siri-shortcuts"

    var id: String { rawValue }
}

nonisolated struct GuideDefinition: Identifiable, Hashable, Sendable {
    let id: GuideID

    var title: String { GuideCatalog.text(id, .title) }
    var subtitle: String { GuideCatalog.text(id, .subtitle) }
}

nonisolated enum GuideCatalog {
    static let all = GuideID.allCases.map(GuideDefinition.init)

    static var languageCode: String {
        let code = AppUILanguage.locale.language.languageCode?.identifier ?? "en"
        return code == "ko" ? "ko" : "en"
    }

    fileprivate enum Field { case title, subtitle }

    fileprivate static func text(_ id: GuideID, _ field: Field) -> String {
        let korean = languageCode == "ko"
        switch (id, field) {
        case (.losslessAudio, .title): return korean ? "무손실 오디오에 관하여" : "About Lossless Audio"
        case (.losslessAudio, .subtitle): return korean ? "FLAC·ALAC과 원본 음질 재생" : "FLAC, ALAC, and original-quality playback"
        case (.replayGain, .title): return korean ? "볼륨 평준화에 관하여" : "About Volume Leveling"
        case (.replayGain, .subtitle): return korean ? "ReplayGain과 클리핑 방지" : "ReplayGain and clipping protection"
        case (.gapless, .title): return korean ? "Gapless에 관하여" : "About Gapless Playback"
        case (.gapless, .subtitle): return korean ? "앨범 트랙 사이의 무음 제거" : "Remove silence between album tracks"
        case (.crossfade, .title): return korean ? "Crossfade에 관하여" : "About Crossfade"
        case (.crossfade, .subtitle): return korean ? "다음 곡으로 자연스럽게 겹치기" : "Blend smoothly into the next track"
        case (.offlineDownloads, .title): return korean ? "오프라인 다운로드에 관하여" : "About Offline Downloads"
        case (.offlineDownloads, .subtitle): return korean ? "다운로드 품질과 저장 공간" : "Download quality and storage"
        case (.streamingCache, .title): return korean ? "스트리밍 캐시에 관하여" : "About Streaming Cache"
        case (.streamingCache, .subtitle): return korean ? "재생한 곡을 다시 빠르게 시작하기" : "Start recently played tracks faster"
        case (.serverConnection, .title): return korean ? "서버 연결 방법" : "Connecting to Your Server"
        case (.serverConnection, .subtitle): return korean ? "OpenSubsonic 서버 주소와 계정" : "OpenSubsonic address and account"
        case (.lyricsSync, .title): return korean ? "가사 동기화에 관하여" : "About Lyrics Sync"
        case (.lyricsSync, .subtitle): return korean ? "LRC·TTML과 단어별 타이밍" : "LRC, TTML, and word timing"
        case (.replay, .title): return korean ? "Replay 기능에 관하여" : "About Replay"
        case (.replay, .subtitle): return korean ? "듣기 기록과 다시 듣기" : "Listening history and revisiting"
        case (.pin, .title): return korean ? "Pin 기능에 관하여" : "About Pin"
        case (.pin, .subtitle): return korean ? "자주 듣는 항목을 빠르게 열기" : "Keep frequently used items close"
        case (.privacy, .title): return korean ? "개인정보 보호에 관하여" : "About Privacy"
        case (.privacy, .subtitle): return korean ? "서버 인증 정보와 진단 데이터" : "Server credentials and diagnostics"
        case (.immersiveArtwork, .title): return korean ? "몰입형 아트워크에 관하여" : "About Immersive Artwork"
        case (.immersiveArtwork, .subtitle): return korean ? "지원되는 커버와 배경 확장 조건" : "When a cover can extend across the player"
        case (.playlistRecommendations, .title): return korean ? "개인화 추천에 관하여" : "About Personalized Recommendations"
        case (.playlistRecommendations, .subtitle): return korean ? "다시 듣기와 Luma 믹스 기준" : "Listen Again and Luma mix rules"
        case (.widgets, .title): return korean ? "Luma 위젯 사용 방법" : "Using Luma Widgets"
        case (.widgets, .subtitle): return korean ? "위젯 추가, 갱신, 데이터 안내" : "Adding widgets, refreshes, and data"
        case (.siriShortcuts, .title): return korean ? "Siri와 단축어 사용 방법" : "Using Siri and Shortcuts"
        case (.siriShortcuts, .subtitle): return korean ? "지원 조건과 설정 방법" : "Requirements and setup"
        }
    }

    /// Offline fallback used when neither a cached guide nor the network is available.
    /// The bundled text intentionally covers the common questions, not every upstream detail.
    static func fallback(_ id: GuideID) -> String {
        let korean = languageCode == "ko"
        switch id {
        case .losslessAudio:
            return korean
                ? "# 무손실 오디오\n\nLuma는 서버가 제공하는 FLAC·ALAC 원본을 손실 압축으로 변환하지 않고 재생합니다.\n\n- 무손실은 파일 크기가 커서 첫 재생까지 시간이 더 걸릴 수 있습니다.\n- 네트워크가 느리면 자동 품질 조정이 적용될 수 있습니다.\n- 다운로드한 원본 파일은 오프라인에서도 원음 그대로 재생됩니다.\n\n## 확인 방법\n\n재생 화면의 음질 배지에서 현재 코덱과 비트레이트를 확인하세요."
                : "# Lossless Audio\n\nLuma plays the FLAC or ALAC original your server provides without converting it to a lossy format.\n\n- Lossless files are larger and may take longer to start.\n- On a slow connection Luma may apply automatic quality adaptation.\n- Downloaded originals play offline at their original quality.\n\n## How to check\n\nOpen the quality badge on the player to see the current codec and bitrate."
        case .immersiveArtwork:
            return korean
                ? "# 몰입형 아트워크\n\n앨범 커버의 색과 질감을 상세 화면 배경으로 확장합니다. 서버가 충분한 해상도의 커버를 제공하고 가장자리가 자연스러울 때 적용됩니다. 투명 PNG나 복잡한 콜라주, 저해상도 커버는 일반 카드로 표시될 수 있습니다.\n\n확장되지 않아도 재생과 다운로드에는 영향이 없으며, 설정에서 기능을 끌 수 있습니다."
                : "# Immersive Artwork\n\nLuma extends a suitable album cover's color and texture into the detail page. It works best with a sufficiently large cover and a stable edge. Transparent PNGs, complex collages, and low-resolution images may use a standard card.\n\nPlayback and downloads are unaffected when a cover does not extend; you can turn the feature off in Settings."
        case .playlistRecommendations:
            return korean
                ? "# 개인화 추천\n\n나의 플레이리스트 탭의 추천은 서버 플레이리스트와 별도 섹션입니다.\n\n- 다시 듣기는 최근 120일 안에 서로 다른 트랙을 2개 이상 들은 앨범만 사용합니다.\n- 한 곡만 반복한 기록은 앨범 감상으로 보지 않습니다.\n- 기록이 부족하면 가짜 앨범을 만들지 않습니다.\n- Get Up!, Heavy Rotation, 나의 필수곡, 신규 음악 등은 기기에서 계산되며 서버 정렬의 영향을 받지 않습니다."
                : "# Personalized Recommendations\n\nRecommendations in the Playlists tab are separate from server playlists.\n\n- Listen Again only uses albums with at least two distinct tracks played in the last 120 days.\n- Repeating one song is not treated as listening to the whole album.\n- No synthetic album is created when history is insufficient.\n- Get Up!, Heavy Rotation, Your Essentials, and New Music are computed on-device and are unaffected by server sorting."
        case .widgets:
            return korean
                ? "# Luma 위젯\n\n홈 화면을 길게 눌러 **편집 → 위젯 추가**에서 Luma의 지금 재생 중, 최근 재생, 추천, 고정 위젯을 추가할 수 있습니다.\n\n곡을 바꾸면 Now Playing과 최근 재생이 갱신되고, 추천 믹스가 새로 계산되면 추천 위젯이 갱신됩니다. 그 외에는 iOS의 timeline 주기에 따라 갱신됩니다."
                : "# Luma Widgets\n\nTouch and hold the Home Screen, choose **Edit → Add Widget**, and add Now Playing, Recently Played, Made for You, or Pins.\n\nChanging tracks refreshes Now Playing and Recently Played; newly computed mixes refresh Made for You. Otherwise iOS refreshes on its timeline schedule."
        case .siriShortcuts:
            return korean
                ? "# Siri와 단축어\n\nOpenSubsonic 서버에 로그인하고 라이브러리 인덱싱이 끝나면 Siri와 단축어에서 곡, 앨범, 아티스트, 플레이리스트를 열 수 있습니다.\n\n음성 검색어는 Apple 서비스로 전달될 수 있지만 서버 비밀번호와 토큰은 포함되지 않습니다. 인덱싱 전에는 일부 항목이 검색되지 않을 수 있습니다."
                : "# Siri and Shortcuts\n\nAfter signing in to an OpenSubsonic server and completing library indexing, Siri and Shortcuts can open songs, albums, artists, and playlists.\n\nSpoken search terms may be sent to Apple services, but server passwords and tokens are not included. Some items may be unavailable before indexing finishes."
        case .replayGain, .gapless, .crossfade, .offlineDownloads, .streamingCache, .serverConnection, .lyricsSync, .replay, .pin, .privacy:
            let title = text(id, .title)
            return korean
                ? "# \(title)\n\n이 가이드의 최신 내용을 불러오지 못했습니다. 네트워크 연결을 확인한 뒤 다시 열어 주세요.\n\n앱의 관련 설정 화면에서 현재 값을 확인할 수 있으며, 저장된 설정은 변경되지 않습니다."
                : "# \(title)\n\nThe latest guide could not be loaded. Check your connection and open it again.\n\nThe related settings screen still shows your current values; no settings were changed."
        }
    }
}
