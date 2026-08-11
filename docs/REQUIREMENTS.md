# 요구사항

## UX-Q1

- 카메라 미리보기는 고정 프레임 대신 안정화된 실제 `PageBoundary`를 표시하며, Spread는 좌/우 경계를 각각 표시한다.
- PDF 검토는 탭 미리보기와 450ms 길게 눌러 순서 변경을 유지하고, 화면 이동은 애니메이션으로 표현한다.
- Android 시스템 Navigation 영역은 모든 화면에서 접근 가능하고 조작 UI는 system inset을 존중한다.

## 제품 목표

Scana는 스마트폰으로 일반 문서와 책을 촬영하고, 데이터 전송 없이 단말에서만 스캔 결과와 PDF를 만드는 Android 앱이다.

## V1 기능

- 모바일 카메라 촬영과 촬영 가이드
- 문서 1면 및 책 2면 스캔
- 문서 영역·네 모서리 자동 검출
- 원근 보정, 곡면/책 페이지 평면화, 문서 화질 보정
- 여러 페이지 관리: 순서 변경, 삭제, 회전, 재촬영
- 기존 보정 스캔 이미지 재사용
- OCR 기반 제목 자동 추천
- PDF 생성 및 사용자 지정 저장 위치 선택

## 현재 구현 범위

- 카메라 프리뷰, 수동 촬영, 세로형 문서 가이드 Overlay
- 앱 전용 `scan_sessions/<session_uuid>` 원본 보관과 앱 재시작 후 Session Recovery
- 최근 페이지 썸네일과 기본 페이지 편집: 선택, 삭제, 순서 변경, 회전 메타데이터
- `session.json` 기반 페이지 순서·회전 상태 보존
- 촬영 후 OpenCV 기반 문서 네 모서리 검출과 원본 픽셀 좌표 저장
- Page Editor의 검출 외곽선 표시와 네 Corner 수동 조정. 액션은 Preview 밖 SafeArea 툴바에 배치해 네 점의 조작 영역을 가리지 않는다.
- 네 모서리 거리로 출력 크기를 계산하는 원근 보정과 별도 corrected JPEG 저장
- 실제 페이지 경계 우선, 4% inset fallback, 다중 수평 구조의 robust 곡률 추정과 안전 검증을 사용하는 보수적 곡면 평탄화
- Page Editor의 원본/보정본 비교, 보정 방식 선택, 재보정과 실패 상태 표시
- Perspective 결과에 OpenCV 기반 paper-aware Scan Color 화질 보정을 자동 적용한다. 문서를 일반 사진처럼 밝게 만드는 대신 저주파 paper background를 추정하고 밝은 저채도·저텍스처 종이 영역만 whitening한다. 강한 문자·표 edge는 별도로 어둡고 선명하게 보강하며 컬러 도표와 사진은 보호한다.
- 페이지별 화질 모드는 `스캔(scanColor)`, `원본(originalColor)`, `그레이(grayscale)`, `흑백(blackWhite)`이며 기본값은 스캔이다. 모드 변경은 raw부터 다시 처리하지 않고 corrected 이미지를 입력으로 사용한다.
- 사용자는 원본 사진이 아니라 촬영 직후 자동 생성된 스캔본을 기본 결과로 본다. 표시와 PDF 입력은 enhanced → corrected → raw 순서로 fallback하며 원본 모드는 corrected를 표시한다.
- 여러 스캔본은 Swipe로 탐색하며, 기본 액션은 재촬영·편집·삭제로 제한한다.
- 원본·Corner 조작은 상세 편집 화면에만 표시하고, 순서 변경은 별도 페이지 관리 화면에서 수행한다.
- 촬영은 결과 화면 이동 없이 Camera Preview에서 연속 수행한다. 화면은 촬영 모드, 촬영 버튼, 장수, 최근 스캔본과 처리 중 수만 표시하며 별도 촬영 완료 버튼은 두지 않는다.
- 촬영 시 사용한 반응형 가이드 영역을 페이지 메타데이터에 저장한다. 편집 Corner 초기값은 사용자 수정 → 자동 검출 → 촬영 가이드 순서로 선택한다.
- 최근 스캔본을 누르면 enhanced 우선 대형 반응형 Grid인 PDF Selection Gallery를 연다. Gallery는 전체/개별 선택, 삭제와 상세 보기만 담당하며 검출·보정·스캔 처리 상태를 표시한다.
- Gallery 완료는 선택 페이지만 담은 PDF Page Review를 연다. Review의 대형 반응형 Grid에서 Long Press Drag로 최종 출력 순서를 정하고, 짧은 Tap은 선택 페이지만 탐색하는 Viewer를 연다.
- Review에서 확정한 순서 그대로 PDF에 포함한다. 페이지에 선택된 모드에 맞춰 enhanced를 우선하고 없으면 corrected, raw 순서로 사용하며 rotation 메타데이터를 내보내기 과정에서 적용한다.
- Review 진입 시 선택한 첫 페이지를 우선하고 두 번째 페이지까지 fallback하여 bundled Korean on-device OCR을 background로 실행한다. 입력은 enhanced → corrected → raw 우선순위이며 OCR 실패나 빈 결과는 PDF 흐름을 막지 않는다.
- OCR 제목 후보는 상단 위치, 글자 높이, 길이와 confidence를 조합해 선택하고 숫자 전용·페이지 번호·날짜·긴 본문 문장을 제외한다. 50자로 제한하고 기존 파일명 sanitizer를 적용한다.
- PDF 파일명은 OCR 제안 제목이 있으면 이를 기본값으로, 없으면 `Scana_yyyyMMdd_HHmm`을 사용한다. 사용자가 확인·수정할 수 있으며 `.pdf` 확장자를 자동 처리한다. Android SAF 폴더 선택기로 저장 위치를 지정하고 최근 위치의 persistable URI 권한을 재사용할 수 있다.
- PDF 생성은 background isolate에서 페이지를 순차 처리하고 진행 장수를 표시한다. SAF 저장이 완전히 검증된 뒤에만 ScanSession을 삭제하되, Review에는 저장된 파일명·페이지 수와 `새 스캔`·`파일 열기` 완료 액션을 유지한다.
- `파일 열기`는 저장 결과의 SAF content URI를 `ACTION_VIEW`, MIME `application/pdf`, 임시 read grant로 외부 Viewer에 전달한다. 처리 가능한 앱이 없어도 PDF와 완료 상태를 유지하고 안내한다.
- 파일명 Dialog 종료와 SAF 실행, SAF 복귀와 PDF 진행 표시 사이에는 Flutter 안정 frame을 보장한다. PDF 진행 상태는 별도 Dialog route가 아닌 Review 내부 overlay로 표시한다.
- DEBUG 빌드는 치명적 Flutter/async 오류의 전체 stack, route, lifecycle과 PDF/SAF 흐름을 앱 전용 영속 로그에 남기고 앱 재시작 후 TXT로 내보낼 수 있어야 한다. Release에서는 이 진단 기능을 비활성화한다.
- Dialog 입력 controller와 focus/controller 계열 객체는 이를 사용하는 Widget State가 생성하고 실제 `dispose()`에서 해제한다. `showDialog` caller는 pop 결과 직후 해당 객체를 해제하지 않는다.
- Recovery에서 이어하기를 선택하면 Viewer가 아니라 PDF Selection Gallery를 열며, Gallery Back은 같은 Session을 유지한 Camera로 돌아가 추가 촬영을 허용한다.
- 화면 방향은 Session이 아니라 현재 화면 역할에 따라 관리한다. Single Camera는 Portrait, Spread Camera는 Landscape며 Gallery·Viewer·Page Editor·PDF Review/Completion은 Capture Mode와 관계없이 Portrait을 유지한다.
- Spread Camera에서 Gallery를 열 때 Portrait 전환을 먼저 완료하고 route를 표시한다. Back 또는 `새 스캔`으로 Camera에 복귀하면 기존 capture mode를 다시 적용한다.

