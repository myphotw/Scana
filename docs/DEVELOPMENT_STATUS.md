# 개발 상태

최종 갱신: 2026-08-11

| 항목 | 상태 | 비고 |
| --- | --- | --- |
| Android 전용 Flutter 기본 프로젝트 | 완료 | applicationId: com.myphotw.scana |
| 앱 진입 구조 및 모듈 폴더 | 완료 | 기능별 책임 분리 |
| 요구사항·설계·로드맵·라이선스 문서 | 완료 | 지속 갱신 |
| 카메라 | 완료 | 전체 화면 프리뷰, 수동 촬영, 가이드 Overlay |
| ScanSession | 완료 | 앱 전용 영속 저장, Recovery, session.json 메타데이터 |
| 페이지 편집 기반 | 완료 | 선택, 삭제, Drag & Drop 순서 변경, 회전 메타데이터 |
| 문서 검출 기반 | 완료 | OpenCV 촬영 후 검출, Overlay, 수동 Corner 조정 |
| OpenCV | 사용 중 | 공식 Android AAR 4.13.0, 오프라인 처리 |
| 원근 보정 | 완료 | 원본 모서리 기반 출력 크기 계산, warpPerspective, corrected 파일 저장 |
| 곡면 평탄화 | 완료 | 경계 우선/inset fallback, robust 다중 곡률, 안전 검증, strip remap |
| Continuous Scan UX | 완료 | Camera 유지 연속 촬영, 처리 대기열 표시, 촬영 완료 후 문서 목록 |
| Scan Result UX | 완료 | corrected 우선 Viewer, Swipe, 재촬영·편집·삭제, 선택 가능한 페이지 관리 |
| 보정 UI·영속화 | 완료 | 상세 편집의 Corner SafeArea 툴바, 원본/보정본 비교, 실패 시 Perspective 보호 |
| 화질 보정 | 미착수 | 향후 단계 |
| OCR·PDF | 미착수 | 향후 단계 |
| 외부 라이브러리 | 사용 중 | camera, path, path_provider, uuid, OpenCV |

## Known Issues

- 1페이지 문서 검출이 실기기 조건에 따라 일부 영역을 잘못 crop하는 경우가 있음
- 2페이지 모드는 좌/우 ROI 분리는 동작하지만 각 페이지 자동 영역 검출 정확도가 부족함
- 곡면 문서 보정은 아직 품질이 충분하지 않아 추후 개선 예정
- 2페이지 가로 촬영 UI 및 촬영 버튼 위치는 정상 동작 확인
