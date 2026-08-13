# 아키텍처

## Scana V1 — AI Primary Crop + Visibility-Safe Boundary

FairScan은 비교 PoC가 아니라 촬영 후 최종 crop의 primary detector다. 처리 우선순위는 `AI Final(Refined/Hybrid) → AI Raw safety fallback → OpenCV/Q1.x fallback → Guide fallback`이며, 실제 선택 결과를 `ScanPage.documentCorners`, `pageBoundary`, `CropSource`에 저장한 뒤 같은 네 점을 Perspective에 전달한다. `CropSource`는 `aiRefined`, `aiHybrid`, `aiRawFallback`, `openCvFallback`, `guideFallback`, `manualCorners`를 구분하고 기존 값의 Recovery 호환성을 유지한다.

`AiPaperBoundaryRefiner`는 Top/Right/Bottom/Left를 독립 평가한다. 각 변은 transition score, supporting sample ratio, source border distance, occlusion penalty, confidence와 `confirmed / weak / occluded / out_of_frame / unknown` 상태를 가진다. `confirmed`만 refined edge를 그대로 사용한다. 나머지는 AI raw보다 안쪽으로 들어가지 않으며 비례 안전 여백을 적용해 하나의 hybrid polygon을 만든다. 한 변의 증거가 약해도 나머지 확정 변을 폐기하지 않는다.

Bottom edge 아래의 AI foreground, edge density, 밝고 저채도인 paper-like 영역을 search ROI 안에서 추가 검사한다. 종이·본문이 계속되는데 강한 paper/background transition이 없으면 bottom을 `unknown`으로 내리고, 일반 변보다 큰 3.5~7% 안전 여백을 적용한다. 화면 경계까지 종이가 이어지는 경우도 inward edge로 해석하지 않는다. DEBUG에는 AI Raw, AI Refined, AI Final, mask와 OpenCV overlay를 남긴다.

Quick Corner Edit의 초기값은 후보 우선순위를 다시 계산하지 않고 현재 실제 final crop인 `ScanPage.documentCorners`만 사용한다. 적용 전 source bounds, convex/order, 최소 면적을 검증하고 `manualCorners`로 영속화한다. 이후 raw 원본에서 Perspective → 자동 곡률 분석 → 조건부 Curved Dewarp → 현재 Enhancement의 production pipeline 전체를 다시 실행하며 OCR은 재실행하지 않는다. 취소는 파일과 세션을 변경하지 않고, 수동 모서리는 자동 검출이 덮어쓰지 않는다.

## AI-PoC 4 — Conservative Refinement + Quick Corner Edit

AI Refined의 마지막 자동 튜닝은 각 변을 동일하게 넓히지 않는다. Top/Right/Bottom/Left마다 paper/background transition 42%, continuity 18%, main-page ownership 20%, adjacent 안전도 14%, occlusion 안전도 6%로 허용 확장량을 계산한다. 증거가 약한 변은 기존 AI Raw 선을 보존하며, Spread spine 방향은 기존 5.5% 상한을 유지한다. Paper-like connected component가 둘 이상이면 AI centroid에 가까운 주 페이지와 두 번째 큰 영역을 분리해 상대 면적·spine 방향·거리로 adjacent penalty를 강화한다.

AI Raw는 면적만으로 판정하지 않는다. source 대비 폭·높이, 중앙 포함, 하단 접근성, inset된 큰 사각형과 paper candidate 확장량을 결합해 본문 박스·표 같은 partial region만 hard reject한다. Refined hard reject는 `partial raw / foreground clipped / expansion / shrink / adjacent merge / ownership / geometry`로 분리하고, 통과했지만 한 변 이상이 evidence cap에 제한되었거나 confidence가 낮으면 `accepted_conservative`로 기록한다. 기존 PoC 3 status는 읽기 호환을 유지한다. V1에서 이 결과는 visibility-safe final 단계의 입력으로 승격되었다.

