# 로드맵

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

## 향후 OCR

Searchable PDF text layer, 전체 페이지 OCR, OCR 검색은 M9 범위에서 제외한다.
