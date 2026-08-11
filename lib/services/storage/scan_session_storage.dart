import 'dart:io';
import 'dart:convert';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'package:scana/models/scan_page.dart';
import 'package:scana/models/scan_session.dart';
import 'package:scana/models/document_detection_result.dart';
import 'package:scana/models/page_correction.dart';
import 'package:scana/models/page_boundary.dart';
import 'package:scana/models/scan_capture_mode.dart';

typedef AppPrivateDirectoryProvider = Future<Directory> Function();

class CorrectionOutputTarget {
  const CorrectionOutputTarget({
    required this.workingPath,
    required this.finalPath,
  });

  final String workingPath;
  final String finalPath;
}

/// Storage operations for raw files in an app-private scan session.
abstract interface class ScanSessionStorage {
  Future<void> createSession(String sessionId);

  Future<List<ScanSession>> findRecoverableSessions();

  Future<void> saveSession(ScanSession session);

  Future<String> storeRawPage({
    required String sessionId,
    required int pageNo,
    required String capturedImagePath,
  });

  Future<void> deleteSession(String sessionId);

  Future<CorrectionOutputTarget> prepareCorrectionOutput({
    required String sessionId,
    required String rawImagePath,
    required CorrectionType type,
  });

  Future<String> commitCorrectionOutput(CorrectionOutputTarget target);

  Future<void> discardCorrectionOutput(CorrectionOutputTarget target);

  Future<void> deletePageFiles(ScanPage page);
}

/// Stores sessions in the app support directory, outside OS-managed caches.
class AppPrivateSessionStorage implements ScanSessionStorage {
  factory AppPrivateSessionStorage({
    AppPrivateDirectoryProvider appPrivateDirectoryProvider =
        getApplicationSupportDirectory,
  }) {
    return AppPrivateSessionStorage._(appPrivateDirectoryProvider);
  }

  AppPrivateSessionStorage._(this._appPrivateDirectoryProvider);

  final AppPrivateDirectoryProvider _appPrivateDirectoryProvider;

  @override
  Future<void> createSession(String sessionId) async {
    final directory = await _sessionDirectory(sessionId);
    await directory.create(recursive: true);
  }

  @override
  Future<void> saveSession(ScanSession session) async {
    final sessionDirectory = await _sessionDirectory(session.id);
    await sessionDirectory.create(recursive: true);
    final metadata = <String, Object>{
      'id': session.id,
      'createdTime': session.createdTime.toIso8601String(),
      'captureMode': session.captureMode.name,
      'pages': session.pages
          .map(
            (page) => <String, Object>{
              'pageNo': page.pageNo,
              'rawImageFile': path.basename(page.rawImagePath),
              'createdTime': page.createdTime.toIso8601String(),
              'rotation': page.rotation,
              if (page.documentSourceWidth != null)
                'documentSourceWidth': page.documentSourceWidth!,
              if (page.documentSourceHeight != null)
                'documentSourceHeight': page.documentSourceHeight!,
              if (page.documentCorners != null)
                'documentCorners': page.documentCorners!.toJson(),
              if (page.pageBoundary != null)
                'pageBoundary': page.pageBoundary!.toJson(),
              if (page.captureGuideCorners != null)
                'captureGuideCorners': page.captureGuideCorners!.toJson(),
              if (page.detectionConfidence != null)
                'detectionConfidence': page.detectionConfidence!,
              'spreadFallbackUsed': page.spreadFallbackUsed,
              'hasUserAdjustedCorners': page.hasUserAdjustedCorners,
              if (page.correctedImagePath != null)
                'correctedImageFile': path.basename(page.correctedImagePath!),
              'correctionStatus': page.correctionStatus.name,
              'correctionType': page.correctionType.name,
              'correctionOutcome': page.correctionOutcome.name,
            },
          )
          .toList(),
    };
    await File(
      path.join(sessionDirectory.path, 'session.json'),
    ).writeAsString(jsonEncode(metadata));
  }