`QuickCornerInitialPolicy`는 현재 실제 final crop을 그대로 초기 네 점으로 사용한다. `QuickCornerEditPage`는 source 크기와 viewport에서 `BoxFit.contain` display rect를 한 번 계산해 이미지 위치·크기·scale을 편집 종료까지 고정한다. background drag, one-finger pan, pinch zoom과 `InteractiveViewer` transform은 사용하지 않고 polygon과 44dp touch target의 선택된 corner만 움직인다. 화면↔source 변환과 source bounds clamp는 동일한 불변 transform을 사용하며 확대경 없이 선택점을 강조한다. 적용 시 `CropSource.manualCorners`를 영속화한 후 원본 high-resolution Perspective와 현재 M8.1 Enhancement 모드를 순차 재실행하고 원래 Gallery/Viewer/PDF Review route로 pop한다. 자동 detector는 수동 corner 페이지를 다시 덮어쓰지 않는다. 실패 시 기존 revision 파일과 세션은 유지한다.

## AI-PoC 3 — AI Refined Boundary Stabilization

PoC 2의 search ROI/paper candidate 구조를 유지하면서 main-page ownership, outer envelope, generic occlusion 내성을 강화한다. AI primary mask를 반응형으로 dilate한 ownership prior와 paper-like mask를 교차해 후보가 반대 페이지·다른 흰 물체로 넘어가는 범위를 먼저 제한한다. 후보는 AI containment 55%, centroid proximity 25%, component intersection 20%의 ownership score가 0.66 이상이어야 한다.

Adjacent-page penalty는 raw 대비 면적 성장, spine 방향 overshoot, component projection의 narrow-connection valley를 결합한다. Spread left는 오른쪽, right는 왼쪽을 spine 방향으로 취급하며 penalty 0.66 이상 또는 최종 면적 1.55배 초과는 refined 결과를 거부한다. Outer edge는 top/bottom과 함께 핵심 anchor이고, spine edge가 약해도 outer + top/bottom 중 하나가 안정적이면 geometry를 유지한다.

Paper contour는 단일 extreme이나 `approxPolyDP`보다 각 raw edge의 바깥 법선 projection 88 percentile로 outer envelope를 구성한다. 이 방식은 curved top/bottom의 바깥쪽 샘플을 보수적으로 포함하고 손가락 때문에 생긴 국소 inward indentation을 무시한다. 변별 샘플은 offset/color median과 MAD 2.8배 기준으로 outlier를 제거하고 18% trimmed mean으로 fitting한다. Bottom occlusion이 크면 손 contour를 따르지 않고 AI raw bottom 또는 안정된 envelope offset으로 복구한다. Refinement는 기본적으로 outward-only이고 paper evidence가 있으면 최소 0.6% margin을 허용한다.

`refinedConfidence`는 containment, 적정 expansion, transition, envelope consistency, edge continuity, geometry sanity에서 adjacent/occlusion penalty를 차감한다. 상태는 `accepted`, `accepted_occlusion_recovered`, `refined_rejected_adjacent_page`, `refined_rejected_occlusion`, `refined_rejected_expansion`, `refined_rejected_shrink`, `refined_rejected_geometry`, `raw_fallback`으로 영속화한다. DEBUG UI에는 ownership/occlusion/adjacent/quality/status를 표시하며 `*_ai_envelope_overlay.jpg`는 AI raw, paper contour, outer envelope, final refined를 함께 표시한다. Production Q1.x crop은 계속 변경하지 않는다.

## AI-PoC 2 — AI Segmentation + Paper Edge Refinement

AI-PoC 1의 FairScan mask와 raw 4-corner는 문서 위치 prior로만 사용한다. 실제 종이 외곽 진단은 `AiPaperBoundaryRefiner`가 담당하며, 기존 Q1.x OpenCV crop/Perspective 입력에는 연결하지 않는다.

```text
raw JPEG
├─ Q1.x OpenCV → 기존 production crop (변경 없음)
└─ FairScan mask → AI raw boundary
   → 최대 1280px 분석 이미지
   → mask bbox 비율 확장 search ROI
   → LAB 밝기/채도 paper candidate + AI overlap/centroid ownership
   → 각 변 바깥 방향 LAB transition/gradient 탐색
   → conservative corners + containment/expansion sanity
   → AI refined boundary (DEBUG 진단만)
```

Search ROI는 mask bbox를 좌우 10%, 상하 14% 확장하고 source bounds로 제한한다. Paper candidate는 LAB 밝기·저채도 mask를 morphology한 external component 중 AI foreground 82% 이상 포함, AI centroid 소유, AI raw 대비 0.90~1.85배 면적만 평가한다. 후보 점수는 containment 52%, 적정 expansion 20%, paper/background transition 28%다.

