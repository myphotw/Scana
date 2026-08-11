# 아키텍처

## 원칙

기능은 모듈 단위로 분리하고, UI가 플랫폼 또는 이미지 처리 구현에 직접 의존하지 않도록 설계한다.

## 처리 흐름

카메라 프리뷰 → 촬영 가이드 → ScanSession → 원본 저장 → 문서 검출 → 자동 원근 보정 → 자동 Scan Color 화질 보정 → Gallery/Viewer → (상세 편집 또는 페이지 관리) → PDF Review → 선택 첫 페이지 OCR 제목 제안 → PDF 생성 → 사용자 지정 위치 저장 → 완료 확인/파일 열기

촬영 직후 PDF를 만들지 않는다. 원본과 각 보정 단계의 결과를 분리해 재편집과 재촬영을 지원한다.

## ScanSession 영속화

- 작업 파일은 앱 전용 영속 디렉터리의 `scan_sessions/<session_uuid>/`에 저장한다.
- `session.json`에는 Session ID, 생성 시간, 페이지 배열 순서, raw/corrected/enhanced 상대 파일명, 페이지 번호, 생성 시간, 회전, 원본 크기, 선택적 문서 모서리 좌표, 보정 상태와 선택적 `suggestedTitle`/`ocrSourcePageNo`를 저장한다.
- JSON에는 절대 경로를 기록하지 않는다. 런타임에 Session 디렉터리와 상대 파일명을 결합한다.
- Recovery는 `session.json`을 우선 사용하고, 없거나 손상된 경우에만 `raw_*.jpg`를 탐색해 복구한다.
- 취소와 향후 PDF 저장 성공 시에만 Session 디렉터리를 삭제한다.

## 문서 검출 계층

- Flutter의 `DocumentDetector` 계약은 Camera와 Page Editor UI에서 독립적이다.
- Android 구현은 MethodChannel 뒤의 OpenCV Java API를 사용하며 전용 background executor에서 처리한다.
- 고해상도 원본은 보존하고 최대 변 1400px의 처리용 Mat으로 축소한다.
- Grayscale → Gaussian Blur → Canny → Morphological Close → Contour → Polygon Approximation 순서로 후보를 생성한다.
- 후보는 사각형, convex, 최소 면적, 비정상 비율, 직각성, bounding rectangularity, 화면 가장자리 관계를 조합해 평가한다.
- 결과 좌표는 원본 이미지 픽셀 좌표로 환산하며 순서는 top-left → top-right → bottom-right → bottom-left로 고정한다.
- 실패는 정상 결과로 취급하고 Page Editor에서 기본 네 점을 수동 조정할 수 있다.

## 페이지 보정 계층

- Flutter의 `PageCorrector` 계약은 UI와 OpenCV 구현을 분리하며 Android MethodChannel 구현만 네이티브 계층을 호출한다.
- 문서 모서리는 top-left → top-right → bottom-right → bottom-left 순서와 convex 여부를 검증한다.
- 원근 보정 출력은 위/아래 너비 중 최댓값과 좌/우 높이 중 최댓값으로 계산하고 `getPerspectiveTransform`과 `warpPerspective`를 적용한다.
- 곡면 보정은 먼저 Perspective 결과를 별도 파일로 확정한다. 실제 문서 Corner가 원본 프레임 안쪽에 보이면 페이지 상·하 경계를 우선 분석하고, Corner가 프레임 가장자리에 닿으면 외곽을 추정하지 않고 상하좌우 4% inset 영역만 분석한다.
- 경계를 신뢰할 수 없을 때는 adaptive threshold와 수평 morphology에서 페이지 폭 35% 이상의 여러 장선분을 수집한다. 각 후보의 선형 기울기를 제거한 뒤 median/MAD outlier 제거, median aggregation, smoothing과 edge taper로 비대칭 deformation curve를 계산한다.
- 곡률 신뢰도 0.68 미만, 의미 없는 곡률, 높이 2.5%를 넘는 변위, 급격한 인접 차이, NaN/Infinity, 범위 밖 또는 역전되는 remap 좌표는 모두 실패로 처리하며 remap을 실행하지 않는다.
- 분석 이미지는 최대 변 1200px로 제한하며 최종 remap은 192행 strip 단위로 실행한다. 검출과 보정은 같은 단일 background executor에서 직렬 처리한다.
- 출력은 먼저 숨김 pending JPEG에 기록하고 성공한 경우에만 새 `corrected_*.jpg` revision을 확정한 뒤 메타데이터 참조를 전환한다. Curved 단계 실패 시 직전에 확정한 Perspective 파일을 ScanPage가 계속 참조한다.
- Page Editor는 원본/보정본 전환, Perspective/Curved 수동 선택, 모서리 저장 후 재보정을 제공한다. Corner Preview에는 핸들 반경만큼 내부 여유를 두고 저장·보정 액션은 Preview 아래 SafeArea 툴바에 둔다.

