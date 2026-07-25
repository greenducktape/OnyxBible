import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'library_store.dart';
import 'main.dart' show DrawingStore;
import 'plan_store.dart';
import 'settings_store.dart';

/// A single-file backup of everything the user owns — their printed Bibles and
/// each one's handwritten notes, reading plans and progress, and settings — so
/// it can be saved off-device and restored later. The app keeps no cloud copy,
/// so this is the user's safety net against a wipe or a lost device.
class BackupService {
  static const String _appTag = 'onyxbible';
  static const int _schema = 1;

  /// Gathers all app data into one JSON file in a temporary directory and
  /// returns it (ready to hand to the share sheet).
  static Future<File> writeBackupFile() async {
    final notes = <String, dynamic>{};
    for (final b in LibraryStore.bibles) {
      final n = await DrawingStore.rawNotesFor(b.id);
      if (n != null) notes[b.id] = n;
    }
    final data = {
      'app': _appTag,
      'schema': _schema,
      'exportedAt': DateTime.now().toIso8601String(),
      'library': {
        'activeId': LibraryStore.activeId,
        'bibles': [for (final b in LibraryStore.bibles) b.toJson()],
      },
      'notes': notes,
      'plans': {
        'activeId': PlanStore.activeId,
        'plans': [for (final p in PlanStore.plans) p.toJson()],
      },
      'settings': SettingsStore.value.toJson(),
    };
    final dir = await getTemporaryDirectory();
    final stamp = DateTime.now().toIso8601String().split('T').first;
    final file = File('${dir.path}/onyxbible-backup-$stamp.json');
    await file.writeAsString(json.encode(data));
    return file;
  }

  /// Builds a backup file and opens the system share sheet for it.
  static Future<void> exportViaShare() async {
    final file = await writeBackupFile();
    await Share.shareXFiles([XFile(file.path)], subject: 'Onyx Bible backup');
  }

  /// Validates and restores a backup, REPLACING all current data. Throws a
  /// [FormatException] if the file isn't a recognised Onyx Bible backup.
  /// Callers should snapshot the current state first (see [writeBackupFile])
  /// and confirm with the user, since this overwrites everything.
  static Future<void> restoreFromFile(File file) async {
    final decoded = json.decode(await file.readAsString());
    if (decoded is! Map || decoded['app'] != _appTag) {
      throw const FormatException('Not an Onyx Bible backup file.');
    }
    final data = decoded.cast<String, dynamic>();

    // Stop any in-flight debounced note save from clobbering the new files.
    DrawingStore.cancelPendingSave();

    if (data['settings'] is Map) {
      await SettingsStore.restore(
          Settings.fromJson((data['settings'] as Map).cast<String, dynamic>()));
    }

    final lib = (data['library'] as Map?)?.cast<String, dynamic>();
    if (lib != null) {
      final bibles = [
        for (final e in (lib['bibles'] as List? ?? const []))
          BibleConfig.fromJson((e as Map).cast<String, dynamic>())
      ];
      await LibraryStore.restore(bibles, lib['activeId'] as String?);
    }

    final notes = (data['notes'] as Map?)?.cast<String, dynamic>() ?? const {};
    for (final entry in notes.entries) {
      await DrawingStore.writeRawNotesFor(entry.key, entry.value as Object);
    }

    final plans = (data['plans'] as Map?)?.cast<String, dynamic>();
    if (plans != null) {
      final list = [
        for (final e in (plans['plans'] as List? ?? const []))
          SavedPlan.fromJson((e as Map).cast<String, dynamic>())
      ];
      await PlanStore.restore(list, plans['activeId'] as String?);
    }

    if (!LibraryStore.isEmpty) {
      await DrawingStore.switchAndReload(LibraryStore.active.id);
    }
  }
}