Top/Right/Bottom/Left는 각각 바깥 법선 방향으로 독립 탐색한다. LAB 안/밖 색차, luminance 차, Sobel edge를 13개 지점에서 robust median/support로 평가한다. Spread의 spine 방향은 outward search를 5.5%로 줄이고 외측은 10%를 허용한다. Paper component가 1.48배보다 커지면 corner prior로 채택하지 않고, 최종 refined polygon은 convex/order/source bounds, AI foreground 94% 이상 포함, raw 면적 0.96~1.55배, 충분한 transition을 만족해야 한다. 이중 면적 제한으로 인접 페이지 병합을 방지하며, 실패하면 AI raw boundary를 비교 결과로 유지한다.

DEBUG `debug_ai/`에는 AI raw, AI refined, search ROI/paper contour, mask, OpenCV overlay를 저장한다. Page Editor는 `원본 / OpenCV / AI Raw / AI Refined / AI Mask`를 비교하며 `[AI_REFINEMENT]` 로그에 단계별 timing과 containment/expansion/transition metric을 남긴다. Release artifact는 계속 비활성화한다.

## AI-PoC 1 FairScan Document Segmentation 비교

기존 OpenCV/Q1.3 crop pipeline은 primary 결과로 그대로 유지한다. 저장된 raw JPEG마다 같은 직렬 background image-processing queue에서 OpenCV 검출을 먼저 수행하고 FairScan segmentation을 보조 진단으로 실행한다. AI 실패, 빈 mask, tensor mismatch 또는 잘못된 corner는 촬영·Perspective·Gallery·OCR·PDF에 영향을 주지 않는다.

```text
raw JPEG 또는 Spread left/right raw ROI
├─ OpenCV/Q1.3 → 실제 Crop/Perspective
└─ FairScan TFLite → probability mask → DEBUG 비교 결과만 저장
```

`FairScanDocumentSegmenter`는 앱 asset의 FairScan v1.2.0 모델을 LiteRT 1.4.1 CPU/XNNPACK 2 threads로 한 번 lazy-load하고 재사용한다. 입력/출력 tensor가 각각 FLOAT32 `[1,256,256,3]`, `[1,256,256,1]`인지 런타임에 검증한다. JPEG는 OpenCV로 decode하고 RGB 256×256 bilinear stretch 후 `(value-127.5)/127.5`로 정규화한다.

출력은 FairScan Android 구현과 같이 0~1 clamp 및 0.5 threshold를 적용한다. 5×5 morphology close/open 뒤 면적 범위, 중심 포함/근접도, 비정상 종횡비를 함께 점수화해 plausible external component를 선택하고, convex hull, 단계적 `approxPolyDP`, 최종 `minAreaRect` fallback으로 네 모서리를 원본 좌표에 복원한다. Single은 전체 raw에서 한 번, Spread는 기존 overlap split이 만든 left/right raw ROI에서 각각 독립 실행한다.

DEBUG 빌드만 `scan_sessions/<id>/debug_ai/`에 raw copy, AI mask, AI boundary/mask overlay, OpenCV boundary overlay를 저장한다. `ScanPage.aiSegmentationResult`에는 timing, coverage, confidence, corners와 세션 기준 상대 artifact 경로만 저장한다. Page Editor의 `AI 검출 비교`에서 원본/OpenCV/AI Boundary/AI Mask를 전환한다. Release에서는 비교 artifact를 만들지 않는다.

## Q1.3 WYSIWYG Capture Boundary

셔터 시점에 Camera Overlay에 표시되는 정상 범위의 live boundary를 불변 `CaptureBoundarySnapshot`으로 고정한다. 스냅샷은 UI 좌표가 아니라 detector analysis-frame 픽셀 좌표, frame 크기, sensor/device/JPEG 회전, capture mode, Spread side, confidence와 stability를 보존한다. 이후 frame, autofocus, orientation listener의 변경은 이미 생성된 스냅샷에 영향을 주지 않는다.

```text
Displayed sane Live Boundary
→ Capture Boundary Snapshot
→ Analysis-frame/JPEG 직접 좌표 변환
→ 제한적 High-resolution refinement (최대 2~5%)
→ Perspective
```