## 화질 보정 계층

- Flutter의 `PageEnhancer` 계약과 `OpenCvPageEnhancer` 구현을 분리해 UI가 MethodChannel/OpenCV에 직접 의존하지 않는다.
- 촬영 처리 큐는 Detection → Perspective → 기본 `scanColor`를 기존 단일 Android executor에서 순차 실행하며 Camera Preview와 다음 촬영을 막지 않는다.
- M8.1 Scan Color는 LAB 휘도 채널의 최대 변 1200px 분석 이미지에서 morphology closing으로 문자 같은 작은 dark component를 제거한 뒤 broad Gaussian background map을 만든다. full-resolution 휘도는 안전 clamp가 적용된 division normalization으로 paper target에 맞춘다.
- 밝은 휘도, 낮은 LAB chroma, 낮은 9x9 local texture를 동시에 만족하는 영역만 paper soft mask로 사용한다. smoothstep LUT가 이 영역의 높은 tone만 white 쪽으로 압축하므로 사진·컬러 도표와 dark foreground의 계조는 유지된다. 종이 주변의 약한 gray component는 함께 완화되어 bleed-through가 억제된다.
- 앞면 문자와 표 선은 밝은 background 위의 강한 local dark-detail로 분리한다. 전역 CLAHE 대신 foreground tone curve를 적용하고 Laplacian edge와 교차하는 부분에만 24% unsharp candidate를 반영해 paper texture와 JPEG noise의 재강조를 제한한다.
- LAB a/b 중성화는 전역 적용하지 않고 paper mask 안에서만 34% 적용한다. 컬러 글자·그래프·로고·사진은 chroma/texture mask로 whitening과 중성화 대상에서 제외한다.
- Grayscale은 RGB 평균 대신 luminance 변환 뒤 같은 배경 정규화·국부 대비·가벼운 sharpening을 사용한다. Black & White는 정규화 휘도에 3x3 median과 해상도 비례 adaptive Gaussian threshold를 적용한다.
- 최종 출력은 Perspective 해상도를 유지한 JPEG quality 96이다. 분석 map만 축소하고 full-resolution mask 합성은 8-bit 차이 영상으로 수행해 float Mat 중복을 피한다. 모든 중간 `Mat`은 성공·실패 경로에서 즉시 release한다.
- DEBUG 로그는 background analysis, normalization, whitening, foreground enhancement, sharpening, 전체 enhancement 시간을 각각 기록한다. Release에서는 기존 `isDebuggable` guard로 상세 로그를 남기지 않는다.
- 출력은 `.enhanced_*.pending.jpg`에 먼저 쓰고 성공 후 `enhanced_*.jpg` revision으로 확정한다. 실패하면 상태만 failed로 기록하고 corrected/raw 참조를 보호한다.

## Scan Result UX

- Camera의 기본 촬영 흐름은 raw 저장·문서 검출·자동 Perspective Correction·Scan Color Enhancement를 처리 큐에서 실행하고 Camera Preview를 유지한다. 자동 Curved Correction은 안정성 우선으로 아직 실행하지 않으며 상세 편집에서만 `책/곡면 문서 보정`으로 수동 선택한다.
- Capture Guide는 화면 비율에서 계산한 normalized 영역으로 전달되고, 검출 결과의 원본 크기가 확인되면 source-pixel Corner로 변환해 session.json에 저장된다. 편집은 사용자 수정 Corner, 자동 검출 Corner, 저장된 Guide Corner 순서로 복원한다.
- Camera에는 촬영 완료 버튼을 두지 않는다. 최근 스캔본과 페이지 수 Badge가 PDF Selection Gallery 진입점이며, Gallery Back은 Session을 유지한 Camera로 돌아간다.
- Gallery는 enhanced → corrected → raw 우선 대형 반응형 Grid, 전체/개별 선택, 삭제와 상세 Viewer 진입만 제공한다. 선택 snapshot은 현재 Session 순서로 Review에 전달한다.
- `PdfPageReviewPage`는 선택된 페이지만 담은 자체 배열을 소유한다. Long Press Drag 중에는 route pop과 PDF 실행을 차단하며, 정렬 결과는 Session 배열을 변경하지 않는다. Review Viewer는 선택 snapshot과 자체 PageController만 소유한다.
- Viewer는 페이지의 화질 모드를 반영해 enhanced → corrected → raw 순서로 표시한다. `PageView` Swipe, 현재/전체 페이지 표시, 재촬영·편집·삭제만 제공한다.
- 상세 편집은 원본, Corner, 수동 재보정, 회전을 담당한다. 전체 썸네일과 Drag & Drop 재정렬은 별도 페이지 관리 화면의 책임이다.
- 재촬영 후보는 Session에 넣기 전에 raw·검출·Perspective 저장을 모두 완료한다. 성공 시에만 기존 위치를 교체하고, 이후 이전 raw/corrected revision을 삭제한다.
- Recovery에서 이어하기를 선택하면 PDF Selection Gallery를 연다. 삭제 후 새 스캔은 Session을 제거하고 Camera로, Gallery Back은 Session을 유지한 Camera로 이동한다.

