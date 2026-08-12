# 개발 상태

최종 갱신: 2026-08-12

| UX-Q1 Camera boundary / PDF reorder / Android Navigation | 구현 | 실기기 위치·애니메이션·Navigation 접근성 확인 필요 |
| Q1.1 Live overlay / Live reorder / 실제 책 crop 재튜닝 | 구현 | 동일 악보 Single/Spread 재촬영 검증 필요 |
| Q1.2 Multi-stage Page Crop Strategy | 구현 | High-res Paper → Content Safe → Guide fallback, 실기기 최종 검증 필요 |
| Q1.3 WYSIWYG Capture Boundary | 구현 | 셔터 시점 Overlay snapshot → 제한적 high-res refine → Perspective, 동일 책 실기기 검증 필요 |
| AI-PoC 1 FairScan Segmentation 비교 | 구현 | v1.2.0 TFLite 병렬 진단, 기존 crop 미변경, 실제 책 품질·속도 비교 필요 |
| AI-PoC 2 AI Segmentation + Paper Edge Refinement | 구현 | AI search prior + LAB paper/edge refinement DEBUG 비교, primary 전환 전 실기기 검증 필요 |
| AI-PoC 3 AI Refined Boundary Stabilization | 구현 | ownership prior, adjacent penalty, robust outer envelope/occlusion recovery, primary 미전환 |
| AI-PoC 4 Conservative Refinement | 구현 | partial raw hard reject, edge별 evidence cap, second paper suppression, primary 미전환 |
| Quick Corner Edit fallback | 구현 | Gallery/Viewer/PDF Review 직접 진입, magnifier·zoom/pan, manual persistence·Perspective/Enhancement 재생성 |

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
| Continuous Scan UX | 완료 | Camera 유지 수동 연속 촬영, 처리 대기열 표시, 최근 썸네일 Gallery 진입 |
| Scan Result UX | 완료 | Gallery 선택 → Review 확인·Long Press 정렬 → PDF 단방향 흐름 |
| 보정 UI·영속화 | 완료 | 상세 편집의 Corner SafeArea 툴바, 원본/보정본 비교, 실패 시 Perspective 보호 |
| PDF Export | 완료 | Review 최종 순서, rotation, fitImage 페이지, 파일명 확인, SAF 저장·최근 위치, 성공 후 Session 정리 |
| Navigation lifecycle | 수정 완료 | 파일명 Dialog State가 TextEditingController lifecycle을 직접 소유하도록 변경 |
| M7.2.2 DEBUG 진단 | 구현 완료 | 영속 오류/stack·lifecycle·Navigator·SAF request/result 로그와 재시작 후 TXT 내보내기 |
| M7.2.3 filename Dialog | 구현 완료 | premature controller dispose 제거, SAF 구조 유지, 반복 Dialog 회귀 테스트 추가 |
| M8 Session Recovery UX | 완료 | 이어하기 → PDF Selection Gallery, Back → 동일 Session Camera |
| M8 화질 보정 | 완료 | Scan Color 기본 자동 처리, 원본·그레이·흑백 수동 전환, enhanced 영속화·fallback |
| M8 처리 안정성 | 완료 | 단일 background executor, full-resolution 출력, 1200px 분석 map, 명시적 Mat release |
| M8.1 Paper-aware Scan Color | 완료 | 종이 mask 기반 whitening·비침 억제, text-aware 대비, edge 제한 sharpening, 컬러 보호 |
| M9 로컬 OCR | 완료 | bundled ML Kit Korean 16.0.1, Review background 제목 제안, 2페이지 fallback |
| M9 PDF 완료 UX | 완료 | 결과 URI/파일명/크기/페이지 수 보존, 새 스캔·ACTION_VIEW 파일 열기 |
| 화면 방향 UX | 완료 | Single Camera Portrait, Spread Camera Landscape, Camera 외 작업 화면 Portrait, 외부 Viewer 복귀 재적용 |
| Q1 Book/Page Boundary Detection Quality Improvement | 구현 완료, 실기기 검증 필요 | 악보 내부선 감점, page occupancy·border·contrast·paper score 강화, Spread spine-side fallback |
| Q1.2 Page Detection / Crop 안정화 | 구현 완료, 실기기 검증 필요 | LAB paper region, content-safe margin, CropSource 영속화, 느슨한 Live Guide |
| Q1.3 WYSIWYG Capture Boundary | 구현 완료, 실기기 검증 필요 | Single/Spread snapshot, analysis→JPEG 직접 변환, shrink 방지 refine, capture evidence 영속화 |
| AI-PoC 1 FairScan Segmentation | 구현 완료, 비교 평가 필요 | LiteRT CPU 추론, Single/Spread 독립 mask, DEBUG overlay·timing, OpenCV primary 유지 |
| AI-PoC 2 AI Paper Edge Refinement | 구현 완료, 비교 평가 필요 | 비율 search ROI, LAB candidate, outward edge search, containment/expansion sanity, OpenCV primary 유지 |
| AI-PoC 3 Refined Boundary 안정화 | 구현 완료, 실기기 평가 필요 | curved envelope, MAD/trim fitting, bottom occlusion 복구, explicit refine status/confidence |
| AI-PoC 4 Refined 마지막 튜닝 | 구현 완료, 실기기 평가 필요 | edge별 확장 제한, partial/adjacent/foreground hard reject, accepted conservative 상태 |
| Quick Corner Edit | 구현 완료, 실기기 평가 필요 | AI/OpenCV 초기값, 확대경, pinch zoom/pan, 적용 후 scan result 즉시 갱신 |
| 외부 라이브러리 | 사용 중 | camera, path, path_provider, pdf, uuid, OpenCV, ML Kit Text Recognition Korean |

