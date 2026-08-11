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

### Phase 5 고급 기능 (예정)

- 문서 중심 Auto Capture
- 자동 연속 스캔
- Camera Preview 실시간 문서 검출

## Phase 7 — 화질 보정과 OCR

문서 화질 보정과 OCR 제목 추천을 구현한다.