  @override
  Future<List<ScanSession>> findRecoverableSessions() async {
    final appPrivateDirectory = await _appPrivateDirectoryProvider();
    final sessionsDirectory = Directory(
      path.join(appPrivateDirectory.path, 'scan_sessions'),
    );
    if (!await sessionsDirectory.exists()) {
      return [];
    }

    final sessions = <ScanSession>[];
    await for (final entity in sessionsDirectory.list(followLinks: false)) {
      if (entity is! Directory) {
        continue;
      }

      final recoveredSession = await _readSessionMetadata(entity);
      sessions.add(recoveredSession ?? await _recoverFromRawFiles(entity));
    }

    sessions.sort(
      (first, second) => second.createdTime.compareTo(first.createdTime),
    );
    return sessions;
  }

  Future<ScanSession?> _readSessionMetadata(Directory sessionDirectory) async {
    final metadataFile = File(path.join(sessionDirectory.path, 'session.json'));
    if (!await metadataFile.exists()) {
      return null;
    }

    try {
      final metadata = jsonDecode(await metadataFile.readAsString());
      if (metadata is! Map<String, dynamic> ||
          metadata['id'] != path.basename(sessionDirectory.path) ||
          metadata['pages'] is! List) {
        return null;
      }
      final createdTime = DateTime.tryParse(
        metadata['createdTime'] as String? ?? '',
      );
      if (createdTime == null) {
        return null;
      }
      final captureMode = ScanCaptureMode.values.firstWhere(
        (mode) => mode.name == metadata['captureMode'],
        orElse: () => ScanCaptureMode.single,
      );

      final session = ScanSession(
        id: metadata['id'] as String,
        createdTime: createdTime,
        captureMode: captureMode,
      );
      for (final pageData in metadata['pages'] as List<dynamic>) {
        if (pageData is! Map<String, dynamic>) {
          return null;
        }
        final pageNo = pageData['pageNo'] as int?;
        final rawImageFile = pageData['rawImageFile'] as String?;
        final pageCreatedTime = DateTime.tryParse(
          pageData['createdTime'] as String? ?? '',
        );
        final rotation = pageData['rotation'] as int?;
        final sourceWidth = pageData['documentSourceWidth'] as int?;
        final sourceHeight = pageData['documentSourceHeight'] as int?;
        final cornersValue = pageData['documentCorners'];
        final documentCorners = DocumentCorners.fromJson(cornersValue);
        final boundaryValue = pageData['pageBoundary'];
        final pageBoundary = PageBoundary.fromJson(boundaryValue);
        final guideCornersValue = pageData['captureGuideCorners'];
        final captureGuideCorners = DocumentCorners.fromJson(guideCornersValue);
        final detectionConfidence = (pageData['detectionConfidence'] as num?)
            ?.toDouble();
        final spreadFallbackUsed =
            pageData['spreadFallbackUsed'] as bool? ?? false;
        final hasUserAdjustedCorners =
            pageData['hasUserAdjustedCorners'] as bool? ?? false;
        final correctedImageFile = pageData['correctedImageFile'] as String?;
        final correctionType = _correctionTypeFromJson(
          pageData['correctionType'],
        );
        var correctionOutcome = _correctionOutcomeFromJson(
          pageData['correctionOutcome'],
        );
        var correctionStatus = _correctionStatusFromJson(
          pageData['correctionStatus'],
        );
        if (pageNo == null ||
            rawImageFile == null ||
            !_isRelativeFileName(rawImageFile) ||
            pageCreatedTime == null ||
            !_isValidRotation(rotation) ||
            (cornersValue != null && documentCorners == null) ||
            (boundaryValue != null && pageBoundary == null) ||
            (guideCornersValue != null && captureGuideCorners == null) ||
            (correctedImageFile != null &&
                !_isRelativeFileName(correctedImageFile))) {
          return null;
        }

        final rawImagePath = path.join(sessionDirectory.path, rawImageFile);
        if (!await File(rawImagePath).exists()) {
          return null;
        }
        String? correctedImagePath;
        if (correctedImageFile != null &&
            _isRelativeFileName(correctedImageFile)) {
          final candidate = path.join(
            sessionDirectory.path,
            correctedImageFile,
          );
          if (await File(candidate).exists()) {
            correctedImagePath = candidate;
          } else if (correctionStatus == CorrectionStatus.completed) {
            correctionStatus = CorrectionStatus.failed;
          }
        }
        if (correctionStatus == CorrectionStatus.processing) {
          correctionStatus = CorrectionStatus.failed;
        }
        if (correctionStatus == CorrectionStatus.completed &&
            correctedImagePath == null) {
          correctionStatus = CorrectionStatus.failed;
        }
        if (correctionOutcome == CorrectionOutcome.none &&
            correctionStatus == CorrectionStatus.completed) {
          correctionOutcome = CorrectionOutcome.completed;
        }
        session.addPage(
          ScanPage(
            pageNo: pageNo,
            rawImagePath: rawImagePath,
            createdTime: pageCreatedTime,
            rotation: rotation!,
            documentCorners: documentCorners,
            pageBoundary: pageBoundary,
            documentSourceWidth: sourceWidth,
            documentSourceHeight: sourceHeight,
            captureGuideCorners: captureGuideCorners,
            detectionConfidence: detectionConfidence,
            spreadFallbackUsed: spreadFallbackUsed,
            hasUserAdjustedCorners: hasUserAdjustedCorners,
            correctedImagePath: correctedImagePath,
            correctionStatus: correctionStatus,
            correctionType: correctionType,
            correctionOutcome: correctionOutcome,
          ),
        );
      }
      return session;
    } on FormatException {
      return null;
    } on FileSystemException {
      return null;
    } on TypeError {
      return null;
    }
  }

