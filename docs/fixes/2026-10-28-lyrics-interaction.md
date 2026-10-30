# Apple Music 스타일 가사 화면 조정 — 2026-10-28

## 참고한 구현

사용자가 제공한 [공유 대화](https://chatgpt.com/share/6ae1f889-c1f8-83ee-b293-720022540d66)의 프로젝트 목록을 읽고 다음 구현을 비교했다.

- [Lyra](https://github.com/matthewprince/lyra/tree/d075478c8ef617acfd7add51a0bf03dc117ae17b): 줄별 지연, 스프링 이동, 프레임마다 레이아웃을 재측정하지 않는 구성.
- [KaraokeText](https://github.com/WillSuo-Github/KaraokeText/tree/08697a112d314aa360f9b2ebed3622181ab58ad8): SwiftUI가 배치한 글리프를 사용하는 강조 효과. Luma의 기존 TextRenderer가 이미 이 역할을 수행하므로 교체하지 않았다.
- [Apple-Music-Lyric-Animation](https://github.com/HuangRunHua/Apple-Music-Lyric-Animation/tree/39eeba81d925882e8e67224382d2610c628668ab): 줄 중심 구성과 탭 이동. 예제의 별도 타이머는 도입하지 않았다.
- [LyricsIsland-driveverse](https://github.com/M-E-L-S/LyricsIsland-driveverse/tree/55acc772e5d04e02f6719939546cc29bc94804d2): 휴대폰/넓은 화면의 가사 중심 배치.
- 기존 Luma AMLL 포팅 및 2026-10-26 영상 비교 기록을 유지했다. 외부 구현 파일을 새로 복사하거나 의존성을 추가하지 않았다.
- [Apple MoveKeyframe 문서](https://developer.apple.com/documentation/swiftui/movekeyframe)와 설치된 iOS SDK의 Spring/KeyframeAnimator 선언을 확인했다.

## 실제 변경

- `LyricsViewModel+Display.swift`: 손가락을 대고 있거나 관성 스크롤 중일 때 자동 추적이 재개되는 문제 수정. idle 이후 2.5초 유예를 시작하고, 다시 터치하면 취소한다. 복귀 시 같은 가사가 계속 재생 중이거나 일시 정지 상태여도 정확히 한 번 현재 줄로 이동한다. 약한 참조와 취소 처리로 대기 작업의 수명을 제한한다.
- `LyricsPlaybackLineRow.swift`: 직접 탐색할 때 모든 줄을 선명하게 표시하고, 현재 줄만 더 밝게 유지한다. 줄 강조는 0.32/0.42초로 완만하게 전환한다. 단어 타임스탬프는 지연시키지 않는다. 동작 줄이기에서는 위치·크기 강조를 생략한다. VoiceOver 활성화 동작을 명시했다.
- `LyricLineCascade.swift`, `LyricsView.swift`: 기존 네이티브 스크롤 스프링에 다음 줄들의 작은 시각적 지연을 더했다. 실제 측정된 이전 행 높이와 간격만 사용한다. 현재 줄의 앵커는 그대로이고 다음 최대 6개 행의 transform만 계산한다. 한 줄씩 정상 진행할 때만 적용하며, 측정값이 없거나 큰 이동·seek·사용자 탐색·듀엣·넓은 패널에서는 기존 스크롤을 사용한다. 별도 오디오 시계나 프레임별 scrollTo/레이아웃 측정은 없다. 움직임은 1.4초 이내 종료되며 일시 정지·화면 숨김·백그라운드·전력/발열 제한에서는 생략한다.
- `LyricsView.swift`: 기본 36pt 크기를 유지하면서 Dynamic Type에 맞게 가사 글꼴을 확대한다. 기존 실측 행 높이 기반 앵커와 마지막 행 여백을 계속 사용한다.
- `LyricsViewModelTests.swift`, `LyricLineCascadeTests.swift`: 길게 누른 상태, 관성 종료 후 복귀, 재터치 취소, 프로그램 스크롤 idle, 실측 행 이동, 현재 줄 고정, 지연 효과의 종료를 검증한다. 실제 행 뷰를 ImageRenderer로 렌더링해 재생/탐색 상태의 한글·영문 줄바꿈과 선명도를 확인했다.
- `PlaybackRecoveryPositionTests.swift`: 기존 테스트의 엔진 선택 전제를 수정했다. downloaded WAV는 iPhone 스피커에서 주입된 FakePlaybackEngine을 선택하는데, 테스트는 AVPlayer의 시계를 검사하고 있었다. cached fixture로 실제 AVPlayer 경로를 명시했다. 제품의 재생 엔진 코드는 이번 작업에서 변경하지 않았다.

## 검증 및 범위

- macOS 전체 테스트: 1,414개, 231개 suite 통과. 로그 `/tmp/luma-lyrics-audit/mac-full.log`.
- 재생 복구 fixture 수정 후 macOS 재검증: 11개 통과. 로그 `mac-recovery-final.log`.
- 마지막 애니메이션 참여 행 제한 변경 후 macOS 관련 테스트 19개 통과, 최종 iOS build-for-testing 성공. 로그 `mac-final.log`, `ios-final-build.log`. 마지막 빌드는 사용자의 요청에 따라 기기에 다시 실행하지 않았다.
- iPhone 16 Pro: 가사 전환·글리프·탭 seek·수동 스크롤·재생 복구 suite 통과. 두 번째 실행 전체 34개 중 Gapless 한 항목은 실패했다. 해당 구간의 로그에 active → inactive → background 전환 및 검증용 AVPlayer가 paused/1.6477초에 머문 상태가 기록되어 있다. 이 실행을 Gapless 검증 완료로 간주하지 않는다. 사용자가 실기기 재검증을 나중으로 요청하여 더 실행하지 않았다. 로그 `iphone-final.log`.
- 렌더링 이미지는 실제 `LyricsPlaybackLineRow`의 테스트 fixture다. iPhone 화면 캡처나 Apple Music과의 동시 녹화가 아니다. 배경은 비교를 위한 고정 그라디언트다.
- Apple Music의 비공개 애니메이션 수치와 픽셀 단위 동일성은 검증하지 못했다. 현재 기기의 Apple Music과 같은 곡을 동시 녹화해 이동 속도·지연·흐림을 비교하는 최종 시각 검증은 남아 있다.
- 기존 TTML/AMLL 단어 타이밍, 번역·발음·백보컬·듀엣, 아트워크 Metal 배경, 음원 재생·큐·Gapless 구현 및 이전 검색 수정은 유지했다.