최종 crop 우선순위는 `captureLiveBoundary → highResPaperBoundary → contentSafe → guideFallback`이다. Capture boundary가 있으면 고해상도 후보는 이를 대체하지 않고 가까운 모서리/edge 보정 후보로만 사용한다. 모서리 평균 이동 3.5%·최대 이동 5%, 안쪽 edge 이동 2.5%, 면적/폭/높이 96% 보존 조건을 벗어나면 refinement를 거부하고 화면에 보였던 capture boundary를 그대로 사용한다.

Single은 한 개, Spread는 좌/우 스냅샷과 fallback을 독립 관리한다. Spread live boundary는 full analysis frame 기준으로 저장한 뒤 JPEG 방향으로 회전하고 overlap ROI 좌표로 한 번만 변환한다. `CropSource`, `captureBoundaryConfidence`, `captureBoundaryStability`는 `ScanPage`와 `session.json`에 기록하며 기존 `paperBoundary`와 `stableLiveFallback` 값도 계속 읽는다. DEBUG의 `CAPTURE_BOUNDARY`와 `CAPTURE_BOUNDARY_WARNING`은 변환 좌표, refine 판정, 최종 source, corner/area 차이를 추적한다.

Live overlay는 최근 경계를 750ms 유지한다. 빨강/주황은 참고용으로 최종 crop에 사용하지 않고, sane한 노랑/초록 경계만 셔터 시점 crop 후보가 된다.

## Q1.2 Multi-stage Page Crop Strategy

Live guide와 최종 crop은 서로 다른 정책을 사용한다. Live는 detector의 best candidate가 있으면 낮은 confidence도 주황, 중간은 노랑, 안정·고신뢰는 초록으로 표시한다. Single과 Spread 좌/우 controller는 서로 독립적이므로 한쪽 후보만 있어도 해당 overlay를 유지한다.

Capture 가능한 live boundary가 없는 경우의 Q1.2 fallback은 다음 순서로 보수적으로 결정한다.

1. `highResPaperBoundary`: 기존 edge/contour 후보와 LAB paper-region 후보 중 geometry, 점유율, 종이/배경 전이, internal-line penalty를 통과한 고신뢰 경계
2. `contentSafe`: paper 경계가 불확실할 때 충분한 수와 분포를 가진 dark foreground component 전체에 비율 기반 안전 여백과 최소 68% 폭·높이를 적용한 crop
3. `guideFallback`: 앞 단계가 모두 불가능할 때 Single capture guide 또는 Spread 좌/우 conservative inset 사용

Android detector는 최대 변 1400px 분석 이미지에서 LAB의 넓은 low-chroma prior와 Otsu/Adaptive luminance를 결합하고 Close/Open morphology로 인쇄·악보·표가 만든 내부 구멍을 메워 paper-like connected region을 만든다. Content 분석은 adaptive foreground component 중 크기·위치·밀도 조건을 통과한 구조만 집계한다. sparse/blank/사진 위주로 신뢰할 수 없는 경우 content fallback을 만들지 않는다. 최종 Perspective는 계속 원본 해상도 좌표를 사용한다.

`CropSource`는 `ScanPage`와 `session.json`에 저장한다. DEBUG의 `CROP_DECISION`은 paper/content/live 가용성, component 수, margin, 최종 비율과 fallback 이유를 기록하고 `LIVE_GUIDE`는 confidence, stability, 표시 등급과 bounds를 기록한다.

## UX-Q1 표현 계층

`LiveDocumentDetectionController`의 기존 throttle/stabilization 결과를 CameraPreview 내부에 그린다. Spread는 좌/우 ROI 요청을 별도로 사용한다. PDF Review의 임시 PDF 순서와 Grid 애니메이션은 분리하며, 앱 루트는 재개 시에도 non-immersive system bar 정책을 적용한다.

## Q1.1 실기기 피드백 반영

