import 'package:scana/models/scan_page.dart';

/// Groups the raw pages that belong to one scanning operation.
class ScanSession {
  ScanSession({required this.id, required this.createdTime});

  final String id;
  final DateTime createdTime;
  final List<ScanPage> _pages = [];

  List<ScanPage> get pages => List.unmodifiable(_pages);

  void addPage(ScanPage page) {
    _pages.add(page);
  }

  void sortPages() {
    _pages.sort((first, second) => first.pageNo.compareTo(second.pageNo));
  }
}
