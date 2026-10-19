# Scana V1.2 PDF Editor 작업 인수인계

최종 갱신: 2026-10-19 (KST)

이 문서는 qpdf 기반 기존 PDF 편집 기능의 구현, 호스트 검증과 V1.2 릴리스 정리 상태를 기록한 인수인계 문서다. Galaxy Tab S7+에서 주요 PDF 편집 흐름을 확인했으며 제품 엔진은 qpdf 12.4.2로 확정했다.

## 1. 현재 Git 기준

- 브랜치: `main`
- HEAD: `5b6e5351709272586596a0dc5c453d68e1765880`
- HEAD 태그: `v1.1.0`
- 릴리스 준비 버전: `1.2.0+2`
- 커밋/푸시: 수행하지 않음
- working tree: 변경 사항 있음
- 2026-10-16에 중단된 테스트와 Gradle 프로세스는 정상 종료했음
- 2026-10-19에 전체 검증을 재개했으며 commit/push 없이 working tree 변경을 그대로 유지함

qpdf 실기기 검증이 완료되어 V1.2 릴리스 정리에서 사용하지 않는 비교 PoC 코드·테스트·의존성은 제거했다. qpdf 제품 코드, 세 ABI 라이브러리와 체크섬 잠금은 유지한다.

## 2. 완료된 구현

### qpdf 네이티브 기반

- qpdf `12.4.2`와 libjpeg-turbo `3.2.0` 소스 아카이브 및 SHA-256 잠금 추가
- Android NDK/CMake 재현 빌드 스크립트 추가
- `armeabi-v7a`, `arm64-v8a`, `x86_64`용 `libqpdf.so` 생성 완료
- `c++_shared`, Android API 24, C++20, C++ 예외/RTTI 구성
- JNI bridge에서 qpdf page-selection 문법을 사용해 페이지 재배열/삭제본 생성
- C++ 예외가 JNI 경계를 넘지 않도록 catch 처리
- 원본과 출력 PDF를 qpdf로 검증하는 native API 추가

### Android/Kotlin

- 기존 PDF 선택: Android `ACTION_OPEN_DOCUMENT`
- 선택한 PDF를 앱 캐시의 독립 PDF 편집 작업 폴더로 복사
- Android `PdfRenderer` 기반 페이지 수 확인 및 지연 썸네일 생성
- 페이지 순서 입력값의 비어 있음, 중복, 범위 오류 방지
- qpdf 출력 생성 후 유효성 및 페이지 수 확인
- 단일 worker executor에서 파일/네이티브 처리를 실행
- PDF 편집 임시 출력 및 작업 폴더 정리 API 추가
- 기존 SAF 저장 채널을 재사용하고 동일 파일명이 있으면 `(n)` 접미사를 붙여 덮어쓰기를 방지
- PDF 편집 흐름은 `ScanSessionManager`와 분리했으며 `deleteAfterSuccessfulExport()`를 호출하지 않음

### Flutter UI

- 홈 화면에 `PDF 편집` 진입 버튼 추가
- 기존 PDF 선택 취소 시 홈 화면 유지
- 기존 PDF용 편집 화면 추가
- 페이지 썸네일 grid, long-press drag 순서 변경, 페이지 삭제/복원
- 모든 페이지 삭제 방지
- 파일명 입력, 최근 저장 위치 또는 새 저장 위치 선택, SAF 저장, 완료 화면 연결
- 원본 PDF는 읽기 전용으로 유지하고 수정본만 별도 저장

### 테스트 코드

- Dart domain/channel 계약 테스트
- PDF 편집 화면 widget 테스트
- JNI/CMake/ABI 파일 계약 테스트
- Kotlin 페이지 순서 정책 unit test
- Android instrumentation용 qpdf 5페이지 재배열/원본 불변 테스트

## 3. 네이티브 소스와 세 ABI 산출물

아래 파일은 모두 현재 파일 시스템에 존재한다. Git ignore 대상은 아니지만 아직 커밋되지 않았으므로 현재는 `untracked` 상태다. 즉 다음 커밋에 정상적으로 포함할 수 있으나, 지금 시점에는 Git이 보존하는 tracked 파일은 아니다.