## 제약 조건

- 모든 핵심 기능은 완전 오프라인으로 동작한다.
- 이미지·OCR 결과를 외부 서버 또는 클라우드 API에 전송하지 않는다.
- 유료 API와 클라우드 API를 사용하지 않는다.
- 무료 오픈소스 또는 상업 배포 조건을 확인한 로컬 SDK만 검토하며, 도입 전에 라이선스·서비스 약관·오프라인 동작을 기록한다.
- 작업 중 원본과 향후 보정본은 외부 저장소가 아닌 앱 전용 영속 디렉터리에 보관한다.
- 문서 검출은 기기 내부에서 오프라인으로 수행하며 실패해도 촬영 페이지를 유지한다.
- 보정 실패 시 원본, ScanSession, 이전 보정본을 유지하고 사용자가 다시 시도할 수 있어야 한다.
- 화질 보정 실패 시 `enhancementStatus=failed`로 기록하고 raw·corrected·ScanPage를 유지한다. Viewer, Gallery와 PDF는 corrected 또는 raw로 안전하게 fallback한다.
- Scan Color는 hard threshold나 전역 exposure로 종이를 날리지 않는다. 약한 뒷면 비침은 종이 mask의 soft tone mapping으로 완화하고 실제 앞면의 작은 글자·얇은 선은 local dark-detail mask로 유지한다.
- 곡률의 신뢰도가 낮거나 변형량·remap 좌표가 안전 기준을 벗어나면 곡면 변형을 적용하지 않고 Perspective 결과를 유지한다.
- 재촬영은 새 raw와 Perspective 결과가 모두 확정된 경우에만 기존 페이지를 같은 순서로 교체한다.
- Gallery 완료는 Review로, Review의 PDF 만들기는 파일명·저장 위치·생성 단계로 이동한다. 각 Back은 이전 상태를 보존하며, 처리 대기열이 남아 있으면 Gallery 완료를 비활성화한다.
- PDF 저장 취소, 입력 이미지 누락, 생성 또는 SAF 기록 실패 시에는 ScanSession과 모든 raw/corrected 파일 및 선택 상태를 유지한다.
- PDF 저장 성공 전까지 Session의 raw, corrected, enhanced 파일을 모두 보존하며 JSON에는 세션 기준 상대 파일명만 저장한다.
- OCR 제안 제목과 출처 페이지 번호는 이전 `session.json`과 하위 호환되는 선택 필드로 저장한다. 이미지 절대경로나 전체 OCR 본문은 제목 추천 목적으로 영속화하지 않는다.
- 외부 저장소 전체 권한이나 `MANAGE_EXTERNAL_STORAGE`를 요구하지 않고, 사용자가 선택한 SAF URI에만 PDF를 기록한다.
