# Scana

Scana는 Android 전용 모바일 문서 스캐너다. ML Kit 기반 촬영, 문서 보정, 페이지 관리, OCR 제목 제안과 PDF 저장을 제공하며 사용자의 문서 이미지를 외부 서버로 전송하지 않는다.

## V1.2 주요 기능

- 1페이지 문서와 펼친 책 2페이지 촬영
- 자동 문서 영역 검출, 원근·곡면 보정과 문서 화질 보정
- 스캔 페이지 순서 변경, 삭제, 회전, 재촬영 및 세션 복구
- 기기 내 OCR 제목 제안과 Android SAF 기반 새 PDF 저장
- 기존 PDF 불러오기, 페이지 순서 변경, 삭제·복원, 수정본 별도 저장

기존 PDF 편집은 qpdf 12.4.2로 페이지 객체를 직접 선택·재배열한다. 페이지를 이미지로 다시 렌더링하거나 재압축하지 않으며 원본 PDF는 읽기 전용으로 유지한다. PDF 편집 임시 작업은 스캔 세션과 분리된다.

## 플랫폼과 배포

- applicationId: `com.myphotw.scana`
- 지원 ABI: `armeabi-v7a`, `arm64-v8a`, `x86_64`
- qpdf 12.4.2 / libjpeg-turbo 3.2.0 버전과 SHA-256은 `android/third_party/qpdf/VERSIONS.md`에 고정
- ML Kit Document Scanner는 Google Play services가 최초 실행 시 구성요소를 내려받을 수 있음

요구사항, 구조, 개발 상태와 라이선스 고지는 [`docs`](docs)에서 확인할 수 있다.
