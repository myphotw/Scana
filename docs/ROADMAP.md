# 로드맵

## Scana V1 — AI Primary Crop + Quick Corner Edit

- FairScan AI Final을 production primary crop으로 사용하고 `AI Refined → AI Hybrid → AI Raw safety fallback → OpenCV/Q1.x → Guide` 순서를 유지한다.
- 네 변의 transition/support/border distance/occlusion을 독립 기록하고 Unknown Edge를 inward edge로 해석하지 않는다.
- 하단 아래 전경·edge·paper-like 연속성을 검사해 페이지 번호와 하단 여백을 우선 보존한다.
- 실제 Perspective 입력과 DEBUG `AI Final`, `ScanPage.documentCorners`를 동일하게 유지한다.
- Quick Corner Edit는 현재 final crop에서 시작하며 적용 시 manual source를 영속화하고 Perspective→자동 곡률 분석→조건부 Curved Dewarp→Enhancement 전체를 재실행한다.
- 다음 단계는 Single/Spread 실제 책, 손가락 가림, 화면 밖 외곽 샘플에서 안전 여백과 fallback 품질을 검증하는 것이다.

## AI-PoC 4 + Quick Corner Edit fallback

- AI Raw의 page-sized extent·center·bottom proximity를 평가해 본문 박스/표 같은 partial region을 명시적으로 거부한다.
- 각 edge의 transition, continuity, ownership, adjacent, occlusion 증거에 따라 outward expansion을 독립 제한하고, 두 번째 paper component를 adjacent page evidence로 사용한다.
- Hard reject status와 `accepted_conservative`를 DEBUG 비교에 남기고 Single/Spread 실제 책으로 primary 전환 여부를 마지막 판단한다.
- Gallery/Viewer/PDF Review의 보이는 모서리 수정 action에서 경량 4-corner 화면을 열고 현재 실제 final crop을 초기값으로 제공한다.
- source/viewport의 BoxFit.contain rect를 고정하고 pan/zoom 없이 44dp hit target의 네 corner만 이동한다. 시야를 가리는 확대경 없이 적용 시 manual source 영속화, Perspective 및 현재 Enhancement 재생성 후 원래 위치로 복귀한다.
- 실사용이 여전히 불안정하면 자동 튜닝을 중단하고 Quick Corner Edit를 공식 fallback으로 유지한다.

## AI-PoC 3 — AI Refined Boundary Stabilization

- AI mask dilation ownership prior, centroid/component intersection으로 main page를 고정한다.
- 면적 성장·spine overshoot·narrow connection valley로 adjacent page penalty를 계산한다.
- Contour projection 88 percentile outer envelope와 MAD/trimmed fitting으로 curved margin을 보존하고 occlusion outlier를 제외한다.
- 하단 partial occlusion은 raw/envelope geometry로 복구하고 outer/top/bottom anchor가 충분하면 약한 spine edge를 허용한다.
- Explicit refine status/confidence와 envelope overlay를 실기기 비교에 사용하되 production primary 전환은 별도 결정한다.

## AI-PoC 2 — AI Segmentation + Paper Edge Refinement

- FairScan mask를 최종 crop이 아니라 문서 search prior로 사용하고 비율 확장 ROI 안에서 실제 paper/background transition을 찾는다.
- LAB paper-like component를 AI overlap·centroid ownership·면적 증가 제한으로 평가하고, 각 변을 outward 우선 탐색한다.
- AI foreground containment, convex ordering, 과도한 축소/확장 제한을 통과한 refined boundary만 DEBUG 비교 결과로 채택한다.
- Single과 Spread left/right ROI를 독립 처리하되 spine 방향 탐색 폭을 제한해 인접 페이지 병합을 방지한다.
- OpenCV / AI Raw / AI Refined 실기기 비교에서 실제 종이 여백·곡선 외곽·페이지 번호 포함 여부를 확인한 뒤 primary 전환 여부를 결정한다.

## AI-PoC 1 — FairScan TFLite Document Segmentation 비교

- FairScan v1.2.0 document segmentation model을 APK asset으로 포함하고 LiteRT CPU에서 완전 오프라인 실행한다.
- 기존 Q1.3/OpenCV crop을 교체하지 않고 같은 raw JPEG의 AI mask·corners·timing을 병렬 진단 결과로 수집한다.
- Single 전체 이미지 및 Spread left/right ROI를 독립 처리한다.
- DEBUG에서 raw, mask, AI overlay, OpenCV overlay를 세션 `debug_ai/`에 저장하고 Page Editor에서 비교한다.
- 실제 입문책 재촬영으로 페이지 전체 포함, 책상 배제, 내부선 내성, Single/Spread 정확도와 처리시간을 비교한 뒤 primary detector 전환 여부를 별도로 결정한다.