### 고정 소스 아카이브

| 파일 | 크기(byte) | SHA-256 |
| --- | ---: | --- |
| `android/third_party/qpdf/sources/qpdf-12.4.2.tar.gz` | 19,402,426 | `FB92435766B8EE31F7BF7123BEC1FC2AF83599ED8B1FEF7F3DAFEF4024A983B5` |
| `android/third_party/qpdf/sources/libjpeg-turbo-3.2.0.tar.gz` | 2,545,285 | `E880CAAB26D598BFF3055CD05B942262BAAEA09BD6E3D3362D6FBC92FAA9F744` |

### prebuilt qpdf 라이브러리

| ABI | 파일 | 크기(byte) | SHA-256 |
| --- | --- | ---: | --- |
| armeabi-v7a | `android/third_party/qpdf/prebuilt/armeabi-v7a/libqpdf.so` | 2,032,128 | `C7B904F1BC0C3205E900DFD8FD7AA21EDD5BC0FAD1719FC856A88629E47BC941` |
| arm64-v8a | `android/third_party/qpdf/prebuilt/arm64-v8a/libqpdf.so` | 3,111,368 | `F5C8BCF271FC79211D4983A0DA63B63E153B88F19727142891D5FDE7B5518E48` |
| x86_64 | `android/third_party/qpdf/prebuilt/x86_64/libqpdf.so` | 3,139,768 | `1D35741AB5B66BFD3D58AA32B9A47AA9004D697DC54A77A538543AC55C829DD6` |

버전과 체크섬 설명은 `android/third_party/qpdf/VERSIONS.md`에 있다.

### 산출물 재생성

세 ABI 파일이 없어졌거나 체크섬이 다르면 저장소 루트에서 다음 명령으로 재생성한다.

```powershell
powershell -ExecutionPolicy Bypass -File android/third_party/qpdf/build_android.ps1
```

스크립트는 `android/local.properties` 또는 Android SDK 환경 변수를 이용하므로 특정 PC의 SDK 절대경로를 저장하지 않는다. 고정된 두 소스 아카이브의 SHA-256을 먼저 검사하고 임시 작업 디렉터리에서 세 ABI를 다시 빌드한다. 필요한 로컬 도구는 Android NDK `28.2.13676358`과 CMake `3.22.1`이다.

## 4. 변경 파일 목록

### 기존 tracked 파일 수정

- `android/app/build.gradle.kts`
- `android/app/src/main/kotlin/com/myphotw/scana/MainActivity.kt`
- `docs/LICENSES.md`
- `lib/features/home/presentation/scan_home_page.dart`
- `test/widget_test.dart`

### 새 qpdf/PDF 편집 파일

- `android/app/src/main/cpp/qpdf/CMakeLists.txt`
- `android/app/src/main/cpp/qpdf/qpdf_bridge.cpp`
- `android/app/src/main/kotlin/com/myphotw/scana/pdfeditor/ExistingPdfEditorPlugin.kt`
- `android/app/src/main/kotlin/com/myphotw/scana/pdfeditor/PdfPageOrderPolicy.kt`
- `android/app/src/main/kotlin/com/myphotw/scana/pdfeditor/QpdfNative.kt`
- `android/app/src/test/kotlin/com/myphotw/scana/pdfeditor/PdfPageOrderPolicyTest.kt`
- `android/app/src/androidTest/kotlin/com/myphotw/scana/pdfeditor/QpdfNativeInstrumentedTest.kt`
- `android/third_party/qpdf/VERSIONS.md`
- `android/third_party/qpdf/build_android.ps1`
- `android/third_party/qpdf/sources/qpdf-12.4.2.tar.gz`
- `android/third_party/qpdf/sources/libjpeg-turbo-3.2.0.tar.gz`
- `android/third_party/qpdf/prebuilt/armeabi-v7a/libqpdf.so`
- `android/third_party/qpdf/prebuilt/arm64-v8a/libqpdf.so`
- `android/third_party/qpdf/prebuilt/x86_64/libqpdf.so`
- `lib/services/pdf_editor/existing_pdf_editor.dart`
- `lib/features/pdf_editor/presentation/existing_pdf_editor_page.dart`
- `test/services/pdf_editor/existing_pdf_editor_test.dart`
- `test/services/pdf_editor/qpdf_native_contract_test.dart`
- `test/features/pdf_editor/existing_pdf_editor_page_test.dart`
- `docs/PDF_EDITOR_HANDOFF.md`

