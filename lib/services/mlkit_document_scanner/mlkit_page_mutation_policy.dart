import 'package:scana/features/scan_session/application/scan_session_manager.dart';
import 'package:scana/models/scan_page.dart';

class MlKitPageMutationPolicy {
  const MlKitPageMutationPolicy._();

  static Set<String> preserveSelection(
    Set<String> selectedBefore,
    MlKitPageMutation mutation,
  ) {
    final result = Set<String>.of(selectedBefore)
      ..removeAll(mutation.oldRawPaths);
    if (mutation.oldRawPaths.any(selectedBefore.contains)) {
      result.addAll(mutation.pages.map((page) => page.rawImagePath));
    }
    return result;
  }

  static List<ScanPage> preserveOrder(
    List<ScanPage> orderedBefore,
    MlKitPageMutation mutation,
  ) {
    final indices = <int>[
      for (var index = 0; index < orderedBefore.length; index++)
        if (mutation.oldRawPaths.contains(orderedBefore[index].rawImagePath))
          index,
    ];
    if (indices.isEmpty) return List<ScanPage>.of(orderedBefore);
    final result = List<ScanPage>.of(orderedBefore)
      ..removeWhere((page) => mutation.oldRawPaths.contains(page.rawImagePath));
    result.insertAll(indices.first.clamp(0, result.length), mutation.pages);
    return result;
  }
}