- Live boundary는 preview 전용 저신뢰 후보도 약하게 표시하고, sensor와 현재 device orientation을 조합한 회전으로 CameraPreview 실제 bounds에 투영한다.
- PDF Review는 pointer 위치를 responsive Grid index로 바꿔 drag-hover 중 `_orderedPages`를 갱신한다. Drop에서는 두 번째 reorder를 수행하지 않는다.
- 고해상도 crop은 page-sized geometry, paper/background transition, 반복 수평 internal-line evidence를 경쟁 후보 선택에 함께 사용한다. Stable-live fallback에도 geometry sanity gate를 적용한다.
- DEBUG의 `LIVE_GUIDE`, `CROP_DECISION`, `PAGE_DETECTION`, `PDF_REORDER` 항목으로 live/high-res/final crop source를 구분한다.

## 원칙

기능은 모듈 단위로 분리하고, UI가 플랫폼 또는 이미지 처리 구현에 직접 의존하지 않도록 설계한다.

## 처리 흐름

카메라 프리뷰 → 촬영 가이드 → ScanSession → 원본 저장 → 문서 검출 → 자동 원근 보정 → 자동 Scan Color 화질 보정 → Gallery/Viewer → (상세 편집 또는 페이지 관리) → PDF Review → 선택 첫 페이지 OCR 제목 제안 → PDF 생성 → 사용자 지정 위치 저장 → 완료 확인/파일 열기

촬영 직후 PDF를 만들지 않는다. 원본과 각 보정 단계의 결과를 분리해 재편집과 재촬영을 지원한다.

## ScanSession 영속화

- 작업 파일은 앱 전용 영속 디렉터리의 `scan_sessions/<session_uuid>/`에 저장한다.
- `session.json`에는 Session ID, 생성 시간, 페이지 배열 순서, raw/corrected/enhanced 상대 파일명, 페이지 번호, 생성 시간, 회전, 원본 크기, 선택적 문서 모서리 좌표, `cropSource`, 보정 상태와 선택적 `suggestedTitle`/`ocrSourcePageNo`를 저장한다.
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

### Q1 Book/Page Boundary Detection Quality Improvement

- 실제 책과 악보에서는 Hough 직선, 오선, 표선, 내부 frame이 종이 외곽보다 강할 수 있으므로 직선 지지율은 보조 evidence로만 사용한다.
- Single 후보는 ROI 점유율, 네 변의 border proximity, 경계 안/밖 luminance·local variance 차이, 밝은 종이 배경과 dark foreground 구조, rectangularity와 edge continuity를 함께 평가한다.
- ROI 중앙의 작은 후보, 폭·높이가 ROI의 30% 미만인 후보, 종이 같은 영역 양쪽에 놓인 선, 외부로 콘텐츠가 이어지는 후보에는 internal-line/small-candidate penalty를 적용한다.
- Spread의 10% overlap 분할 비율은 유지한다. 좌우 ROI는 독립적으로 평가하며 outer/top/bottom anchor가 충분하면 spine-side edge가 약해도 geometry 기반 후보를 유지한다.
- Spread의 수평 anchor는 edge strength만으로 선택하지 않고 안/밖 대비와 ROI 상·하단 위치 prior를 함께 사용해 오선을 page edge로 선택하는 위험을 줄인다.
- confidence는 순위 점수와 분리해 occupancy, paper interior, outside contrast, geometry, edge continuity와 penalty로 계산한다. 낮은 confidence 결과는 기존 stable-live/guide/보수적 ROI fallback보다 우선하지 않는다.
- DEBUG 빌드는 mode, ROI side, candidate count와 상위 3개 후보의 세부 점수 및 confidence만 기록한다.

## 페이지 보정 계층

