import 'package:scana/models/document_detection_result.dart';

/// A raw page captured during a scan session.
class ScanPage {
  const ScanPage({
    required this.pageNo,
    required this.rawImagePath,
    required this.createdTime,
    this.rotation = 0,
    this.documentCorners,
    this.documentSourceWidth,
    this.documentSourceHeight,
  }) : assert(
         rotation == 0 || rotation == 90 || rotation == 180 || rotation == 270,
       );

  final int pageNo;
  final String rawImagePath;
  final DateTime createdTime;
  final int rotation;
  final DocumentCorners? documentCorners;
  final int? documentSourceWidth;
  final int? documentSourceHeight;

  ScanPage copyWith({
    int? pageNo,
    int? rotation,
    DocumentCorners? documentCorners,
    int? documentSourceWidth,
    int? documentSourceHeight,
  }) {
    return ScanPage(
      pageNo: pageNo ?? this.pageNo,
      rawImagePath: rawImagePath,
      createdTime: createdTime,
      rotation: rotation ?? this.rotation,
      documentCorners: documentCorners ?? this.documentCorners,
      documentSourceWidth: documentSourceWidth ?? this.documentSourceWidth,
      documentSourceHeight: documentSourceHeight ?? this.documentSourceHeight,
    );
  }

  ScanPage rotateClockwise() => copyWith(rotation: (rotation + 90) % 360);

  ScanPage withDetection(DocumentDetectionResult detection) {
    return copyWith(
      documentCorners: detection.corners,
      documentSourceWidth: detection.sourceWidth > 0
          ? detection.sourceWidth
          : documentSourceWidth,
      documentSourceHeight: detection.sourceHeight > 0
          ? detection.sourceHeight
          : documentSourceHeight,
    );
  }

  ScanPage withDocumentCorners(DocumentCorners corners) {
    return copyWith(documentCorners: corners);
  }
}