  Future<ScanSession> _recoverFromRawFiles(Directory entity) async {
    final pages = <ScanPage>[];
    await for (final fileEntity in entity.list(followLinks: false)) {
      if (fileEntity is! File) {
        continue;
      }

      final match = _rawPageName.firstMatch(path.basename(fileEntity.path));
      final pageNo = match == null ? null : int.tryParse(match.group(1)!);
      if (pageNo == null) {
        continue;
      }

      pages.add(
        ScanPage(
          pageNo: pageNo,
          rawImagePath: fileEntity.path,
          createdTime: (await fileEntity.stat()).modified,
        ),
      );
    }
    pages.sort((first, second) => first.pageNo.compareTo(second.pageNo));
    final createdTime = pages.isEmpty
        ? (await entity.stat()).modified
        : pages
              .map((page) => page.createdTime)
              .reduce(
                (first, second) => first.isBefore(second) ? first : second,
              );
    final session = ScanSession(
      id: path.basename(entity.path),
      createdTime: createdTime,
    );
    for (final page in pages) {
      session.addPage(page);
    }
    return session;
  }

  @override
  Future<String> storeRawPage({
    required String sessionId,
    required int pageNo,
    required String capturedImagePath,
  }) async {
    final directory = await _sessionDirectory(sessionId);
    await directory.create(recursive: true);

    var fileIndex = pageNo;
    var destinationPath = path.join(
      directory.path,
      'raw_${fileIndex.toString().padLeft(3, '0')}.jpg',
    );
    while (await File(destinationPath).exists()) {
      fileIndex++;
      destinationPath = path.join(
        directory.path,
        'raw_${fileIndex.toString().padLeft(3, '0')}.jpg',
      );
    }
    final source = File(capturedImagePath);
    await source.copy(destinationPath);

    if (path.normalize(source.path) != path.normalize(destinationPath)) {
      await source.delete();
    }

    return destinationPath;
  }

  @override
  Future<void> deleteSession(String sessionId) async {
    final directory = await _sessionDirectory(sessionId);
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }

  @override
  Future<CorrectionOutputTarget> prepareCorrectionOutput({
    required String sessionId,
    required String rawImagePath,
    required CorrectionType type,
  }) async {
    final directory = await _sessionDirectory(sessionId);
    await directory.create(recursive: true);
    final rawStem = path.basenameWithoutExtension(rawImagePath);
    final suffix = rawStem.startsWith('raw_')
        ? rawStem.substring('raw_'.length)
        : rawStem;
    final baseName = type == CorrectionType.perspective
        ? 'corrected_$suffix.jpg'
        : 'corrected_curved_$suffix.jpg';
    var finalName = baseName;
    var revision = 2;
    while (await File(path.join(directory.path, finalName)).exists()) {
      finalName = '${path.basenameWithoutExtension(baseName)}_$revision.jpg';
      revision++;
    }
    return CorrectionOutputTarget(
      workingPath: path.join(directory.path, '.$finalName.pending.jpg'),
      finalPath: path.join(directory.path, finalName),
    );
  }

  @override
  Future<String> commitCorrectionOutput(CorrectionOutputTarget target) async {
    final workingFile = File(target.workingPath);
    if (!await workingFile.exists()) {
      throw const FileSystemException('Correction output was not created.');
    }
    await workingFile.copy(target.finalPath);
    await workingFile.delete();
    return target.finalPath;
  }

  @override
  Future<void> discardCorrectionOutput(CorrectionOutputTarget target) async {
    final workingFile = File(target.workingPath);
    if (await workingFile.exists()) {
      await workingFile.delete();
    }
  }

  @override
  Future<void> deletePageFiles(ScanPage page) async {
    final rawStem = path.basenameWithoutExtension(page.rawImagePath);
    final suffix = rawStem.startsWith('raw_')
        ? rawStem.substring('raw_'.length)
        : rawStem;
    final parentDirectory = path.dirname(page.rawImagePath);
    final filePaths = <String>{
      page.rawImagePath,
      if (page.correctedImagePath != null) page.correctedImagePath!,
    };
    final correctionFilePattern = RegExp(
      r'^\.?corrected(?:_curved)?_' +
          RegExp.escape(suffix) +
          r'(?:_\d+)?\.jpg(?:\.pending\.jpg)?$',
    );
    final directory = Directory(parentDirectory);
    if (await directory.exists()) {
      await for (final entity in directory.list(followLinks: false)) {
        if (entity is File &&
            correctionFilePattern.hasMatch(path.basename(entity.path))) {
          filePaths.add(entity.path);
        }
      }
    }
    for (final filePath in filePaths) {
      final file = File(filePath);
      if (await file.exists()) {
        await file.delete();
      }
    }
  }

  Future<Directory> _sessionDirectory(String sessionId) async {
    final appPrivateDirectory = await _appPrivateDirectoryProvider();
    return Directory(
      path.join(appPrivateDirectory.path, 'scan_sessions', sessionId),
    );
  }

  static final RegExp _rawPageName = RegExp(r'^raw_(\d+)\.jpg$');

  static bool _isRelativeFileName(String value) {
    return !path.isAbsolute(value) && path.basename(value) == value;
  }

  static bool _isValidRotation(int? value) {
    return value == 0 || value == 90 || value == 180 || value == 270;
  }

  static CorrectionStatus _correctionStatusFromJson(Object? value) {
    return CorrectionStatus.values.firstWhere(
      (status) => status.name == value,
      orElse: () => CorrectionStatus.none,
    );
  }

  static CorrectionType _correctionTypeFromJson(Object? value) {
    return CorrectionType.values.firstWhere(
      (type) => type.name == value,
      orElse: () => CorrectionType.perspective,
    );
  }

  static CorrectionOutcome _correctionOutcomeFromJson(Object? value) {
    return CorrectionOutcome.values.firstWhere(
      (outcome) => outcome.name == value,
      orElse: () => CorrectionOutcome.none,
    );
  }
}
