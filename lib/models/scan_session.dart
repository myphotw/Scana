import 'package:scana/models/scan_page.dart';
import 'package:scana/models/document_detection_result.dart';

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

  ScanPage removePageAt(int index) {
    final page = _pages.removeAt(index);
    _renumberPages();
    return page;
  }

  void reorderPages(int oldIndex, int newIndex) {
    final page = _pages.removeAt(oldIndex);
    _pages.insert(newIndex, page);
    _renumberPages();
  }

  void rotatePageAt(int index) {
    _pages[index] = _pages[index].rotateClockwise();
  }

  void updateDetectionAt(int index, DocumentDetectionResult detection) {
    _pages[index] = _pages[index].withDetection(detection);
  }

  void updateDocumentCornersAt(int index, DocumentCorners corners) {
    _pages[index] = _pages[index].withDocumentCorners(corners);
  }

  void _renumberPages() {
    for (var index = 0; index < _pages.length; index++) {
      _pages[index] = _pages[index].copyWith(pageNo: index + 1);
    }
  }
}