## Q1.3 — WYSIWYG Capture Boundary

- 셔터 순간 화면에 표시된 sane live boundary를 analysis-frame 좌표의 immutable snapshot으로 고정한다.
- UI preview 좌표를 역산하지 않고 sensor/device/JPEG 회전을 반영해 full-resolution JPEG 좌표로 직접 변환한다.
- Capture boundary를 최우선 crop으로 사용하며 high-resolution 검출은 2~5% 범위의 제한적 refinement로만 허용한다.
- 과도한 corner 이동, 안쪽 축소, 면적·폭·높이 감소는 거부하고 capture boundary를 보호한다.
- Live boundary가 없을 때만 `High-res Paper → Content Safe → Guide` Q1.2 fallback을 사용한다.
- Spread 좌/우 snapshot, 좌표 변환, crop source와 실패 fallback을 서로 독립 처리한다.
- `CAPTURE_BOUNDARY` 진단 및 session metadata로 Overlay와 결과 차이를 추적한다.

## Q1.2 — Multi-stage Page Crop Strategy

- Q1.3 capture snapshot이 없는 경우 최종 crop을 `High-res Paper Boundary → Content Safe Crop → Guide Fallback` 순서로 결정한다.
- LAB luminance/chroma와 local brightness, morphology, connected region으로 edge보다 종이 덩어리를 우선하는 후보 경로를 추가한다.
- paper 검출 실패 시 충분한 foreground component bounds에 반응형 안전 여백을 적용하고, sparse/blank/불확실한 사진 페이지는 guide로 넘긴다.
- Live overlay는 최종 crop confidence와 분리해 낮은 best candidate도 표시하며 Spread 좌/우를 독립 표시한다.
- `CropSource`, `CROP_DECISION`, `LIVE_GUIDE` 진단으로 실기기 튜닝 근거를 보존한다.

## Q1.1 검증

- Camera에서 unstable/stable live boundary 표시 및 Portrait/Spread 좌표 확인
- PDF Review에서 여러 row와 2~4 column을 넘나드는 live reorder 확인
- Minuet 악보 재촬영으로 narrow content crop 감소와 Spread 배경 포함 감소 확인
- DEBUG candidate breakdown을 다음 실기기 튜닝 근거로 보관

## M1 — 기반 구조

Android 전용 Flutter 앱 진입 구조, 모듈 폴더, 요구사항·설계·라이선스 문서를 준비한다.

## M2 — Camera Foundation

Android 카메라 프리뷰와 권한 처리를 구현한다.

## M3 — Scan Session & Recovery

촬영 원본 보관, Session Recovery, 앱 전용 영속 저장 구조를 구현한다.

## M4 — Scan Guide & Page Editor Foundation

반응형 촬영 가이드와 페이지 선택·삭제·순서 변경·회전 메타데이터 편집을 구현한다.

## M5 — Document Detection Foundation

OpenCV 기반 촬영 이미지 문서 검출, 모서리 Overlay, 수동 Corner 조정과 영속화를 구현한다.

## M6 — Perspective Correction & Page Flattening

OpenCV 원근 변환, 경계/inset 기반의 보수적 곡면 평탄화, Guide Corner 영속화와 연속 촬영·Scan Document List·Viewer 중심 UX를 구현한다.

### V1 Stabilization

