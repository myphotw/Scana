/// Describes which evidence selected the page area used for correction.
///
/// The value is persisted so recovery and debug diagnostics can distinguish a
/// precise paper boundary from the deliberately wider safety fallbacks.
enum CropSource {
  /// Corners explicitly confirmed by the user. Automatic detection must not
  /// replace these corners until the page itself is replaced.
  manualCorners,
  captureLiveBoundary,
  highResPaperBoundary,
  // Legacy Q1.2 values remain decodable for existing session.json files.
  paperBoundary,
  contentSafe,
  stableLiveFallback,
  guideFallback,
}
