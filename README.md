# Attendance Management Software

**에스텍베스트 근태관리 프로그램** · v1.2.0

근무조 코드를 개인에게 한 번 부여하면 2026년 1월부터 매월 1일~말일 근태가 코드대로 자동 생성되는 근태관리 프로그램입니다. 웹 버전과 안드로이드 앱(APK)으로 씁니다.

## 내려받기

| 구분 | 파일 | 주소 |
|---|---|---|
| 웹 버전 | [index.html](index.html) | https://sadness500-boop.github.io/attendance-management-software/ |
| 웹 버전 (버전별) | [releases/Attendance_Management_Software_v1.2.0.html](releases/Attendance_Management_Software_v1.2.0.html) | |
| 안드로이드 앱 (최신) | `ams-latest.apk` | https://github.com/sadness500-boop/attendance-management-software/releases/download/app-latest/ams-latest.apk |
| 안드로이드 앱 (버전별) | `releases/Attendance_Management_Software_v1.2.0.apk` | 릴리스 `v1.2.0` |

- **APK는 GitHub Actions가 만듭니다.** `index.html` 또는 `version.json`을 올리면 Actions 탭의 "Android APK"가 실행되어 약 5분 뒤 `releases/` 폴더와 릴리스에 버전 이름이 붙은 APK가 올라갑니다. Actions 탭 › Android APK › Run workflow 로 직접 실행할 수도 있습니다.
- **안드로이드 설치:** APK 내려받기 → "출처를 알 수 없는 앱 설치 허용" → 설치. Play 프로텍트 경고가 뜨면 "무시하고 설치".
- 서명 키(`android-keystore/ams-debug.keystore`)를 고정해 두었으므로 새 버전은 지우지 않고 덮어 설치하면 됩니다.
- **웹 버전 주소를 열려면** 저장소 Settings › Pages › Branch를 `main` / `/(root)` 로 한 번 켜야 합니다.
- **크롬에서 앱처럼 쓰기:** 웹 버전을 연 뒤 크롬 메뉴 ⋮ → 전송, 저장, 공유 → 페이지를 앱으로 설치 (휴대폰: ⋮ → 홈 화면에 추가). 북마크는 `Ctrl`+`D`.

## 주요 기능

1. **근무조 코드** — 직군·근무형태(주5일·격일·3조2교대·5조2교대·변형 등)를 코드로 만들고 개인에게 코드와 조(순번)를 부여. 출퇴근·휴게시간, 공휴일 휴무 여부, 근로형태(일반·감시단속·특고·단시간) 포함.
2. **계획 근태 자동 생성** — 계획은 저장하지 않고 매월 코드에서 다시 계산합니다. 변경 근태는 날짜별로 따로 저장되므로 수정해도 다음 달은 코드대로 이어집니다.
3. **사업장 근태 원장** — 계획 / 변경 / 시간가감 / 요약 4줄. 변경 칸에 근태기호(연차·반차·결근·특근 등)와 ±시간을 넣으면 휴게시간을 반영해 가감시간과 월 추가근무가 집계됩니다 (반영시간: 일반 ×1.5, 감시단속 ×1.0).
4. **메인화면** — 회사별 · 조직구분별(본부·지사·권역) · 사업장별 · 개인별 진입, 조직도 월 집계, 이달 확인할 것.
5. **사업장 지도** — 카카오맵(회사 공용 키) 위에 에스텍베스트·에스텍시스템 사업장, 근태 사업장, 지사·본부 표시. 내 위치, 스카이뷰, 사업장 현황 검색(인원·근무형태·인근 사업장·관할 지사까지 거리). 카카오맵을 쓸 수 없는 곳에서는 내장 지도로 보여줍니다.
6. **근태 담당** — 담당자를 지정해야 프로그램이 열립니다. 다운로드 QR(웹·앱), 친구 추천, 주간·야간·시스템 화면.
7. **Things to enjoy** — 오늘의 뽑기판 · 팔도 제철맛길 · 팔도 축제길 바로 가기.
8. **월 집계 · 백업** — 사업장별 집계, 추가근무 상위 인원, 엑셀용 복사, 데이터 백업·복원.

## 카카오 지도

- 회사 공용 JavaScript 키를 씁니다. 등록 도메인은 `https://sadness500-boop.github.io` 입니다.
- 안드로이드 앱은 같은 주소(`sadness500-boop.github.io`)로 실행되도록 설정되어 있어 앱에서도 카카오맵이 열립니다.
- 미리보기 창처럼 등록되지 않은 곳에서는 내장 지도(한반도 윤곽 + 사업장 표시)로 바뀝니다.

## 데이터 저장

- 입력한 근태·인원·코드는 그 기기의 브라우저(앱) 저장소에 보관됩니다. 설정 › 데이터 백업으로 정기적으로 복사해 두세요.
- 여러 사람이 같은 데이터를 함께 쓰려면 서버 DB 연동이 필요합니다 (다음 단계).

## 변경 이력

- **v1.2.0** (2026-10-29) — 메인화면 사업장 지도(카카오맵·내 위치·스카이뷰, 에스텍 그룹 사업장·지사·본부, 사업장 현황 검색), Things to enjoy, 제작자 서명, 사업장 좌표와 권역(울산권·경주·포항권·대구·경북권) 정리, 서부·남부·중부지사 조직 추가, 다운로드 QR에 안드로이드 앱 추가, GitHub 저장소·안드로이드 앱 배포
- **v1.1.0** (2026-10-29) — 근태 담당 지정(미지정 시 잠금), 다운로드 QR·친구 추천·주간/야간/시스템, S-Tec 로고 디자인, 메인화면(회사·조직·사업장·개인 진입), 본부·지사·권역 집계, 개인별 달력
- **v1.0.0** (2026-10-29) — 최초 버전: 근무조 코드 기반 월 자동 생성, 변경 근태 분리 저장, 휴게 반영 시간가감, 월 집계

## 폴더 구성

```
index.html                  웹 버전 (GitHub Pages 시작 화면)
releases/                   버전별 배포 파일 (HTML · APK)
version.json                현재 버전
manifest.webmanifest, sw.js, icons/   크롬 앱 설치(PWA)
capacitor.config.json, package.json   안드로이드·아이폰 앱 포장 (Capacitor)
.github/workflows/android-apk.yml     APK 자동 빌드
android-keystore/           앱 서명 키 (덮어 설치용)
```

---

*Produced by RatRae Choi*
