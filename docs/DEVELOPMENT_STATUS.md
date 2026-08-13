# 개발 상태

최종 갱신: 2026-08-13

| Scana V1 AI Primary Crop | 구현 | AI Final/Hybrid/Raw → OpenCV → Guide production priority, 실기기 검증 필요 |
| Visibility-Safe Boundary | 구현 | 변별 visibility, bottom-beyond 검사, conservative hybrid polygon |
| Quick Corner Edit 정식 UX | 구현 | 고정 BoxFit.contain 이미지, gesture transform 제거, 44px hit target·선택점 강조, manual 전체 자동 보정 pipeline 재생성 |

| UX-Q1 Camera boundary / PDF reorder / Android Navigation | 구현 | 실기기 위치·애니메이션·Navigation 접근성 확인 필요 |
| Q1.1 Live overlay / Live reorder / 실제 책 crop 재튜닝 | 구현 | 동일 악보 Single/Spread 재촬영 검증 필요 |
| Q1.2 Multi-stage Page Crop Strategy | 구현 | High-res Paper → Content Safe → Guide fallback, 실기기 최종 검증 필요 |
| Q1.3 WYSIWYG Capture Boundary | 구현 | 셔터 시점 Overlay snapshot → 제한적 high-res refine → Perspective, 동일 책 실기기 검증 필요 |
| AI-PoC 1 FairScan Segmentation 비교 | 구현 | v1.2.0 TFLite 병렬 진단, 기존 crop 미변경, 실제 책 품질·속도 비교 필요 |
| AI-PoC 2 AI Segmentation + Paper Edge Refinement | 구현 | AI search prior + LAB paper/edge refinement DEBUG 비교, primary 전환 전 실기기 검증 필요 |
| AI-PoC 3 AI Refined Boundary Stabilization | 구현 | ownership prior, adjacent penalty, robust outer envelope/occlusion recovery, primary 미전환 |
| AI-PoC 4 Conservative Refinement | 완료/제품 반영 | partial raw hard reject, edge별 evidence cap, second paper suppression |
| Quick Corner Edit fallback | 구현 | Gallery/Viewer/PDF Review 직접 진입, fixed-image corner-only drag, manual persistence·Perspective/Enhancement 재생성 |

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
| 자동 곡면 평탄화 | 구현/실기기 승인 대기 | FLAT/MILD/STRONG/UNRELIABLE, mild 55% strength, straightness·geometry 검증, 실패 시 Perspective+Enhancement 보호 |
| 자동 Production Correction | 구현 | Capture/Quick Corner/Spread 공통 Perspective → curvature analysis → optional Dewarp → Enhancement |
| Page contour curvature evidence | 구현/실기기 승인 대기 | 기존 AI owned paper contour의 top/bottom/spine 정규화 곡률과 text/staff 방향 fusion, AI crop scoring 미변경 |
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
| V1 Final Quality Regression Fix | 구현 완료, 실기기 재검증 필요 | M8.1 Scan Color 복원, foreground-first 72%/black-hat 제거, PNG·full-resolution·quality artifact 유지 |
| V1 Scan Readability Final Tuning | 구현 완료, 실기기 승인 대기 | edge-limited sharpening 17%, foreground darkening 20%, source blend 7%; 품질 동결 후보 |
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
| Quick Corner Edit | 구현 완료, 실기기 평가 필요 | 현재 final crop 초기값, 고정 이미지 위 corner-only drag, 적용 후 전체 자동 correction pipeline 재실행 |
| V1 AI Primary Crop | 구현 완료, 실기기 평가 필요 | AI Refined/Hybrid/Raw fallback 우선, OpenCV·Guide 안전 fallback 유지 |
| V1 Edge Visibility | 구현 완료, 실기기 평가 필요 | confirmed/weak/occluded/out-of-frame/unknown 및 하단 전경·종이 연속성 검사 |
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
- Quick Corner Edit의 고정 contain rect, 네 모서리 끝점 clamp, 선택점 강조와 적용 후 Perspective→곡률 분석→조건부 Dewarp→Scan Color 처리 시간은 다양한 화면 비율의 실기기에서 최종 확인 필요
- AI Primary의 `AI Final`이 실제 책 하단 여백·페이지 번호를 보존하는지, 손가락/그림자/화면 밖 외곽에서 hybrid 안전 여백이 과도하지 않은지 실기기 확인 필요
- Spread left/right는 독립 AI Final을 사용하므로 제본부·반대 페이지가 overlap에 포함된 실제 촬영에서 adjacent 억제와 좌우 순서를 재검증해야 함
- 자동 곡면보정은 `flat/mildCurve/strongCurve/unreliable`로 분류하고 mild에는 55% 보수적 변형만 적용한다. 실제 책·악보의 비대칭 곡률에서 MILD 적용률, straightness 개선과 과도한 변형 부재를 실기기로 승인해야 함
- 자동 곡률 분석 또는 Dewarp가 거부되면 기술 오류를 노출하지 않고 Perspective+Enhancement로 정상 완료한다. DEBUG `[CURVED_AUTO]`의 상태·시간·evidence·straightness 지표는 진단용이며 실기기 품질 승인값은 아님
- 최근 얇은 책 3장이 모두 미적용된 가장 유력한 원인은 AI refinement의 실제 paper contour가 Curved 단계로 전달되지 않아 text/staff evidence만으로 evidence count·coverage·consistency를 동시에 만족하지 못한 것이다. 이제 contour 전달과 geometry-MILD 경로를 추가했으며 같은 샘플에서 일부 MILD 적용, 평면 A4의 FLAT 유지, 과변형 부재를 실기기로 승인해야 함
- `debug_curvature/<raw-stem>/curvature_report.json`과 overlay를 통해 재차 미적용되더라도 contour 부재, 낮은 magnitude, 방향 충돌, coverage 부족, straightness/geometry 미개선 중 구체 원인을 구분할 수 있음
- 새 촬영은 corrected/enhanced full-resolution PNG로 중간 JPEG 누적 압축을 제거했다. 기존 JPEG session은 하위 호환되며 PNG 파일 크기와 페이지당 처리시간은 실기기에서 측정 필요
- Foreground-first 실험의 source luminance 72%, 3×3/9×9 source detail, horizontal black-hat은 종이 speckle/비침 증폭 회귀로 제거했다. 최종 가독성 튜닝은 M8.1 구조와 source 7%를 고정하고 edge-limited sharpening 17%, foreground darkening 20%만 적용한다. 동일 문제 책 페이지에서 자연스러운 획과 눈의 피로를 실기기 재검증해야 함
- DEBUG `[SCAN_QUALITY]`의 sharpness/background variance/dark speckle ratio는 진단 지표이며 품질 자동 판정값이 아니다. Enhanced speckle이 Perspective 대비 1.75배 및 1%p 넘게 증가하면 `background_speckle_amplified` 경고를 기록한다
- Camera 고정 guide 대비선과 PDF Gallery compact action row는 widget 회귀를 통과했으며 밝은/어두운 실기기 배경과 최소 폭 기기에서 최종 육안 확인 필요
- 2페이지 가로 촬영 UI 및 촬영 버튼 위치는 정상 동작 확인

## 다음 단계

동일 평면 문서·최근 얇은 책 3장·강한 곡률 책·가림/그림자 불확실 샘플에서 contour/internal fusion 상태 분류와 Perspective fallback을 승인하면 Curved Dewarp V1을 동결하고 UI Cleanup으로 전환한다. 얇은 책은 일부 MILD 적용과 육안 geometry/text 개선, 평면 문서는 FLAT, 충돌 샘플은 UNRELIABLE이어야 한다.
