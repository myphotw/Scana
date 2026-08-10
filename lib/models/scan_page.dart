/// A raw page captured during a scan session.
class ScanPage {
  const ScanPage({
    required this.pageNo,
    required this.rawImagePath,
    required this.createdTime,
  });

  final int pageNo;
  final String rawImagePath;
  final DateTime createdTime;
}
