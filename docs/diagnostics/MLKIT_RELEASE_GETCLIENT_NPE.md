# ML Kit Release `getClient` NPE investigation

Date: 2026-08-22

## Device evidence

- Device: Galaxy Tab S7+
- Build: Release APK
- Failure stage: `get_client`
- Exception: `java.lang.NullPointerException`
- Top frame: `java.util.Objects`, `Objects.java:504`
- Debug APK on the same device has launched Document Scanner successfully.

## SDK bytecode finding

`play-services-mlkit-document-scanner:16.0.0` implements
`GmsDocumentScanning.getClient(options)` by constructing its internal scanner.
That constructor first creates the scanner telemetry client. The telemetry
client obtains `SharedPrefManager` from `MlKitContext`, then its constructor
calls `Objects.requireNonNull(sharedPrefManager)`.

Therefore the observed frame identifies a null ML Kit component lookup; it is
not the scanner options object. The options object is a non-null local `val`
and its class and identity are now recorded immediately before `getClient`.

## Debug/Release comparison

### Manifest and application configuration

Both packaged APKs contain:

- applicationId `com.myphotw.scana`
- versionCode `1`, versionName `1.0.0`
- `MlKitInitProvider`
- `MlKitComponentDiscoveryService`
- `CommonComponentRegistrar`, `VisionCommonRegistrar`, and `TextRegistrar`
- `GmsDocumentScanningDelegateActivity`

The effective merged-manifest difference is `android:debuggable="true"` in
Debug plus Debug's explanatory INTERNET-permission comment/location. The
effective permissions and ML Kit components are the same.

Both APKs use the same debug signing certificate during this development
phase (SHA-256 `f9b4acea7290a0db5151d399c3ca05ebc917e767c9d8413ec278150441da4a7c`).

### Resolved dependencies

Debug and Release resolve the same versions:

| Module | Resolved version | Resolution note |
| --- | ---: | --- |
| `play-services-mlkit-document-scanner` | 16.0.0 | direct dependency |
| `com.google.mlkit:common` | 18.11.0 | 18.6.0 upgraded by conflict resolution |
| `play-services-base` | 18.5.0 | 18.1.0 upgraded by conflict resolution |
| `play-services-tasks` | 18.2.0 | 18.0.2 upgraded by conflict resolution |

The conflicts are identical in both variants, so they do not explain the
Release-only failure by themselves.

### R8 and resource shrinking

Before the production fix, the app build script did not explicitly set
`isMinifyEnabled`. Flutter's Gradle plugin defaults its `shrink` property to
true and configured Release with both `isMinifyEnabled = true` and
`isShrinkResources = true`.

Artifact evidence:

- Release task graph contains `minifyReleaseWithR8`.
- `build/app/outputs/mapping/release/` contains mapping, seeds, usage, and
  configuration reports.
- Before the fix, R8 merged ML Kit `LazyInstanceMap` with an unrelated CameraX
  class and horizontally merged scanner telemetry map implementations.
- Debug does not run that transformation.

## Targeted keep-rule result

An initial diagnostic fix prevented optimization and class merging across the
ML Kit automatic initialization/component boundary for:

- `com.google.mlkit.common.internal.**`
- `com.google.mlkit.common.sdkinternal.**`
- `com.google.firebase.components.**`

The resulting Release APK still reproduced the same `getClient` NPE on the
Galaxy Tab S7+. These keep rules are therefore not a production fix and have
been removed.

## Production fix

The R8-disabled diagnostic APK launched ML Kit Document Scanner successfully
on the same Galaxy Tab S7+. Scana V1 therefore promotes that verified setting
to its production Release build:

- `isMinifyEnabled = false`
- `isShrinkResources = false`

Both values are explicit in `android/app/build.gradle.kts`; Scana no longer
depends on Flutter's implicit Release shrink defaults. No provider or manual
`MlKitContext` initialization was added.

## A/B artifact

An R8-disabled diagnostic build was produced with Gradle property
`-Pshrink=false` and temporarily copied as:

`build/app/outputs/flutter-apk/app-release-no-shrink-diagnostic.apk`

This temporary APK was used only to isolate the failure and is removed after
promoting its configuration. The production `app-release.apk` is now built
from the same no-minify/no-resource-shrink configuration.

## Official references and issue search

- Android document scanner guide:
  https://developers.google.com/ml-kit/vision/doc-scanner/android
- Official sample:
  https://github.com/googlesamples/mlkit/tree/master/android/documentscanner
- API reference:
  https://developers.google.com/android/reference/com/google/mlkit/vision/documentscanner/GmsDocumentScanning

No matching official issue was found for version 16.0.0 combining
`GmsDocumentScanning.getClient`, Release, `NullPointerException`, and
`Objects.requireNonNull`. Related sample-repository issues found during the
search concern different failures and do not support a version change.
