# 아키텍처

## 원칙

기능은 모듈 단위로 분리하고, UI가 플랫폼 또는 이미지 처리 구현에 직접 의존하지 않도록 설계한다.

## 처리 흐름

카메라 프리뷰 → 촬영 가이드 → ScanSession → 원본 저장 → 문서 검출 → 자동 원근 보정 → Scan Result Viewer → (상세 편집 또는 페이지 관리) → 곡면 보정 → 화질 보정 → PDF 편집 → OCR 제목 추천 → PDF 생성 → 사용자 지정 위치 저장

촬영 직후 PDF를 만들지 않는다. 원본과 각 보정 단계의 결과를 분리해 재편집과 재촬영을 지원한다.

## ScanSession 영속화

- 작업 파일은 앱 전용 영속 디렉터리의 `scan_sessions/<session_uuid>/`에 저장한다.
- `session.json`에는 Session ID, 생성 시간, 페이지 배열 순서, 원본/보정 파일명, 페이지 번호, 생성 시간, 회전, 원본 크기, 선택적 문서 모서리 좌표, 보정 상태와 보정 방식을 저장한다.
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

## Scan Result UX

- Camera의 기본 촬영 흐름은 raw 저장·문서 검출 후 자동 Perspective Correction을 처리 큐에서 실행하고 Camera Preview를 유지한다. 자동 Curved Correction은 안정성 우선으로 아직 실행하지 않으며 상세 편집에서만 `책/곡면 문서 보정`으로 수동 선택한다.
- Capture Guide는 화면 비율에서 계산한 normalized 영역으로 전달되고, 검출 결과의 원본 크기가 확인되면 source-pixel Corner로 변환해 session.json에 저장된다. 편집은 사용자 수정 Corner, 자동 검출 Corner, 저장된 Guide Corner 순서로 복원한다.
- 촬영 완료는 처리 중 장수를 확인한 뒤 Scan Document List를 연다. 목록은 스캔본 썸네일, 전체/개별 선택, Drag & Drop 순서 변경, 상세 Viewer 진입을 제공한다.
- Viewer는 corrected 이미지를 우선 표시하고 없을 때만 raw를 fallback으로 사용한다. `PageView` Swipe, 현재/전체 페이지 표시, 재촬영·편집·삭제만 제공한다.
- 상세 편집은 원본, Corner, 수동 재보정, 회전을 담당한다. 전체 썸네일과 Drag & Drop 재정렬은 별도 페이지 관리 화면의 책임이다.
- 재촬영 후보는 Session에 넣기 전에 raw·검출·Perspective 저장을 모두 완료한다. 성공 시에만 기존 위치를 교체하고, 이후 이전 raw/corrected revision을 삭제한다.
- Recovery에서 이어하기를 선택하면 Camera가 아닌 Scan Result Viewer를 연다.

## 폴더 책임

- core: 전역 설정, 오류, 공통 계약
- data: 로컬 데이터 소스와 저장소 구현
- features: 기능별 화면과 유스케이스
- models: 도메인 모델
- services: 플랫폼 및 향후 네이티브 연동
- shared: 기능 간 공유되는 요소
- utils: 부수 효과 없는 보조 함수
- widgets: 재사용 UI 구성요소