## 5. 지금까지의 검증 결과

| 검증 | 상태 | 결과 |
| --- | --- | --- |
| qpdf 3 ABI 독립 NDK 빌드 | PASS | 세 `libqpdf.so` 생성 및 SHA-256 확인 |
| 새 PDF 편집 Flutter 대상 테스트 | PASS | `existing_pdf_editor_page_test.dart`, `existing_pdf_editor_test.dart` 합계 8개 통과 |
| `flutter analyze` | PASS | 마지막 실행에서 `No issues found` |
| Kotlin app unit test | PASS | `:app:testDebugUnitTest` 성공 |
| 전체 `flutter test` | PASS | 467개 통과 |
| 앱 CMake/JNI 최종 링크 | PASS | 세 ABI의 `libscana_qpdf.so` 빌드 성공 |
| qpdf APK 패키징 | PASS | Debug/Release APK 각각 세 ABI의 `libqpdf.so`, `libscana_qpdf.so`, `libc++_shared.so` 포함 확인 |
| Android instrumentation test APK | PASS | `:app:assembleDebugAndroidTest` 성공 |
| Android instrumentation test 실행 | PASS | Pixel 8 emulator에서 qpdf JNI 테스트 1개 실행 성공 |
| 5페이지 합성 PDF 재배열/삭제 | PASS | `1,2,3,4,5`에서 `3,1,5,2` 출력, 페이지 폭 순서와 4페이지 개수 확인 |
| 원본 PDF 불변 | PASS | instrumentation test에서 qpdf 실행 전후 원본 bytes 동일 확인 |
| Debug APK | PASS | `build/app/outputs/flutter-apk/app-debug.apk`, 381,081,216 bytes |
| Release APK 및 크기 증가량 | PASS | 최종 `build/app/outputs/flutter-apk/app-release.apk`, 221,215,739 bytes(210.97 MiB). 이전 기록 212,629,995 bytes 대비 +8,585,744 bytes(약 4.0%) |
| 1/5/20/100페이지 실제 PDF | UNVERIFIED | 실제 fixture/실기기 검증 전 |
| 암호화/손상 PDF | UNVERIFIED | UI 방어 코드는 있으나 실제 자료 검증 전 |
| 벡터/텍스트/OCR 보존 | UNVERIFIED | qpdf 객체 복사 방식이나 실제 표본 비교 전 |
| Galaxy Tab S7+ | PASS | 사용자가 기존 PDF 불러오기, 페이지 편집 및 수정본 저장의 주요 흐름 정상 동작을 확인 |
| `git diff --check` | PASS | 공백 오류 없음. 기존 Windows line-ending 안내만 출력 |

V1.2 릴리스 정리에서는 사용하지 않는 비교 PoC Kotlin 코드·테스트, Gradle 의존성과 전용 Robolectric 설정을 제거했다. 제거 후 위 Android/Flutter 테스트와 Release 빌드를 다시 통과했으며 APK에는 세 ABI 각각 `libqpdf.so`, `libscana_qpdf.so`, `libc++_shared.so`가 포함된다.

## 6. 마지막 오류와 현재 판단

1. 저장소 루트의 광범위한 `gradlew testDebugUnitTest` 실행은 Windows의 프로젝트 드라이브와 Flutter Pub cache 드라이브가 달라 camera plugin task에서 다음 오류가 발생했다.
   - `this and base files have different roots`
   - 다음에는 전체 unscoped Gradle 테스트 대신 `android` 디렉터리에서 `:app:testDebugUnitTest`를 사용한다.
2. 첫 `:app:testDebugUnitTest`에서 `ExistingPdfEditorPlugin.kt`의 nullable `data.flags` 컴파일 오류가 발생했다.
   - `(data?.flags ?: 0)`로 수정함.
   - 수정 후 동일 scoped unit test는 PASS했다.
