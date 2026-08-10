# 라이선스 기록

## 현재 의존성

| 구성요소 | 용도 | 라이선스 |
| --- | --- | --- |
| Flutter SDK | 앱 프레임워크 | BSD 3-Clause |
| Dart SDK | 언어 및 런타임 | BSD 3-Clause |
| flutter_test | 테스트 | BSD 3-Clause |
| flutter_lints | 정적 분석 | BSD 3-Clause |
| camera 0.11.3+1 | Android 카메라 프리뷰·촬영 | BSD 3-Clause |
| path 1.9.1 | 플랫폼 독립 경로 조합 | BSD 3-Clause |
| path_provider 2.1.6 | 앱 전용 저장 디렉터리 조회 | BSD 3-Clause |
| uuid 4.6.0 | ScanSession ID 생성 | MIT |
| OpenCV Android AAR 4.13.0 (`org.opencv:opencv`) | 오프라인 문서 영역 검출 | Apache License 2.0 |

## 도입 규칙

새 라이브러리는 무료 오픈소스 라이선스, 오프라인 동작 가능 여부, 배포 시 고지 의무를 확인한 뒤에만 도입한다. 도입한 항목은 버전, 용도, 라이선스, 고지 요구사항을 이 문서에 추가한다.

OpenCV 4.13.0은 OpenCV Team이 Maven Central에 배포하는 공식 Android AAR을 사용한다. OpenCV 4.5.0 이상은 Apache License 2.0이며, 배포 시 라이선스와 저작권·NOTICE 고지 의무를 보존한다.

- 공식 라이선스: https://opencv.org/license/
- 공식 Android Maven 사용 안내: https://docs.opencv.org/4.13.0/d5/df8/tutorial_dev_with_OCV_on_Android.html
- Maven Central artifact: https://central.sonatype.com/artifact/org.opencv/opencv/4.13.0

OCR 및 PDF 라이브러리는 아직 추가하지 않았다.