- Flutter의 `PageCorrector` 계약은 UI와 OpenCV 구현을 분리하며 Android MethodChannel 구현만 네이티브 계층을 호출한다.
- 문서 모서리는 top-left → top-right → bottom-right → bottom-left 순서와 convex 여부를 검증한다.
- 원근 보정 출력은 위/아래 너비 중 최댓값과 좌/우 높이 중 최댓값으로 계산하고 `getPerspectiveTransform`과 `warpPerspective`를 적용한다. Perspective/Curved 최종 remap은 full-resolution `INTER_LINEAR`를 사용해 넓은 cubic kernel의 작은 글자 softening을 피하며 분석 축소에만 `INTER_AREA`를 사용한다.
- 곡면 보정은 먼저 Perspective 결과를 별도 파일로 확정하고, rectified 이미지의 전체 사각형 좌표계에서만 분석한다. RAW 좌표의 Corner/PageBoundary를 Perspective 이미지에 재사용하지 않는다. 곡면 출력은 같은 canvas 크기·종횡비, 유효 luminance를 검증한 뒤에만 채택한다.
- 곡면 confidence는 분석 영역 coverage 45%, 후보 evidence 30%, curve 간 consistency 25%로 계산하며 최소값 0.68을 유지한다. 실제 페이지 상·하단 curve, spine signal, 긴 text/staff 수평 구조를 evidence로 수집하되 단일 선은 충분한 증거가 아니다. DEBUG 및 `session.json`에는 confidence/threshold/component score와 `insufficient_evidence`, `insufficient_coverage`, `curvature_too_small`, `inconsistent_curve`, `geometry_invalid`, `deformation_excessive` 등의 rejection reason을 보존한다.
- 자동 곡률 분석은 전체 confidence와 곡률 크기를 분리해 `flat / mildCurve / strongCurve / unreliable`로 분류한다. 유효 evidence가 2개 미만이거나 coverage 0.48 미만, consistency 0.60 미만이면 `unreliable`이며, magnitude 0.0015 미만은 `flat`, 0.008 미만이면서 confidence 0.56·coverage 0.52·consistency 0.72 이상이면 `mildCurve`, 그 이상이면서 기존 full-dewarp confidence 0.68을 만족하면 `strongCurve`다.
- FairScan refinement가 이미 계산한 owned paper contour를 crop scoring 변경 없이 선택 metadata로 전달한다. 최종 네 Corner는 계속 Perspective geometry의 source of truth이고, contour는 top/bottom/spine 곡률 evidence로만 사용한다. 각 contour는 Corner chord에 투영한 signed deviation을 source height로 정규화하므로 RAW 절대좌표를 rectified raster에 직접 재사용하지 않는다.
- Evidence fusion은 page geometry(top/bottom contour와 spread spine), internal structure(text/staff/diagram horizontal line), 방향 consistency를 분리한다. 명확한 contour 두 개가 일치하거나 contour 하나와 internal evidence가 같은 방향인 경우에는 기존 단일 confidence 기준보다 보수적인 geometry-MILD 경로를 허용한다. 반대 방향 evidence가 섞이면 크기가 커도 `unreliable`로 유지한다.
- `mildCurve`는 추정 변위의 55%만 적용하고 가장자리 taper, 유효 좌표, 단조성, canvas/aspect, 최대 높이 2.5% 변위 제한을 그대로 통과해야 한다. `strongCurve`만 full strength를 사용한다. 결과 직선성은 Perspective 대비 최소 0.5% 개선되어야 하며 개선이 없거나 geometry가 악화되면 pending Curved revision을 폐기하고 Perspective를 최종 geometry로 유지한다.
- MILD 결과는 변형량이 작으므로 horizontal straightness 0.05% 개선 또는 contour residual geometry 0.5% 개선 중 하나를 요구한다. STRONG은 기존 straightness 0.5% 개선 기준을 유지한다. 두 지표가 모두 개선되지 않으면 자동 폐기한다.
- 경계를 신뢰할 수 없을 때는 adaptive threshold와 수평 morphology에서 페이지 폭 35% 이상의 여러 장선분을 수집한다. 각 후보의 선형 기울기를 제거한 뒤 median/MAD outlier 제거, median aggregation, smoothing과 edge taper로 비대칭 deformation curve를 계산한다.
- 곡률 신뢰도 0.68 미만, 의미 없는 곡률, 높이 2.5%를 넘는 변위, 급격한 인접 차이, NaN/Infinity, 범위 밖 또는 역전되는 remap 좌표는 모두 실패로 처리하며 remap을 실행하지 않는다.
- 분석 이미지는 최대 변 1200px로 제한하며 최종 remap은 192행 strip 단위로 실행한다. 검출과 보정은 같은 단일 background executor에서 직렬 처리한다.
- 원근 출력 크기는 원본 좌표의 top/bottom 너비와 left/right 높이 중 최댓값을 사용한다. 일반 2500×3500px 문서는 축소하지 않으며 32MP를 넘는 비정상 대형 canvas에만 Android OOM 방지 상한을 적용한다. Perspective/Curved 결과는 숨김 pending PNG에 먼저 기록하고 성공한 경우에만 새 `corrected_*.png` revision을 확정한다. 기존 `corrected_*.jpg` session은 확장자 독립 metadata recovery로 계속 읽는다. Curved 단계 실패 시 직전에 확정한 Perspective 파일을 보호한다.
- Camera의 Single/Spread 고정 guide는 AI live boundary와 별도 layer로 항상 남으며 어두운/밝은 배경 모두에서 보이도록 외곽 대비선을 사용한다. Camera 화면의 DEBUG 버튼은 노출하지 않고 persistent diagnostics와 artifact/log 경로는 유지한다.
- PDF Selection Gallery는 thumbnail과 44px action row를 분리한다. 좁은 카드에서는 page label을 숨기고 32px compact icon constraint를 사용해 Preview/Quick Corner/Delete가 카드 밖으로 overflow하지 않게 한다. Gallery/Review route state가 살아 있으므로 Quick Corner 복귀 시 선택·순서·현재 scroll 위치를 유지하고 갱신된 thumbnail만 rebuild한다.
- Page Editor는 원본/보정본 전환, Perspective/Curved 수동 선택, 모서리 저장 후 재보정을 제공한다. Corner Preview에는 핸들 반경만큼 내부 여유를 두고 저장·보정 액션은 Preview 아래 SafeArea 툴바에 둔다.