3. 첫 Debug/Release APK 빌드에서는 CMake가 `libscana_qpdf.so`를 링크했지만 prebuilt `libqpdf.so` 본체가 APK에 포함되지 않았다.
   - `android/app/build.gradle.kts`의 main `jniLibs` source에 `../third_party/qpdf/prebuilt`를 추가했다.
   - 수정 후 Debug/Release APK에서 세 ABI별 qpdf/bridge/C++ runtime 총 9개 항목을 확인했다.
4. 전체 `flutter test`는 재개 후 두 번 완료했으며 최종 결과는 467개 PASS다.
5. Gradle 실행 시 sandbox의 Java home 계산이 사용자 프로필이 아닌 드라이브 루트의 `.gradle`을 가리킬 수 있다. Android Gradle 명령에는 실행 단위로 `$env:GRADLE_USER_HOME=Join-Path $env:USERPROFILE '.gradle'`을 설정하면 정상 동작한다. 프로젝트에는 개인 PC의 Gradle 절대경로를 저장하지 않았다.
6. 첫 instrumentation 실행은 `AndroidJUnitRunner` 클래스가 test APK에 없어 0개 테스트로 실패했다.
   - `androidTestImplementation("androidx.test:runner:1.7.0")`을 명시적으로 추가했다.
   - 같은 Pixel 8 emulator에서 재실행해 qpdf JNI 테스트 1개가 PASS했다.

## 7. 미완료 작업

- 실제 Scana PDF 및 1/5/20/100페이지 PDF로 순서/삭제/원본 SHA-256 검증
- 벡터, 텍스트, OCR 레이어, 페이지 크기/회전 보존 확인
- 암호화/손상/저장 취소/저장 실패/저장 공간 부족 검증
- 20/100페이지 대용량 문서와 암호화·손상 PDF 등 경계 조건의 추가 실기기 검증
- 검증이 모두 끝난 후에만 커밋 여부를 사용자에게 보고. 자동 commit/push 금지

## 8. 다음 작업의 정확한 재개 순서

호스트 빌드, Pixel 8 emulator의 합성 5페이지 qpdf JNI 검증과 Galaxy Tab S7+의 주요 사용자 흐름 확인은 완료되었다. 이후 회귀 확인 시 저장소 루트에서 현재 상태와 네이티브 파일 체크섬을 먼저 확인한다.

```powershell
Get-Content docs/PDF_EDITOR_HANDOFF.md
git status --short
Get-FileHash -Algorithm SHA256 android/third_party/qpdf/prebuilt/*/libqpdf.so
```

체크섬이 3절과 다르거나 파일이 없을 때만 재생성한다. 정상이라면 네이티브 빌드를 반복하지 않는다.

```powershell
powershell -ExecutionPolicy Bypass -File android/third_party/qpdf/build_android.ps1
```

JNI 회귀 확인이 필요할 때 instrumentation test를 다시 실행한다.

```powershell
Set-Location android
$env:GRADLE_USER_HOME=Join-Path $env:USERPROFILE '.gradle'
.\gradlew.bat :app:connectedDebugAndroidTest
Set-Location ..
```

추가 품질 검증이 필요하면 20/100페이지 PDF와 암호화·손상 문서를 사용해 메모리, 오류 안내와 저장 실패 복구를 확인한다. 테스트 전후 원본 SHA-256을 비교하고 출력의 텍스트 선택, OCR 검색, 벡터 확대, 페이지 크기와 회전을 확인한다. 마지막으로:

```powershell
git diff --check
git status --short
```

## 9. 기능 보호 조건

- 기존 ML Kit 스캔 흐름은 수정하지 않는다.
- 기존 `ScanSessionManager` 및 `DartPdfGenerator`를 PDF 편집용으로 재사용하거나 변경하지 않는다.
- 기존 Scan PDF 저장 성공 후 세션 삭제 정책을 변경하지 않는다.
- PDF 편집 성공/실패로 ScanSession을 삭제하지 않는다.
- Release의 `isMinifyEnabled = false`, `isShrinkResources = false`를 유지한다.
- 원본 PDF를 덮어쓰거나 삭제하지 않는다.
- PDF 페이지를 bitmap으로 재생성하지 않는다.
- 사용자 승인 없이 commit/push하지 않는다.
