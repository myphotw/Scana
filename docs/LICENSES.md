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
| pdf 3.13.0 | 기기 내부 PDF 문서·이미지 페이지 생성 | Apache License 2.0 |
| uuid 4.6.0 | ScanSession ID 생성 | MIT |
| OpenCV Android AAR 4.13.0 (`org.opencv:opencv`) | 오프라인 문서 검출, 원근 변환, 곡면 remap, Scan Color·Grayscale·Black & White 화질 보정 | Apache License 2.0 |
| LiteRT 1.4.1 (`com.google.ai.edge.litert:litert`) | FairScan segmentation TFLite CPU/XNNPACK 오프라인 추론 | Apache License 2.0 |
| FairScan Document Segmentation Model v1.2.0 | AI-PoC 문서 probability mask 생성, DeepLabV3Plus + MobileNetV2, dynamic-range quantized TFLite | GNU GPL v3 |
| Google ML Kit Text Recognition Korean 16.0.1 (`com.google.mlkit:text-recognition-korean`) | bundled 기기 내 한국어 OCR·PDF 제목 제안 | Google ML Kit Terms / Google APIs Terms (비 오픈소스 SDK) |

## 도입 규칙

새 라이브러리는 무료 오픈소스 라이선스, 오프라인 동작 가능 여부, 배포 시 고지 의무를 확인한 뒤에만 도입한다. 도입한 항목은 버전, 용도, 라이선스, 고지 요구사항을 이 문서에 추가한다.

OpenCV 4.13.0은 OpenCV Team이 Maven Central에 배포하는 공식 Android AAR을 사용한다. OpenCV 4.5.0 이상은 Apache License 2.0이며, 배포 시 라이선스와 저작권·NOTICE 고지 의무를 보존한다.

- 공식 라이선스: https://opencv.org/license/
- 공식 Android Maven 사용 안내: https://docs.opencv.org/4.13.0/d5/df8/tutorial_dev_with_OCV_on_Android.html
- Maven Central artifact: https://central.sonatype.com/artifact/org.opencv/opencv/4.13.0

`pdf` 3.13.0은 순수 Dart 기반 PDF 생성 라이브러리로 Android에서 네트워크 없이 동작한다. Apache License 2.0에 따라 라이선스와 저작권·NOTICE 고지 의무를 보존한다. 인쇄·공유용 `printing` 패키지는 추가하지 않았다.

- 공식 패키지: https://pub.dev/packages/pdf
- 공식 라이선스: https://pub.dev/packages/pdf/license
- 공식 저장소: https://github.com/DavBfr/dart_pdf

Google ML Kit Text Recognition v2 Korean 16.0.1은 Android 앱에 모델을 정적으로 포함하는 bundled artifact를 사용한다. 공식 문서의 bundled/unbundled 분류에 따라 앱 실행 중 모델 다운로드가 필요 없고 즉시 사용 가능하며, 한국어 script를 지원한다. 모델/인식은 기기 내에서 실행하고 Scana는 인식 이미지나 텍스트를 외부 API로 전송하지 않는다.

이 artifact는 Apache/MIT 오픈소스가 아니며 Google ML Kit Terms와 Google APIs Terms의 적용을 받는 proprietary SDK이다. 유료 클라우드 OCR API는 사용하지 않는다. 배포 전에는 해당 약관과 Google Play/Data Safety 고지 요구를 재확인한다. 공식 Android 가이드의 용량 안내는 bundled script당 architecture별 약 4MB 증가이며, 실제 APK 크기는 빌드 결과로 별도 검증한다.

- 공식 Android Text Recognition v2: https://developers.google.com/ml-kit/vision/text-recognition/v2/android
- 공식 언어 지원: https://developers.google.com/ml-kit/vision/text-recognition/v2/languages
- Google ML Kit Terms: https://developers.google.com/ml-kit/terms
- Google APIs Terms: https://developers.google.com/terms

M6에서는 새 외부 라이브러리를 추가하지 않고 M5에서 도입한 OpenCV 4.13.0을 재사용한다.

M8 화질 보정도 새 외부 라이브러리를 추가하지 않고 기존 OpenCV 4.13.0과 Flutter/Dart 표준 기능만 재사용한다. 따라서 추가 라이선스 고지 대상은 없다.

## AI-PoC 1 FairScan Segmentation

PoC는 `pynicolas/fairscan-segmentation-model`의 공식 v1.2.0 release asset을 저장소에 명시적으로 포함한다. 빌드 또는 런타임 자동 다운로드를 사용하지 않으며 Android `INTERNET` permission을 추가하지 않는다.

- 모델 파일: `android/app/src/main/assets/models/fairscan_document_segmentation.tflite`
- 버전/tag: `v1.2.0` (`78cde68`, dataset v2.1 release)
- 파일 크기: 4,921,040 bytes
- SHA-256: `96E14D7E610DD0C27B768B228FBC553B4EC119EBE68F3A3594029A25400691D2`
- 구조: DeepLabV3Plus, MobileNetV2 encoder, 256×256 RGB binary document segmentation
- 형식: dynamic-range quantized TFLite, FLOAT32 input/output interface
- 라이선스: GNU General Public License v3
- 모델 저장소: https://github.com/pynicolas/fairscan-segmentation-model
- 공식 release: https://github.com/pynicolas/fairscan-segmentation-model/releases/tag/v1.2.0
- FairScan 참고 구현: https://github.com/pynicolas/FairScan

FairScan 앱의 LiteRT 사용 방식과 preprocessing/mask decoding만 검토했으며 앱 전체 소스는 복사하지 않았다. Scana의 segmenter와 post-processing은 기존 OpenCV 계층에 맞게 별도로 작성했다. FairScan 모델이 GPL-3.0이므로 이 모델을 포함한 APK를 외부 배포할 때는 앱 전체의 GPL 호환성과 해당 소스 제공 의무를 제품 배포 전에 반드시 법률·라이선스 관점에서 확인해야 한다.

LiteRT 1.4.1은 Google AI Edge의 Android runtime artifact를 사용한다. 모델과 runtime이 APK에 포함되어 기기 내 CPU/XNNPACK으로 실행되며 API key, cloud service, runtime model download가 없다.

- LiteRT 공식 저장소: https://github.com/google-ai-edge/LiteRT
- Maven artifact: https://central.sonatype.com/artifact/com.google.ai.edge.litert/litert/1.4.1