- Curved 입력을 Perspective rectified 좌표계로 고정하고 출력 canvas/luminance 검증과 Perspective fallback 재화질보정을 적용한다.
- Camera 고정 Single/Spread guide를 AI live boundary 아래에 복원하고 Camera DEBUG 버튼은 제거한다.
- Quick Corner 이미지를 불변 contain rect로 고정하고 모든 pan/zoom gesture를 제거해 corner-only 보정 UX로 마감한다.
- Curved confidence의 coverage/evidence/consistency와 구체 rejection reason을 DEBUG/session metadata에 남기되 전체 threshold 0.68은 낮추지 않는다.
- 자동 correction pipeline을 Capture와 Quick Corner, Spread Left/Right에 공통 적용한다. 곡률 크기와 evidence 품질을 분리해 FLAT/MILD/STRONG/UNRELIABLE로 분류하고 mild는 55% strength, strong은 full strength로 처리한다.
- Curved 출력은 geometry/deformation/straightness 개선 검증 후에만 채택한다. 거부 또는 불확실 상태는 Perspective+Enhancement 정상 결과로 완료하고 기술 오류를 사용자에게 노출하지 않는다.
- Curved Dewarp Final Pass는 AI refinement의 기존 owned paper contour를 top/bottom/spine evidence로 재사용하고 text/staff evidence와 방향별로 fusion한다. Geometry 두 신호 또는 geometry+internal 동방향 조합은 MILD 후보가 될 수 있지만 충돌 신호는 UNRELIABLE로 격리한다.
- V1 acceptance는 최근 얇은 책에서 일부 MILD가 실제 적용되어 page geometry 또는 baseline이 개선되고, 평면 A4는 FLAT을 유지하며, DEBUG curvature report가 모든 미적용 원인을 구체적으로 설명하는 것이다. Strength 55%, STRONG 0.68, M8.1 0.17/0.20/0.07 값은 유지한다.
- Quick Corner 확대경을 제거하고 Gallery 액션을 thumbnail 아래 반응형 compact row로 분리한다.
- corrected/enhanced 중간 결과를 full-resolution PNG로 전환해 누적 JPEG 재압축을 제거하고 기존 JPEG session 호환을 유지한다.
- Foreground-first source 72%/3×3·9×9 detail/black-hat 실험은 종이 질감과 비침을 증폭한 회귀로 철회한다. Scan Color는 M8.1의 paper-aware normalization, soft whitening, 보수적 5×5 text mask를 유지하며 최종 가독성 값은 edge-local sharpening 17%, foreground darkening 20%, source blend 7%로 동결 후보화한다.
- `debug_quality` 단계 artifact와 전체/foreground sharpness, background variance/dark speckle ratio, format/bytes/PDF source report로 같은 글자의 RAW→Perspective→Enhanced 손실 및 speckle 증가를 실기기에서 비교한다.
- Viewer와 PDF는 동일 full-resolution `displayImagePath`를 사용하며 thumbnail 또는 PDF pre-resize를 허용하지 않는다.
- 동일 책 페이지에서 자연스러운 stroke, 낮은 halo/눈 피로, 안정된 배경을 승인하면 이미지 품질 튜닝을 종료하고 V1 UI Cleanup으로 전환한다. 다음 범위는 DEBUG/AI 비교 메뉴, 개발용 버튼, 중복 편집 진입점, Page Editor와 Camera·Gallery·PDF Review의 사용자 명칭·아이콘·간격 정리다.

## M7 — PDF Export & Scan Document Workflow

corrected 우선 반응형 선택 Gallery와 별도 PDF Page Review, Long Press Drag 최종 순서, 오프라인 PDF 생성, rotation 적용, 파일명 확인, Android SAF 저장 위치 선택·최근 위치 기억, 진행 상태와 성공 후 Session 정리를 구현한다.

## M8 — Scan Image Enhancement & Recovery UX

Recovery의 기본 진입점을 PDF Selection Gallery로 변경하고, OpenCV 기반 Scan Color·Original Color·Grayscale·Black & White 화질 보정, raw/corrected/enhanced 단계별 영속화, Gallery/Viewer/PDF 결과 일치와 실패 fallback을 구현한다.

## M8.1 — Paper-aware Scan Color

종이 background 추정, 저주파 조명·그림자 normalization, soft whitening과 bleed-through 억제, foreground/text 대비 및 edge 제한 sharpening, 컬러 콘텐츠 보호를 적용해 일반 사진 보정이 아닌 문서 스캔 특성으로 개선한다.

### Phase 5 고급 기능 (예정)

- 문서 중심 Auto Capture
- 자동 연속 스캔
- Camera Preview 실시간 문서 검출

## M9 — OCR Auto Title & PDF Completion UX

bundled Korean on-device OCR의 첫/두 번째 PDF 페이지 제목 제안, Session 재사용, 날짜 fallback, PDF 저장 결과 보존, Review 내부 완료 UX와 Android PDF Viewer 열기를 구현한다.

Camera 역할 기반 방향 정책을 추가해 Single은 Portrait, Spread는 Landscape를 사용하고 Gallery·Viewer·Editor·PDF flow는 Portrait으로 고정한다.

## Q1 — Book/Page Boundary Detection Quality Improvement

악보·표·내부 frame의 강한 선을 page boundary로 오인하는 문제를 개선한다. 페이지 점유율, ROI 외곽 접근성, 경계 안/밖 대비, 종이 내부 특성, 외곽 연속성을 우선하고 내부선과 좁은 crop을 감점한다. Spread ROI 비율은 유지하며 outer/top/bottom evidence가 충분할 때 약한 spine-side edge를 보완한다.

구현 후 synthetic 회귀 테스트와 APK 빌드를 통과하더라도 실제 책·악보를 Single/Spread로 다시 촬영해 최종 품질을 판단한다.

## 향후 OCR

Searchable PDF text layer, 전체 페이지 OCR, OCR 검색은 M9 범위에서 제외한다.
