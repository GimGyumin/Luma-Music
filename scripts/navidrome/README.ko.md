# Navidrome 저작권 comment 진단 및 복구

Luma는 OpenSubsonic의 곡 `comment` 안에 있는 `[[COPYRIGHT]]…[[/COPYRIGHT]]` 블록을
앨범 하단에 표시한다. Navidrome 웹의 Get Info에 보이는 원본 `copyright` / `cprt`와
OpenSubsonic `comment`는 서로 다른 데이터다. Get Info 사진만으로 DB의 comment 값이나
실제 getAlbum 응답까지 확인한 것으로 간주하지 않는다.

공식 서버 구현에서 `child.Comment = mf.Comment`이고, 스캔 시
`mf.Comment = md.String(model.TagComment)`로 원본 태그에서 다시 생성한다.
따라서 DB comment만 수정한 값은 해당 파일을 재스캔하면 원래 COMMENT로 덮일 수 있다.

- [OpenSubsonic 응답 생성](https://github.com/navidrome/navidrome/blob/master/server/subsonic/helpers.go)
- [스캔 시 comment 생성](https://github.com/navidrome/navidrome/blob/master/model/metadata/map_mediafile.go)
- [기본 comment 태그 매핑](https://github.com/navidrome/navidrome/blob/master/resources/mappings.yaml)

## 변경 없이 먼저 확인

Navidrome DB가 있는 컴퓨터에서 실행한다. 다음 명령은 DB를 읽기 전용으로 열고,
파일 생성이나 DB 수정을 하지 않는다. `--album`과 `--artist`는 생략하면 전체 검사한다.

```sh
python3 scripts/navidrome/sync_copyright.py \
  --db /Users/your-username/navidrome/data/navidrome.db \
  --album Dangerous --artist 'Michael Jackson'
```

- `needs_update`: 저작권 태그는 있으나 comment에 블록이 없어 복구할 수 있는 곡.
- `already_marked`: DB comment에 이미 내용이 있는 정상 블록이 있다. 실제 getAlbum 응답과
  Luma의 캐시 여부를 이어서 확인해야 한다. 서버의 LegacyClients 설정도 comment 전달에 영향을 준다.
- `invalid_tags`: JSON/태그 형식이 잘못되어 건너뛴 곡.
- `invalid_markers`: 블록이 비어 있거나 닫히지 않아 수동 확인이 필요한 곡.

기존 스크립트의 `copyright_list[0].get("value")`는 객체 목록만 처리한다.
이 도구는 그 형식과 `{"copyright": ["℗ …"]}` 문자열 목록을 모두 지원한다.

## 복구 적용

Navidrome을 중지하고 진단 결과를 확인한 뒤, 같은 명령에 `--apply`를 붙인다.
이는 실제 DB 쓰기 작업이며 이 저장소에서 자동으로 실행하지 않는다.
매번 덮어쓰지 않는 날짜별 SQLite 백업을 먼저 생성한다. WAL의 커밋된 내용도 백업에 포함한다.
기존 comment 설명, tags, 파일 시각인 updated_at은 보존하고 comment만 변경한다.
검사 이후 행이 달라졌으면 전체 쓰기를 롤백한다.

적용 후 Navidrome을 다시 시작하고 Luma도 완전히 종료 후 다시 열어
5분 수명의 메모리 앨범 캐시를 비운다. 캐시 파일이나 다운로드를 삭제할 필요는 없다.
이 작업 직후 full scan을 하면 DB에만 쓴 블록이 다시 없어질 수 있다.

재스캔에도 유지하려면 원본 음악 파일의 COMMENT 태그에 해당 블록을 보존해야 한다.
이는 음원 파일 수정이므로 이 도구는 실행하지 않는다. 여러 COMMENT 값 중 첫 값만
서버에 전달될 수 있으므로 기존 설명과 블록을 하나의 COMMENT 값으로 합쳐야 한다.
copyright를 comment의 첫 alias로 바꾸는 설정은 기존 설명을 가릴 수 있어 일괄 적용하지 않는다.

## 검증

```sh
python3 -B -m unittest discover -s scripts/navidrome -p 'test_*.py' -v
```

임시 DB로 두 태그 형식, 읽기 전용 진단, 설명/시각 보존, 중복 실행,
손상 데이터, 앨범 필터, 동시 변경 롤백 및 WAL 백업을 검증한다.
