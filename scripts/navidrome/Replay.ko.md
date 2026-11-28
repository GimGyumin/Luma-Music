# Navidrome Replay 검증

Luma는 일반 사용자로 Navidrome에 로그인한 후 Native API의 `GET /api/scrobble`을 사용합니다. 운영 서버에서는 HTTPS와 기존 Navidrome 계정이 필요합니다. 서버 URL에 경로 접두사가 있으면 기존 계정 설정에 그대로 둡니다. Replay 화면의 새로고침 메뉴에서 동기화, 과거 기록 재확인, 로컬 기록 보기를 선택할 수 있습니다.

v0.64.2에서 이 경로와 계정 격리를 검증했습니다. v0.62.0은 일반 사용자로 인증해도 404를 반환합니다. 해당 버전에서는 로컬 Replay가 계속 작동합니다. Native 이력을 사용하려면 관리자가 데이터 폴더를 백업하고 지원 버전으로 업그레이드해야 합니다. 검증 프로그램은 설치된 운영 서버를 업그레이드하지 않습니다.

## 독립 서버 실행 및 검사

Python 3와 검사할 버전의 Navidrome 실행 파일을 준비하고 프로젝트 루트에서 다음 명령을 실행합니다.

```sh
python3 scripts/navidrome/test_replay_history.py /path/to/navidrome
```

이 명령은 임시 음악과 데이터 폴더를 만들고 루프백 주소에 서버를 띄웁니다. 일반 계정 둘을 생성해 재생 중 보고, 확정 제출, 같은 초의 반복 재생, 늦게 들어온 제출, 시간 범위, 페이지, 계정 격리를 검사한 후 서버를 종료합니다. 운영 계정이나 기존 데이터 폴더는 필요하지 않습니다.

Chrome, Node.js 22 이상, FFmpeg가 있는 환경에서는 실행 파일 앞에 `--web`을 추가하면 실제 웹 플레이어에서 MP3를 재생한 뒤 같은 서버를 앱 테스트에 넘깁니다. macOS 이외에서는 `CHROME_BINARY`로 Chrome 경로를 지정합니다.

macOS Xcode 환경에서는 같은 서버를 앱 통합 테스트에 전달할 수 있습니다.

```sh
python3 scripts/navidrome/test_replay_history.py /path/to/navidrome \
  xcodebuild -project Luma.xcodeproj -scheme LumaTests -destination 'platform=macOS' \
  -only-testing:LumaTests/ReplayHistoryTests test
```

## 데이터 해석

Native 날짜는 서버에 기록된 제출 시각이며 초 단위입니다. Luma가 제출하는 경우 재생 시작 시각을 명시합니다. 서버 집계의 기간 경계는 UTC입니다. 다른 기기가 뒤늦게 과거 시각의 재생을 제출해도 더 큰 서버 ID로 추가됩니다. 서버에 제출되지 않은 재생과 이력 저장 기능 도입 전의 개별 재생은 복원할 수 없습니다.

서버 이력이 있는 기간의 재생 횟수는 확인된 서버 행 수입니다. 청취 시간은 Luma에 저장된 측정값만 합산합니다. 로컬 기록과 서버 이력을 더해 횟수를 부풀리지 않으며, 일대일로 확인되지 않은 로컬 기록은 별도로 표시합니다. 최초 전환 전에 로컬 이벤트를 JSON Lines로 백업하고 기존 SwiftData 저장소도 유지합니다.

## 작업 파일

| 영역 | 경로 |
|---|---|
| `Luma/App` | `AppContainer.swift`, `LumaApp.swift` |
| `Luma/Models/Domain` | `PlaybackEventDTO.swift`, `WrappedData.swift` |
| `Luma/ObservableState` | `ServerState.swift` |
| `Luma/Services/Implementations` | `LibraryIndexService.swift`, `LibraryService.swift`, `PlayerService+Reporting.swift`, `ReplayHistoryStore.swift`, `ReplayHistorySync.swift`, `StatsService.swift` |
| `Luma/Services/Playback` | `PlaybackMeterMailbox.swift` |
| `Luma/Services/Protocols` | `LibraryServiceProtocol.swift` |
| `Luma/Utilities` | `HapticFeedback.swift` |
| `Luma/Views/Main` | `DiscoverView.swift`, `FullPlayerView.swift`, `MiniPlayerAccessoryView.swift` |
| `Luma/Views/Main/Player` | `AppleMusicLyricsBackground.swift`, `LyricsArtwork.metal`, `PlayerTransportControls.swift` |
| `Luma/Views/Platform/macOS` | `BottomPlayerBar.swift`, `FullPlayerExpandedView.swift`, `MiniPlayerWindowView.swift` |
| `Luma/Views/Wrapped/Components` | `WrappedStatHero.swift` |
| `Luma/Views/Wrapped/Story` | `WrappedStoryPlayerView.swift` |
| `Luma/Views/Wrapped` | `WrappedView.swift` |
| `LumaTests` | `ArtworkSceneTests.swift`, `PlaybackBeatMeterTests.swift`, `ReplayHistoryTests.swift` |
| `Packages/SwiftSonic/Sources/swiftsonic/Navidrome` | `NavidromeNativeAPI.swift` |
| `Packages/SwiftSonic/Sources/swiftsonic/Transport` | `URLSessionTransport.swift` |
| `scripts/navidrome` | `Replay.ko.md`, `replay_web_client.mjs`, `test_replay_history.py` |
