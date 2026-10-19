param(
    [string]$AndroidSdk = "",
    [string]$NdkVersion = "28.2.13676358",
    [string]$CmakeVersion = "3.22.1"
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$androidRoot = Resolve-Path (Join-Path $root "..\..")
$projectRoot = Resolve-Path (Join-Path $androidRoot "..")

if ([string]::IsNullOrWhiteSpace($AndroidSdk)) { $AndroidSdk = $env:ANDROID_SDK_ROOT }
if ([string]::IsNullOrWhiteSpace($AndroidSdk)) {
    $properties = Join-Path $androidRoot "local.properties"
    if (Test-Path -LiteralPath $properties) {
        $line = Get-Content -LiteralPath $properties |
            Where-Object { $_ -like "sdk.dir=*" } | Select-Object -First 1
        if ($line) {
            $AndroidSdk = $line.Substring(8) -replace "\\:", ":" -replace "\\\\", "\"
        }
    }
}
if ([string]::IsNullOrWhiteSpace($AndroidSdk)) { throw "Set ANDROID_SDK_ROOT or pass -AndroidSdk." }

$cmake = Join-Path $AndroidSdk "cmake\$CmakeVersion\bin\cmake.exe"
$ninja = Join-Path $AndroidSdk "cmake\$CmakeVersion\bin\ninja.exe"
$toolchain = Join-Path $AndroidSdk "ndk\$NdkVersion\build\cmake\android.toolchain.cmake"
$strip = Join-Path $AndroidSdk "ndk\$NdkVersion\toolchains\llvm\prebuilt\windows-x86_64\bin\llvm-strip.exe"
foreach ($tool in @($cmake, $ninja, $toolchain, $strip)) {
    if (-not (Test-Path -LiteralPath $tool)) { throw "Missing Android build tool: $tool" }
}

$sources = Join-Path $root "sources"
$qpdfArchive = Join-Path $sources "qpdf-12.4.2.tar.gz"
$jpegArchive = Join-Path $sources "libjpeg-turbo-3.2.0.tar.gz"
$expected = @{
    $qpdfArchive = "FB92435766B8EE31F7BF7123BEC1FC2AF83599ED8B1FEF7F3DAFEF4024A983B5"
    $jpegArchive = "E880CAAB26D598BFF3055CD05B942262BAAEA09BD6E3D3362D6FBC92FAA9F744"
}
foreach ($archive in $expected.Keys) {
    $actual = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
    if ($actual -ne $expected[$archive]) { throw "Source checksum mismatch: $archive" }
}

$work = Join-Path ([System.IO.Path]::GetTempPath()) "scana-qpdf-android-build"
if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
New-Item -ItemType Directory -Force -Path $work | Out-Null
$qpdfSource = Join-Path $work "qpdf-source"
$jpegSource = Join-Path $work "jpeg-source"
New-Item -ItemType Directory -Force -Path $qpdfSource,$jpegSource | Out-Null
tar -xzf $qpdfArchive -C $qpdfSource
tar -xzf $jpegArchive -C $jpegSource

foreach ($abi in @("armeabi-v7a", "arm64-v8a", "x86_64")) {
    $jpegBuild = Join-Path $work "jpeg-$abi"
    $jpegInstall = Join-Path $work "jpeg-install-$abi"
    $qpdfBuild = Join-Path $work "qpdf-$abi"
    & $cmake -S $jpegSource -B $jpegBuild -G Ninja `
        "-DCMAKE_MAKE_PROGRAM=$ninja" "-DCMAKE_TOOLCHAIN_FILE=$toolchain" `
        "-DANDROID_ABI=$abi" -DANDROID_PLATFORM=24 -DANDROID_STL=c++_shared `
        -DCMAKE_BUILD_TYPE=MinSizeRel -DENABLE_SHARED=OFF -DENABLE_STATIC=ON `
        -DWITH_TURBOJPEG=OFF -DWITH_SIMD=OFF -DWITH_TOOLS=OFF -DWITH_TESTS=OFF `
        "-DCMAKE_INSTALL_PREFIX=$jpegInstall"
    if ($LASTEXITCODE -ne 0) { throw "libjpeg configure failed for $abi" }
    & $cmake --build $jpegBuild --target install --parallel 8
    if ($LASTEXITCODE -ne 0) { throw "libjpeg build failed for $abi" }

    & $cmake -S $qpdfSource -B $qpdfBuild -G Ninja `
        "-DCMAKE_MAKE_PROGRAM=$ninja" "-DCMAKE_TOOLCHAIN_FILE=$toolchain" `
        "-DANDROID_ABI=$abi" -DANDROID_PLATFORM=24 -DANDROID_STL=c++_shared `
        -DCMAKE_BUILD_TYPE=MinSizeRel -DBUILD_SHARED_LIBS=ON -DBUILD_STATIC_LIBS=OFF `
        -DBUILD_DOC=OFF -DBUILD_TESTING=OFF -DUSE_IMPLICIT_CRYPTO=OFF `
        -DREQUIRE_CRYPTO_NATIVE=ON -DSTATIC_JPEG=ON `
        "-DLIBJPEG_LIB_PATH=$jpegInstall\lib\libjpeg.a" `
        "-DLIBJPEG_H_PATH=$jpegInstall\include"
    if ($LASTEXITCODE -ne 0) { throw "qpdf configure failed for $abi" }
    & $cmake --build $qpdfBuild --target libqpdf --parallel 8
    if ($LASTEXITCODE -ne 0) { throw "qpdf build failed for $abi" }

    $destination = Join-Path $projectRoot "android\third_party\qpdf\prebuilt\$abi\libqpdf.so"
    New-Item -ItemType Directory -Force -Path (Split-Path $destination) | Out-Null
    Copy-Item -LiteralPath (Join-Path $qpdfBuild "libqpdf\libqpdf.so") -Destination $destination -Force
    & $strip --strip-unneeded $destination
    if ($LASTEXITCODE -ne 0) { throw "qpdf strip failed for $abi" }
    Get-FileHash -LiteralPath $destination -Algorithm SHA256
}
