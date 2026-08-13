/// Describes which evidence selected the page area used for correction.
///
/// The value is persisted so recovery and debug diagnostics can distinguish a
/// precise paper boundary from the deliberately wider safety fallbacks.
enum CropSource {
  /// Corners explicitly confirmed by the user. Automatic detection must not
  /// replace these corners until the page itself is replaced.
  manualCorners,

  /// Fully confirmed visibility-safe AI refinement.
  aiRefined,

  /// Per-edge hybrid: confirmed edges plus conservative weak/unknown edges.
  aiHybrid,

  /// Sane AI mask boundary expanded with visibility-safe margins.
  aiRawFallback,

  /// Q1.x/OpenCV result selected because AI could not produce a safe polygon.
  openCvFallback,
  captureLiveBoundary,
  highResPaperBoundary,
  // Legacy Q1.2 values remain decodable for existing session.json files.
  paperBoundary,
  contentSafe,
  stableLiveFallback,
  guideFallback,
}