## OCR 제목 제안 계층

- Flutter의 `OcrService` 계약과 `AndroidLocalOcrService` MethodChannel 구현을 분리해 Review UI가 ML Kit API에 직접 의존하지 않는다.
- Android는 bundled Google ML Kit Text Recognition v2 Korean 모델을 사용한다. 전용 단일 background executor가 최대 변 2048px로 축소 decode한 후 ML Kit task 완료를 기다리며, Bitmap은 성공·실패 경로에서 즉시 recycle한다. 모델 다운로드나 클라우드 전송은 없다.
- `OcrResult` → block → line 모델은 원문, 좌표, 선택 confidence·language, source page/dimension을 보존해 향후 searchable PDF를 추가할 수 있게 한다. M9에서는 제목 추출에만 사용한다.
- Review 진입 후 background 제안을 시작하고, 정렬·미리보기·PDF 버튼은 유지한다. 첫 페이지 인식/제목 추출이 실패하면 두 번째 페이지를 한 번만 시도한다.
- `PdfTitleExtractor`는 상단 거리·글자 높이·짧은 제목 길이·confidence를 score로 사용하고 숫자, 페이지 번호, 날짜, 긴 문장을 제외한다. 결과는 50자로 제한한 후 PDF 파일명 정책으로 sanitize한다.
- 인식 실패는 정상적인 optional 상태이며 `Scana_yyyyMMdd_HHmm` fallback으로 PDF 생성을 계속한다. 성공한 제안만 Session에 저장해 Recovery 후 재사용한다.

## PDF Export 계층

- `PdfExportSelection.fromOrderedRawPaths`는 Review가 확정한 `rawImagePath` 순서대로 페이지만 수집한다. PDF 순서는 `pageNo`가 아니라 Review의 최종 배열 순서다.
- 입력은 페이지 모드를 반영한 `enhancedImagePath ?? correctedImagePath ?? rawImagePath`로 결정하고, 원본 모드는 corrected를 사용한다. 파일을 변경하지 않은 채 PDF `MemoryImage` orientation으로 0/90/180/270 회전을 적용한다.
- `PdfPageSizingPolicy.fitImage`는 회전 후 이미지 종횡비를 유지하면서 페이지 자체를 같은 비율로 구성해 왜곡과 불필요한 여백을 피한다. 향후 A4/Letter 정책을 같은 계약에 추가할 수 있다.
- `DartPdfGenerator`는 별도 isolate에서 페이지 파일을 하나씩 읽고 진행률을 UI로 전달한다. 문서는 앱 임시 디렉터리의 pending PDF로 생성하고 PDF 헤더와 파일 크기를 검증한다.
- Android `pdf_storage` MethodChannel은 `ACTION_OPEN_DOCUMENT_TREE`로 폴더를 선택하고 persistable read/write URI permission과 최근 URI를 앱 SharedPreferences에 보관한다. `DocumentsContract.createDocument`로 최종 PDF를 생성하며 광범위 저장소 권한은 사용하지 않는다.
- `PdfExportWorkflow`만 생성 → 임시 파일 검증 → SAF 기록 검증 → `deleteAfterSuccessfulExport()` 순서를 조정한다. 취소나 어느 단계의 실패도 Session 정리를 호출하지 않는다.
- `PdfExportResult`는 Session 삭제 후에도 `documentUri`, `displayName`, `byteLength`, `pageCount`를 유지한다.
- Review의 export flow는 버튼 탭 시점부터 단일 guard로 파일명 → 안정 frame → SAF → 안정 frame → 생성 순서를 직렬화한다. SAF 복귀 후 진행 상태는 Dialog route가 아니라 Review 내부 `ModalBarrier` overlay로 표시한다.
- PDF 성공 시 Review 내부 완료 overlay가 파일명·페이지 수와 `새 스캔`/`파일 열기`를 표시한다. `새 스캔`을 누를 때만 Review → Gallery → Camera를 정리하며 다음 촬영은 새 UUID를 사용한다.
- Android `pdf_document` MethodChannel은 SAF content URI를 `ACTION_VIEW`, `application/pdf`, `FLAG_GRANT_READ_URI_PERMISSION`으로 연다. Viewer가 없거나 열기가 실패해도 완료 overlay와 저장 결과를 유지한다.
- Android SAF 계층은 pending `MethodChannel.Result`를 하나만 보유하고 Activity 결과 수신 전에 참조를 제거한다. picker 실행 실패와 FlutterEngine 정리도 pending result를 정확히 한 번 완료하며 Flutter Navigation에는 관여하지 않는다.

