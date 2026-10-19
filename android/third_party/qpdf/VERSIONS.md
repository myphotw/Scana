# Scana qpdf native dependency lock

- qpdf: `12.4.2`, upstream commit `4eba95899886e851cc41d76886483b347612f2a8`
- qpdf source archive SHA-256: `FB92435766B8EE31F7BF7123BEC1FC2AF83599ED8B1FEF7F3DAFEF4024A983B5`
- libjpeg-turbo: `3.2.0`, upstream commit `c85e6b905bf237038faa936dab160ebfc5da0344`
- libjpeg-turbo source archive SHA-256: `E880CAAB26D598BFF3055CD05B942262BAAEA09BD6E3D3362D6FBC92FAA9F744`
- Android API: 24
- NDK: `28.2.13676358`
- CMake: `3.22.1`
- STL: `c++_shared`
- qpdf crypto provider: native
- JPEG linkage: static libjpeg API from libjpeg-turbo
- zlib linkage: Android system zlib
- `armeabi-v7a/libqpdf.so` SHA-256: `C7B904F1BC0C3205E900DFD8FD7AA21EDD5BC0FAD1719FC856A88629E47BC941`
- `arm64-v8a/libqpdf.so` SHA-256: `F5C8BCF271FC79211D4983A0DA63B63E153B88F19727142891D5FDE7B5518E48`
- `x86_64/libqpdf.so` SHA-256: `1D35741AB5B66BFD3D58AA32B9A47AA9004D697DC54A77A538543AC55C829DD6`

The source archives are deterministic `git archive` snapshots of the pinned
commits. Run `build_android.ps1` from PowerShell to verify hashes and rebuild
all supported ABI libraries. No developer-machine SDK path is stored here.
