class OcrRect {
  const OcrRect({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  final double left;
  final double top;
  final double right;
  final double bottom;

  double get height => bottom - top;
}

class OcrLine {
  const OcrLine({
    required this.text,
    this.boundingBox,
    this.confidence,
    this.language,
  });

  final String text;
  final OcrRect? boundingBox;
  final double? confidence;
  final String? language;
}

class OcrBlock {
  const OcrBlock({
    required this.text,
    required this.lines,
    this.boundingBox,
    this.language,
  });

  final String text;
  final List<OcrLine> lines;
  final OcrRect? boundingBox;
  final String? language;
}

class OcrResult {
  const OcrResult({
    required this.fullText,
    required this.blocks,
    required this.sourcePageId,
    required this.sourceWidth,
    required this.sourceHeight,
  });

  final String fullText;
  final List<OcrBlock> blocks;
  final String sourcePageId;
  final int sourceWidth;
  final int sourceHeight;

  Iterable<OcrLine> get lines => blocks.expand((block) => block.lines);
}