## 화질 보정 계층

- Flutter의 `PageEnhancer` 계약과 `OpenCvPageEnhancer` 구현을 분리해 UI가 MethodChannel/OpenCV에 직접 의존하지 않는다.
- 촬영 처리 큐는 Detection → Perspective → 기본 `scanColor`를 기존 단일 Android executor에서 순차 실행하며 Camera Preview와 다음 촬영을 막지 않는다.
- M8.1 Scan Color는 LAB 휘도 채널의 최대 변 1200px 분석 이미지에서 morphology closing으로 문자 같은 작은 dark component를 제거한 뒤 broad Gaussian background map을 만든다. full-resolution 휘도는 안전 clamp가 적용된 division normalization으로 paper target에 맞춘다.
- 밝은 휘도, 낮은 LAB chroma, 낮은 9x9 local texture를 동시에 만족하는 영역만 paper soft mask로 사용한다. smoothstep LUT가 이 영역의 높은 tone만 white 쪽으로 압축하므로 사진·컬러 도표와 dark foreground의 계조는 유지된다. 종이 주변의 약한 gray component는 함께 완화되어 bleed-through가 억제된다.
- Foreground-first 실험의 source 3×3/9×9 dark-detail, 수평 black-hat, source luminance 72% 복원은 종이 질감·JPEG residue·비침까지 foreground로 되살리는 실기기 회귀를 만들어 제거했다. Scan Color는 M8.1의 보수적인 정규화 후 5×5 local dark-detail mask로 복원하며 종이의 모든 dark variation을 문자로 취급하지 않는다.
- Background normalization/soft whitening은 paper mask에만 적용하고 source luminance 전역 혼합은 M8.1의 7%로 유지한다. 최종 가독성 튜닝은 같은 foreground tone curve의 darkening을 20%, edge-limited sharpening을 17%로 완화한다. 전역 unsharp, aggressive morphology, 별도 staff detector를 추가하지 않으며 악보·얇은 도표선도 이 보수적 edge 경로로 처리한다.
- LAB a/b 중성화는 전역 적용하지 않고 paper mask 안에서만 34% 적용한다. 컬러 글자·그래프·로고·사진은 chroma/texture mask로 whitening과 중성화 대상에서 제외한다.
- Grayscale은 RGB 평균 대신 luminance 변환 뒤 같은 배경 정규화·국부 대비·가벼운 sharpening을 사용한다. Black & White는 정규화 휘도에 3x3 median과 해상도 비례 adaptive Gaussian threshold를 적용한다.
- Perspective/Curved/Enhanced 작업 결과는 full-resolution PNG로 보존해 RAW JPEG 이후 중간 JPEG 재압축을 제거한다. 분석 map만 축소하고 full-resolution mask 합성은 8-bit 차이 영상으로 수행한다. 기존 JPEG metadata/path도 Recovery·Viewer·PDF에서 계속 지원한다. 출력은 `.enhanced_*.pending.png`에 먼저 쓰고 성공 후 `enhanced_*.png` revision으로 확정한다.
- Viewer는 thumbnail/cache resize 없이 실제 `displayImagePath`를 사용하고 문서 표시에는 `FilterQuality.medium`을 적용한다. PDF는 enhanced → corrected → raw 우선순위의 동일 full-resolution bytes를 `MemoryImage`에 직접 전달하며 page physical size 계산과 raster pixel 수를 분리하고 pre-resize하지 않는다.
- DEBUG는 `debug_quality/<raw_stem>/`에 raw, perspective, optional curved, enhanced artifact와 PDF source metadata를 보존한다. Native variance-of-Laplacian은 전체와 text-like mask에서 각각 계산하고, 밝은 paper 후보의 local dark residual로 background variance와 dark speckle ratio도 기록한다. `[SCAN_QUALITY]`는 단계별 resolution, sharpness, foreground sharpness, background noise, format, bytes, processing time, PDF source를 기록한다. Enhanced foreground sharpness가 입력의 90% 미만이거나 dark speckle ratio가 1.75배이면서 1%p 넘게 증가하면 DEBUG 경고만 남기며 자동 fallback 정책은 변경하지 않는다.