## Known Issues

- 파일명 Dialog controller premature dispose가 `_dependents.isEmpty`와 Duplicate GlobalKeys의 최초 원인으로 확인되어 M7.2.3에서 수정함. 실기기 재검증 필요
- Q1 detector scoring 개선은 synthetic test와 Android build를 통과했으나 실제 책·악보 재촬영으로 최종 판정해야 함
- Q1.2는 잘못된 좁은 crop보다 넓은 fallback을 우선한다. 실제 악보·누런 종이·그림자·Spread 좌우 혼합 source는 실기기에서 최종 판정해야 함
- Q1.3의 Overlay/최종 crop 일치도는 동일 책을 Camera → 촬영 → Gallery 순서로 비교하는 실기기 검증이 필요함
- AI-PoC 1은 실제 입문책의 전체 페이지 포함, 주변 책상 배제, 내부선 오인 방지, Spread 좌우 및 1초 내외 처리시간을 실기기에서 OpenCV와 비교해야 함
- AI-PoC 2 refined boundary는 같은 책에서 AI Raw보다 상·하·좌우 종이 여백을 보존하면서 인접 페이지를 배제하는지, 추가 처리시간이 목표 수백 ms 범위인지 실기기 검증해야 함
- AI-PoC 3는 손가락 하단 가림·겹친 흰 종이·반대 페이지가 있는 동일 Single/Spread 샘플에서 envelope margin과 adjacent/occlusion status를 실기기 재검증해야 함
- AI-PoC 4는 동일 샘플에서 상단/측면 과확장과 partial raw reject가 개선됐는지 최종 비교해야 하며, 불안정하면 추가 자동 튜닝 대신 Quick Corner Edit를 공식 fallback으로 사용함
- Quick Corner Edit 확대경 위치, 고배율 corner drag, 적용 후 Perspective+Scan Color 처리 시간은 다양한 화면 비율의 실기기에서 최종 확인 필요
- 곡면 문서 보정은 아직 품질이 충분하지 않아 추후 개선 예정
- 2페이지 가로 촬영 UI 및 촬영 버튼 위치는 정상 동작 확인