## Navigation과 객체 소유권

- 앱 최상위 flow만 `CameraSession`과 `ScanSessionManager`를 소유하며, 소유권을 명시적으로 전달받은 경우에만 dispose/close한다. Camera, Gallery, Viewer와 Review는 주입받은 manager를 dispose하지 않는다.
- Viewer의 PageController와 Review Viewer의 PageController는 각 route가 생성하고 같은 route가 dispose한다. Review 정렬 배열과 PDF 진행 ValueNotifier도 Review route만 소유한다.
- PDF 파일명 입력의 `TextEditingController`는 `PdfFileNameDialog` State가 생성하고, Dialog route의 reverse transition을 포함한 실제 widget teardown 시점의 `State.dispose()`에서 해제한다. 호출자는 Dialog 결과만 받으며 controller를 소유하지 않는다.
- 0페이지 알림을 받은 비활성 route는 `Navigator.pop`을 실행하지 않는다. 현재 route만 pop하고, 상위 route에는 명시적인 결과를 반환하여 중첩 pop과 route teardown 경쟁을 방지한다.

## 화면 방향 계층

- `ScreenOrientationController`가 Single Camera=Portrait Up, Spread Camera=Landscape Left/Right, Content=Portrait Up 정책을 한 곳에서 관리한다. 각 화면은 `SystemChrome` 상수를 직접 복제하지 않는다.
- Camera는 Gallery route를 push하기 전 Content Portrait 요청을 await해 첫 Gallery frame이 Landscape로 그려지는 flicker를 줄인다. Gallery가 pop되면 다시 현재 `ScanSessionManager.captureMode`를 읽어 Camera 방향을 복원한 후 기존 Preview analysis만 재개한다.
- Gallery, Scan Result Viewer, Page Editor, PDF Review는 진입 시 Content Portrait을 요청한다. Review는 app lifecycle `resumed`에서도 Portrait을 재적용해 외부 PDF Viewer가 Scana 방향을 변경하지 못하게 한다.
- 방향 전환은 CameraSession/CameraController를 재생성하지 않는다. 현재 새 Session 정책은 직전 capture mode를 메모리에 유지하므로 Spread PDF 완료 후 `새 스캔`도 Landscape Camera로 복귀한다.

## DEBUG 진단 계층

- DEBUG 빌드는 `FlutterError.onError`와 `PlatformDispatcher.instance.onError`에서 exception과 전체 stack을 기록하되 기존 Flutter 오류 표시 동작은 그대로 호출한다.
- 로그는 Application Support의 `debug/scana_debug.log`에 append/flush 방식으로 남기며 Release 빌드에서는 기록과 내보내기를 비활성화한다.
- 전역 `NavigatorObserver`, Flutter/Android lifecycle, 주요 Scan route와 소유 객체의 init/dispose, PDF 단계, Android SAF 요청 ID와 `MethodChannel.Result` 완료를 같은 파일에서 시간순으로 추적한다.
- Camera의 DEBUG 전용 `진단 로그 내보내기`는 앱 재시작 뒤에도 누적 로그를 `text/plain` 문서로 내보낸다. 이 경로는 진단 전용이며 PDF 저장 구현을 변경하지 않는다.
- M7.2.3 실기기 로그에서 최초 오류는 caller가 filename Dialog의 controller를 route teardown보다 먼저 dispose한 것으로 확인됐다. `_dependents.isEmpty`와 Duplicate GlobalKeys는 후속 증상이었으며 SAF 구조는 유지한다.

## 폴더 책임

- core: 전역 설정, 오류, 공통 계약
- data: 로컬 데이터 소스와 저장소 구현
- features: 기능별 화면과 유스케이스
- models: 도메인 모델
- services: 플랫폼 및 향후 네이티브 연동
- shared: 기능 간 공유되는 요소
- utils: 부수 효과 없는 보조 함수
- widgets: 재사용 UI 구성요소