## 자동 Production Correction Pipeline

- 신규 Single 페이지와 Spread의 Left/Right 페이지는 각각 `RAW → AI Final/OpenCV/Guide fallback corners → Perspective PNG → automatic curvature analysis → optional Curved PNG → selected Enhancement PNG`를 처리 큐에서 순차 실행한다.
- `flat`과 `unreliable`, 또는 Curved 안전성/품질 검증 실패는 제품 실패가 아니다. 확정된 Perspective 파일을 보호하고 Enhancement를 적용해 정상 완료하며, 사용자 UI에는 기술적인 곡률 실패 메시지를 표시하지 않는다.
- `ScanPage`와 `session.json`은 `perspectiveApplied`, `curvatureState`, `curvedApplied`, `curvedConfidence`, `curvatureMagnitude`, `curvedRejectReason`, `enhancementApplied`를 선택 필드로 저장한다. 기존 JSON은 correction/enhancement 상태로 기본값을 복원한다.
- DEBUG `[CURVED_AUTO]`는 페이지 번호, 상태, 적용 여부, detect/dewarp/total 시간, magnitude, coverage, evidence 수, consistency, confidence, strength, straightness 전후와 reject reason을 기록한다.
- DEBUG `debug_curvature/<raw-stem>/`에는 Perspective, contour/internal-line overlay, 적용된 dewarp preview와 `curvature_report.json`을 저장한다. Report는 combined/page/top/bottom/spine/internal magnitude, 방향 충돌, geometry·straightness 전후와 구체 reject reason을 포함한다.

## Scan Result UX

- Camera의 기본 촬영 흐름은 raw 저장·문서 검출·자동 Perspective Correction·곡률 분석·조건부 Curved Correction·Scan Color Enhancement를 처리 큐에서 실행하고 Camera Preview를 유지한다. 상세 편집 버튼은 고급 재시도 수단일 뿐 production 결과 생성의 필수 단계가 아니다.
- Capture Guide는 AI boundary 유무와 관계없이 항상 표시되며 CameraPreview → fixed guide → AI live boundary → controls 순서로 합성한다. Single은 문서 사각형, Spread는 전체 책 사각형과 10% overlap 정책의 중심 제본선을 사용한다. normalized guide는 원본 크기가 확인되면 source-pixel Corner로 변환해 session.json에 저장된다.
- Camera에는 촬영 완료 버튼을 두지 않는다. 최근 스캔본과 페이지 수 Badge가 PDF Selection Gallery 진입점이며, Gallery Back은 Session을 유지한 Camera로 돌아간다.
- Gallery는 enhanced → corrected → raw 우선 대형 반응형 Grid를 사용하고 Preview/Quick Corner/Delete 액션은 thumbnail 아래 별도 행에 둔다. 선택 snapshot은 현재 Session 순서로 Review에 전달한다.
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
- Camera 화면에는 DEBUG 버튼을 노출하지 않는다. 영속 진단 로그, Page Editor AI 비교, 세션 debug artifact와 내부 export 구현은 유지한다.
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
