# Changelog

## 1.2.0+2 - 2026-10-19

### Added

- Android 파일 선택기로 기존 PDF를 불러오는 독립 PDF 편집 흐름
- 페이지 썸네일, 길게 눌러 순서 변경, 삭제 및 저장 전 복원
- qpdf 12.4.2 기반 무재렌더링 페이지 선택·재배열과 수정본 별도 저장
- `armeabi-v7a`, `arm64-v8a`, `x86_64` 네이티브 패키징

### Preserved

- 기존 ML Kit 스캔, ScanSession, OCR 제목 제안과 스캔 PDF 생성·저장 흐름
- 원본 PDF 불변 및 PDF 편집 작업과 ScanSession의 분리

### Verified

- Galaxy Tab S7+에서 기존 PDF 불러오기, 페이지 편집과 새 PDF 저장 흐름 확인
