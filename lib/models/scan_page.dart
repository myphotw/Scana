/// A raw page captured during a scan session.
class ScanPage {
  const ScanPage({
    required this.pageNo,
    required this.rawImagePath,
    required this.createdTime,
    this.rotation = 0,
  }) : assert(
         rotation == 0 || rotation == 90 || rotation == 180 || rotation == 270,
       );

  final int pageNo;
  final String rawImagePath;
  final DateTime createdTime;
  final int rotation;

  ScanPage copyWith({int? pageNo, int? rotation}) {
    return ScanPage(
      pageNo: pageNo ?? this.pageNo,
      rawImagePath: rawImagePath,
      createdTime: createdTime,
      rotation: rotation ?? this.rotation,
    );
  }

  ScanPage rotateClockwise() => copyWith(rotation: (rotation + 90) % 360);
}
